MOSS-Image + SeedVR2 部署说明
在云 GPU 上从零部署 ComfyUI v0.42.0 + MOSS-Image + SeedVR2 超分工作流，一条命令完成。
- 适用平台：RunPod / Vast.ai / 任意 Ubuntu + NVIDIA GPU 容器（需有 root 或 sudo）
- 部署脚本：deploy_moss.sh
- 脚本校验值：sha256 = 79cd60eb1277d414f1895a31742e69e789c91270a88917875e61abf06061b3fd
1. 前置要求
项目
最低
推荐
说明
GPU 显存
16 G
24 G
16 G 需用 int8 权重并给 SeedVR2 留 swap
磁盘
55 G
80 G
约 40 G 权重 + 2 G ComfyUI + 1 G 本地包 + 余量
显卡架构
Turing / Ampere
Ampere 及以上
Turing 无 bf16 硬件加速
系统
Ubuntu 20.04+
Ubuntu 22.04
需 git curl python3、可用的 nvidia-smi
端口
8188
8188
须在平台侧显式开放
脚本全程只用 --listen 0.0.0.0 直接监听平台端口，不启动任何隧道程序。
2. 一键部署
2.1 RunPod
1. Pods → Deploy，GPU 选 RTX 4090
2. 镜像 runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
3. Container Disk 改为 80 G（默认 20 G 装不下）
4. Exposed HTTP Ports 添加 8188
5. 建议挂 80 G Volume 到 /workspace，模型可跨 Pod 复用
6. 进入 Pod 的 Web Terminal 执行：
curl -fsSL https://raw.githubusercontent.com/QLANSHENG/moss-assets/main/deploy_moss.sh -o /workspace/d.sh \
  && bash /workspace/d.sh
1. 在 Connect 面板点 HTTP 8188，地址形如 https://<pod-id>-8188.proxy.runpod.net
2.2 Vast.ai
端口必须在创建实例时指定，创建后无法追加。
1. GPU 选 RTX 4090，Disk 设 80 G
2. 端口映射填 -p 8188:8188
3. 实例启动后 SSH 进去，执行与 RunPod 相同的命令：
curl -fsSL https://raw.githubusercontent.com/QLANSHENG/moss-assets/main/deploy_moss.sh -o /workspace/d.sh \
  && bash /workspace/d.sh
1. 浏览器访问 http://<实例公网IP>:8188
2.3 普通 Ubuntu 服务器
# 先确认驱动与 CUDA 正常
nvidia-smi

