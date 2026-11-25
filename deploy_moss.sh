#!/usr/bin/env bash
# =============================================================================
#  MOSS-Image + SeedVR2 一键部署
#  适用：RunPod / Vast.ai / 任意 Ubuntu + NVIDIA GPU 容器（root 或有 sudo）
#
#  用法：
#    bash deploy_moss.sh                 # 全量部署（约 45G 下载）
#    SKIP_MODELS=1 bash deploy_moss.sh   # 已有权重时跳过 40G 下载
#    PORT=8188 bash deploy_moss.sh       # 自定义端口
#    SEEDVR2_REMOTE=1 bash deploy_moss.sh  # SeedVR2 用远端 2.5.10 而非本地快照
#
#  设计要点：
#    - 幂等：每一步都先检查，已完成的跳过，中断后重跑可续
#    - 不碰 torch：所有 requirements 都过滤掉 torch 系，避免覆盖镜像里的 CUDA 版
#    - 中文名安全：本地包用 Python zipfile 解压，不用 unzip（会破坏 UTF-8）
#    - 端口直通：--listen 0.0.0.0，不需要任何隧道
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n[FAIL] 第 $LINENO 行失败: $BASH_COMMAND" >&2' ERR

COMFY_ROOT=${COMFY_ROOT:-/workspace/ComfyUI}
PORT=${PORT:-8188}
PY=${PY:-python3}
SKIP_MODELS=${SKIP_MODELS:-0}
SEEDVR2_REMOTE=${SEEDVR2_REMOTE:-0}

ZIP_URL="https://github.com/QLANSHENG/moss-assets/releases/download/v1/moss-local.zip"
ZIP_SHA="3306a9ccf7f747c41439bc8df6bad2dc28ea8e320358d1a53e312c52d6f7629e"
ZIP_PATH=/workspace/moss-local.zip
LOCAL_DIR=/workspace/moss-local

COMFY_TAG="v0.42.0"
RGTHREE_SHA="2b9eb36d3e1741e88dbfccade0e08137f7fa2bfb"
KJNODES_SHA="4dfb85dcc52e4315c33170d97bb987baa46d128b"
SEEDVR2_REMOTE_SHA="912ab4a5da8bb3590c4659f8f19160a7bd88a656"

MODELS="$COMFY_ROOT/models"
CN="$COMFY_ROOT/custom_nodes"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }

# -----------------------------------------------------------------------------
# 0. 前置检查
# -----------------------------------------------------------------------------
log "0/7 环境检查"

[ "$(id -u)" -eq 0 ] || { warn "非 root，后续命令可能需要 sudo"; SUDO=sudo; }
SUDO=${SUDO:-}

command -v "$PY" >/dev/null || { echo "找不到 $PY"; exit 1; }
command -v git  >/dev/null || { echo "找不到 git";   exit 1; }

if ! command -v nvidia-smi >/dev/null; then
  echo "!! 没有 nvidia-smi，这台机器没有 GPU，部署完也跑不起来"; exit 1
fi
ok "$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"

mkdir -p /workspace
AVAIL_GB=$(df -BG --output=avail /workspace 2>/dev/null | tail -1 | tr -dc '0-9')
AVAIL_GB=${AVAIL_GB:-0}
echo "    /workspace 可用空间: ${AVAIL_GB}G"
if [ "$SKIP_MODELS" != "1" ] && [ "$AVAIL_GB" -lt 55 ]; then
  echo "!! 空间不足 55G（需要 40G 权重 + 5G ComfyUI + 余量）。"
  echo "   RunPod 请在模板里把 Container Disk 调到 80G 以上；"
  echo "   Vast.ai 请把 Disk 调到 80G 以上后重新创建实例。"
  exit 1
fi

mkdir -p /workspace "$MODELS"/{diffusion_models,text_encoders,vae,loras,SEEDVR2} "$CN"

