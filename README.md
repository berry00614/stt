# stt — Local Speech-to-Text for macOS

基于 [whisper.cpp](https://github.com/ggerganov/whisper.cpp) 的本地语音转写命令行工具，完全离线运行，支持中英文。

## 安装

```bash
# 已安装到 /opt/homebrew/bin/stt，全局可用
# 依赖：ffmpeg, whisper.cpp (CoreML + Metal + Accelerate)
```

## 使用

```bash
# 录音并转写（指定时长）
stt record -d 30

# 无限录音，Ctrl+C 停止后转写
stt record

# 转写已有音频文件
stt file recording.mp3

# 实时流转写（实验性）
stt stream

# 列出麦克风设备
stt list-devices

# JSON 输出（含时间戳、置信度），方便 agent 解析
stt record -d 10 --json
stt file audio.mp3 --json

# 指定语言
stt record -d 10 -l zh      # 中文
stt record -d 10 -l en      # 英文
stt record -d 10 -l auto    # 自动检测（默认）
```

## 模型

默认使用 `ggml-small.bin`（466MB，速度与精度均衡）。

下载更大模型以获得更高精度：
```bash
cd ~/projects/stt/whisper.cpp
bash models/download-ggml-model.sh large-v3-turbo   # ~1.5GB，推荐
bash models/download-ggml-model.sh medium            # ~1.5GB
bash models/download-ggml-model.sh small             # 466MB（默认）
```

使用指定模型：
```bash
stt record -m ggml-large-v3-turbo.bin -d 30
```

## 架构

```
~/projects/stt/
├── stt                    # CLI 入口（Python）
├── whisper.cpp/           # whisper.cpp 引擎
│   ├── build/bin/
│   │   ├── whisper-cli    # 核心转写二进制
│   │   └── whisper-server # HTTP 服务（可选）
│   └── models/
│       └── ggml-small.bin # 当前模型
└── README.md
```

## 硬件加速

M5 Max / Apple Silicon 上自动启用：
- **CoreML** — Apple Neural Engine 推理
- **Metal** — GPU 加速
- **Accelerate** — BLAS 矩阵运算

## Agent 集成

作为 Claude Code skill 使用：
```bash
# 在 agent 中调用
stt record -d 30 --json | jq -r '.text'
```