sudo mkdir -p /workspace && sudo chown $USER /workspace
bash deploy_moss.sh
通过 SSH 端口转发访问：
ssh -L 8188:127.0.0.1:8188 <user>@<host>
# 浏览器打开 http://127.0.0.1:8188
3. 脚本做了什么
7 个步骤，全部幂等：任意一步中断后重新执行会跳过已完成部分。
步骤
内容
产物
1
下载 414 MB 本地资源包，校验 sha256 后用 Python zipfile 解压
/workspace/moss-local/
2
克隆 ComfyUI 并切到 v0.42.0
/workspace/ComfyUI/
3
安装 3 个自定义节点
custom_nodes/
4
下载 6 个权重（约 40 G，支持断点续传）
ComfyUI/models/
5
放置 LoRA、vae、工作流文件
models/loras、models/vae、ComfyUI/
6
启动服务并生成重启脚本
/workspace/start_comfy.sh
7
自检 15 个必需节点，打印模型下拉框内容
控制台输出
3.1 组件版本
组件
版本 / commit
ComfyUI
v0.42.0
rgthree-comfy
2b9eb36d
ComfyUI-KJNodes
4dfb85dc
ComfyUI-SeedVR2_VideoUpscaler
随本地包提供 2.5.24；设 SEEDVR2_REMOTE=1 改用仓库远端 912ab4a
3.2 权重清单（约 39.1 GiB）
脚本自动下载，无需手动准备：
文件
大小
来源
diffusion_models/moss_image_sft_bf16.safetensors
9.47 G
Comfy-Org/MOSS-Image
diffusion_models/moss_image_sft_int8_convrot.safetensors
5.04 G
Comfy-Org/MOSS-Image
text_encoders/qwen3.5_9b_int8_convrot.safetensors
9.08 G
Comfy-Org/MOSS-Image
text_encoders/qwen3.5_9b_w4a8_gptq.safetensors
6.84 G
Comfy-Org/MOSS-Image
SEEDVR2/seedvr2_ema_7b-Q8_0.gguf
8.23 G
cmeka/SeedVR2-GGUF
SEEDVR2/ema_vae_fp16.safetensors
0.47 G
numz/SeedVR2_comfyUI
随本地包附带的文件（无需另外下载）：
文件
大小
loras/KOOK-MOSS-SFT-观澜.safetensors
138 MB
vae/flux2-vae.safetensors
336 MB
【WorkFisher】全能生图王 _ 适配所有类型.json
工作流
fisher-moss-prompt-expander-完整版.md
提示词文档
ComfyUI-SeedVR2_VideoUpscaler/
节点快照
4. 参数
全部通过环境变量控制，可与脚本同行或 export 后执行：
PORT=8888 bash deploy_moss.sh                    # 换端口
SKIP_MODELS=1 bash deploy_moss.sh                # 权重已存在，跳过 40 G 下载
SEEDVR2_REMOTE=1 bash deploy_moss.sh             # SeedVR2 用仓库远端版本
COMFY_ROOT=/data/ComfyUI bash deploy_moss.sh     # 换安装目录
变量
默认
说明
COMFY_ROOT
/workspace/ComfyUI
ComfyUI 安装目录
PORT
8188
监听端口
PY
python3
Python 解释器
SKIP_MODELS
0
1 时跳过权重下载
SEEDVR2_REMOTE
0
1 时改用远端 SeedVR2 节点
5. 验证
第 7 步在控制台打印三组信息，逐项核对：
节点总数: 13xx
工作流所需 15 个节点: 全部就位
UNETLoader: ['moss_image_sft_bf16.safetensors', 'moss_image_sft_int8_convrot.safetensors', ...]
15 个必需节点：
UNETLoader  CLIPLoader  VAELoader  LoraLoaderModelOnly  EmptyFlux2LatentImage
ResolutionSelector  SkipLayerGuidanceDiTSimple  KSampler  INTConstant  SaveImage
SeedVR2LoadDiTModel  SeedVR2LoadVAEModel  SeedVR2VideoUpscaler
Image Comparer (rgthree)  Fast Groups Bypasser (rgthree)
浏览器能打开页面后，把 【WorkFisher】全能生图王 _ 适配所有类型.json 拖入画布，先跑不带 SeedVR2 的分支确认 MOSS 本体出图，再开启超分。
6. 运维
tail -f /workspace/comfyui.log     # 查看日志
bash /workspace/start_comfy.sh     # 重启（会先结束旧进程）
ps aux | grep main.py              # 确认进程存在
du -sh /workspace/ComfyUI/models   # 核对权重大小
7. 故障排查
现象
原因
处理
启动即退出，提示空间不足 55 G
容器盘太小
平台侧改为 80 G 后重建实例
$'\r': command not found
脚本被转成 CRLF
用 curl 直链下载，不要从网页复制粘贴内容
git clone 卡住
GitHub 网络抖动
重新执行脚本，已完成步骤会跳过
权重下载中断
网络限速
重跑即断点续传；国内链路可 export HF_ENDPOINT=https://hf-mirror.com
自检缺 SeedVR2* 三项
本地节点快照与 ComfyUI 版本不匹配
SEEDVR2_REMOTE=1 bash deploy_moss.sh
CUDA out of memory
显存不足
改用 int8 权重、降低分辨率，或给 SeedVR2 设 blocks_to_swap
页面打不开但进程正常
端口未开放
RunPod 添加 HTTP 8188；Vast 重建实例时加 -p 8188:8188
模型下拉框为空
models/ 目录多套了一层
确认路径为 models/diffusion_models/xxx
中文文件名乱码
用 unzip 解压
脚本已用 Python zipfile；手动解压时不要用 unzip