# requirements 安装器：过滤 torch 系，避免覆盖镜像自带的 CUDA 版
pip_req() {
  local f="$1" tmp="/tmp/req.$$.txt"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" \
    | grep -vEi '^(torch|torchvision|torchaudio|torchsde|xformers)([<=>!~ ]|$)' \
    > "$tmp" || true
  if [ -s "$tmp" ]; then
    echo "    pip install -r $(basename "$(dirname "$f")")/requirements.txt"
    "$PY" -m pip install -q -r "$tmp" || warn "部分依赖安装失败，通常不影响"
  fi
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# 1. 本地包（414MB）：LoRA + 本地版 vae + 工作流文档 + SeedVR2 节点快照
# -----------------------------------------------------------------------------
log "1/7 本地包（GitHub Release，414MB）"

if [ -d "$LOCAL_DIR" ] && [ -f "$LOCAL_DIR/loras/KOOK-MOSS-SFT-观澜.safetensors" ]; then
  ok "已解压，跳过下载"
else
  if [ ! -f "$ZIP_PATH" ] || [ "$(stat -c%s "$ZIP_PATH")" -lt 400000000 ]; then
    echo "    下载中 …"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$ZIP_PATH" "$ZIP_URL"
  fi
  GOT=$(sha256sum "$ZIP_PATH" | cut -d' ' -f1)
  if [ "$GOT" != "$ZIP_SHA" ]; then
    echo "!! sha256 不一致"; echo "   期望 $ZIP_SHA"; echo "   实际 $GOT"; exit 1
  fi
  ok "sha256 校验通过 ($(( $(stat -c%s "$ZIP_PATH") / 1024 / 1024 )) MB)"
  rm -rf "$LOCAL_DIR"
  # 必须用 Python 解压：unzip 会丢 UTF-8 标志，中文名变乱码
  "$PY" - "$ZIP_PATH" /workspace <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
print("    extracted ->", sys.argv[2])
PYEOF
fi
ls "$LOCAL_DIR/loras" 2>/dev/null | sed 's/^/    lora: /'

# -----------------------------------------------------------------------------
# 2. ComfyUI 本体
# -----------------------------------------------------------------------------
log "2/7 ComfyUI $COMFY_TAG"

if [ -d "$COMFY_ROOT/.git" ] && git -C "$COMFY_ROOT" describe --tags --always | grep -q "^$COMFY_TAG"; then
  ok "已安装 $(git -C "$COMFY_ROOT" describe --tags --always)"
else
  rm -rf "$COMFY_ROOT"
  git clone --filter=blob:none --quiet https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
  git -C "$COMFY_ROOT" checkout -q "$COMFY_TAG"
  ok "$(git -C "$COMFY_ROOT" describe --tags --always)"
  pip_req "$COMFY_ROOT/requirements.txt"
fi
mkdir -p "$CN"

# -----------------------------------------------------------------------------
# 3. 自定义节点
# -----------------------------------------------------------------------------
log "3/7 自定义节点"

clone_at() {
  local url="$1" name="$2" sha="$3"
  if [ -d "$CN/$name/.git" ]; then ok "$name 已存在"; return; fi
  rm -rf "$CN/$name"
  git clone --quiet "$url" "$CN/$name"
  git -C "$CN/$name" checkout -q "$sha"
  ok "$name @ ${sha:0:8}"
}

clone_at https://github.com/rgthree/rgthree-comfy.git   rgthree-comfy   "$RGTHREE_SHA"
clone_at https://github.com/kijai/ComfyUI-KJNodes.git   ComfyUI-KJNodes "$KJNODES_SHA"

SEED_DST="$CN/seedvr2_videoupscaler"
if [ -d "$SEED_DST" ]; then
  ok "seedvr2_videoupscaler 已存在"
elif [ "$SEEDVR2_REMOTE" = "1" ] || [ ! -d "$LOCAL_DIR/ComfyUI-SeedVR2_VideoUpscaler" ]; then
  clone_at https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git seedvr2_videoupscaler "$SEEDVR2_REMOTE_SHA"
else
  cp -a "$LOCAL_DIR/ComfyUI-SeedVR2_VideoUpscaler" "$SEED_DST"
  ok "seedvr2_videoupscaler（本地快照 $(grep -m1 '^version' "$SEED_DST/pyproject.toml" 2>/dev/null | cut -d'"' -f2)）"
fi

for f in "$CN"/*/requirements.txt; do pip_req "$f"; done

# -----------------------------------------------------------------------------
# 4. 六个权重（约 40G）
# -----------------------------------------------------------------------------
log "4/7 权重（约 40G）"

if [ "$SKIP_MODELS" = "1" ]; then
  warn "SKIP_MODELS=1，跳过"
else
  "$PY" -m pip install -q -U huggingface_hub || warn "huggingface_hub 升级失败，用镜像自带版本"
  "$PY" -m pip install -q hf_transfer 2>/dev/null || true

  MODELS="$MODELS" "$PY" - <<'PYEOF'
import os, sys
from huggingface_hub import hf_hub_download

MODELS = os.environ["MODELS"]
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

# (repo, repo 内路径, 本地目录, 期望大小 GB)
JOBS = [
    ("Comfy-Org/MOSS-Image", "diffusion_models/moss_image_sft_bf16.safetensors",
     f"{MODELS}", "diffusion_models/moss_image_sft_bf16.safetensors", 9.0),
    ("Comfy-Org/MOSS-Image", "diffusion_models/moss_image_sft_int8_convrot.safetensors",
     f"{MODELS}", "diffusion_models/moss_image_sft_int8_convrot.safetensors", 4.8),
    ("Comfy-Org/MOSS-Image", "text_encoders/qwen3.5_9b_int8_convrot.safetensors",
     f"{MODELS}", "text_encoders/qwen3.5_9b_int8_convrot.safetensors", 8.7),
    ("Comfy-Org/MOSS-Image", "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors",
     f"{MODELS}", "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors", 6.5),
    ("cmeka/SeedVR2-GGUF", "seedvr2_ema_7b-Q8_0.gguf",
     f"{MODELS}/SEEDVR2", "seedvr2_ema_7b-Q8_0.gguf", 7.9),
    ("numz/SeedVR2_comfyUI", "ema_vae_fp16.safetensors",
     f"{MODELS}/SEEDVR2", "ema_vae_fp16.safetensors", 0.4),
]

for i, (repo, remote, local_dir, rel, gb) in enumerate(JOBS, 1):
    dst = os.path.join(local_dir, rel)
    if os.path.isfile(dst) and os.path.getsize(dst) >= gb * 2**30:
        print(f"  [{i}/6] 已存在 {rel}")
        continue
    os.makedirs(local_dir, exist_ok=True)
    print(f"  [{i}/6] {repo} :: {remote}", flush=True)
    p = hf_hub_download(repo_id=repo, filename=remote, local_dir=local_dir)
    print(f"        ok {os.path.getsize(p)/2**30:5.2f} G -> {os.path.basename(p)}", flush=True)
PYEOF
fi

# -----------------------------------------------------------------------------
# 5. 本地独有文件就位
# -----------------------------------------------------------------------------
log "5/7 本地 LoRA / vae / 工作流文档"

place() {  # place <相对路径> <目标目录>
  local src="$LOCAL_DIR/$1" dst="$2"
  if [ -f "$src" ]; then cp -f "$src" "$dst/" && ok "$(basename "$src") -> $dst"; else warn "缺 $1"; fi
}
place "loras/KOOK-MOSS-SFT-观澜.safetensors" "$MODELS/loras"
place "vae/flux2-vae.safetensors"            "$MODELS/vae"

for f in "$LOCAL_DIR"/*.json "$LOCAL_DIR"/*.md; do
  if [ -f "$f" ]; then cp -f "$f" "$COMFY_ROOT/" && ok "$(basename "$f") -> ComfyUI/"; fi
done

# -----------------------------------------------------------------------------
# 6. 启动脚本 + 启动
# -----------------------------------------------------------------------------
log "6/7 启动 ComfyUI"

cat > /workspace/start_comfy.sh <<EOF
#!/usr/bin/env bash
# 重启 ComfyUI：bash /workspace/start_comfy.sh
pkill -f "main.py --listen" 2>/dev/null; sleep 1
cd "$COMFY_ROOT"
nohup $PY main.py --listen 0.0.0.0 --port $PORT > /workspace/comfyui.log 2>&1 &
echo "started pid=\$!  log=/workspace/comfyui.log"
EOF
chmod +x /workspace/start_comfy.sh

if curl -sf -m 3 "http://127.0.0.1:$PORT/object_info" >/dev/null 2>&1; then
  ok "已在运行，跳过启动"
else
  bash /workspace/start_comfy.sh
fi

echo -n "    等待启动"
INFO=""
for _ in $(seq 1 60); do
  sleep 3; echo -n "."
  if INFO=$(curl -sf -m 5 "http://127.0.0.1:$PORT/object_info" 2>/dev/null); then break; fi
  INFO=""
done
echo
if [ -z "$INFO" ]; then
  echo "!! ComfyUI 没起来，最后 40 行日志："
  tail -40 /workspace/comfyui.log
  exit 1
fi

# -----------------------------------------------------------------------------
# 7. 自检
# -----------------------------------------------------------------------------
log "7/7 自检"
INFO="$INFO" "$PY" - <<'PYEOF'
import json, os
info = json.loads(os.environ["INFO"])
need = ["UNETLoader", "CLIPLoader", "VAELoader", "LoraLoaderModelOnly", "EmptyFlux2LatentImage",
        "ResolutionSelector", "SkipLayerGuidanceDiTSimple", "KSampler", "INTConstant", "SaveImage",
        "SeedVR2LoadDiTModel", "SeedVR2LoadVAEModel", "SeedVR2VideoUpscaler",
        "Image Comparer (rgthree)", "Fast Groups Bypasser (rgthree)"]
missing = [n for n in need if n not in info]
print(f"  节点总数: {len(info)}")
print(f"  工作流所需 15 个节点: {'全部就位' if not missing else '缺失 ' + str(missing)}")
def opts(node, key):
    try:
        v = info[node]["input"]["required"][key][0]
        return v if isinstance(v, list) else [v]
    except Exception:
        return []
for node, key in [("UNETLoader", "unet_name"), ("CLIPLoader", "type"),
                  ("VAELoader", "vae_name"), ("LoraLoaderModelOnly", "lora_name")]:
    o = opts(node, key)
    print(f"  {node}: {o if len(o) <= 4 else o[:4] + ['...']}")
PYEOF

cat <<EOF

────────────────────────────────────────────────────────────
  ComfyUI 已启动，端口 $PORT

  RunPod ：Pods 页面 → 该 Pod → Connect → 找到 HTTP 8188 的链接
           （形如 https://<pod-id>-8188.proxy.runpod.net）
  Vast.ai：创建实例时就要把端口映射成 -p $PORT:$PORT，
           然后访问 http://<实例公网IP>:$PORT
  本地/SSH：ssh -L $PORT:127.0.0.1:$PORT root@<host> -p <ssh端口>
           然后浏览器开 http://127.0.0.1:$PORT

  日志：/workspace/comfyui.log
  重启：bash /workspace/start_comfy.sh

  打开后把「【WorkFisher】全能生图王 _ 适配所有类型.json」
  直接拖进画布即可（文件已放在 $COMFY_ROOT/）
────────────────────────────────────────────────────────────
EOF
