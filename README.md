# stt — Local Speech-to-Text for macOS

> 基于 whisper.cpp 的本地语音转写 CLI。**完全离线**，**亚秒级延迟**，M 系列芯片原生加速。

[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://python.org)
[![macOS](https://img.shields.io/badge/macOS-Sequoia%2B-black)](https://apple.com)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M5_Max-orange)](https://apple.com)

## 特性

- 🔒 **完全离线** — 零网络请求，隐私绝对安全
- ⚡ **亚秒级延迟** — 滑动窗口 + whisper-server 长驻内存，<500ms 出字
- 🧠 **智能抗幻觉** — 三层防护（能量门控 + 语音检测阈值 + 幻觉文本过滤），静音不抽风
- 🖥️ **原生加速** — CoreML + Metal + Accelerate，M5 Max 上推理 <100ms
- 🤖 **Agent 友好** — JSON 输出、CLI first、可作 Claude Code skill 调用
- 🌐 **多语言** — 自动检测中/英/日等 99 种语言

## 安装

```bash
# 已全局安装
which stt  # /opt/homebrew/bin/stt

# 依赖：ffmpeg + whisper.cpp (CoreML/Metal/Accelerate)
```

## 使用

```bash
# ── 录音转写 ──
stt record -d 30                # 录 30 秒 → 转写
stt record                      # 无限录音，Ctrl+C 停
stt record -d 30 -l zh          # 强制中文

# ── 文件转写 ──
stt file meeting.mp3            # 支持 wav/mp3/flac/ogg
stt file audio.wav --json       # JSON 输出（时间戳+置信度）

# ── 实时流 ──
stt stream                      # 默认：0.5s 推送，3s 上下文
stt stream -i 0.3 -c 2.0       # 极速模式
stt stream -s 0.005             # 安静环境（降低能量阈值）
stt stream -v                   # 调试模式（显示 RMS 和原始响应）

# ── 设备 ──
stt list-devices                # 列出可用麦克风
```

## 实时流转写调优

| 参数 | 默认 | 作用 |
|------|------|------|
| `-i`, `--interval` | `0.5` | 推送间隔（秒），越低反应越快 |
| `-c`, `--chunk` | `3.0` | 会话上下文窗口（秒），越大精度越高 |
| `-s`, `--silence` | `0.01` | 能量阈值，0.1s 帧 RMS 超过此值且持续 0.5s 才识别为语音 |
| `-l`, `--language` | `auto` | 语言：`zh`/`en`/`ja`/`auto` |
| `-v`, `--verbose` | `false` | 显示每帧 RMS 能量和 server 原始响应 |

## 模型

默认 `ggml-small.bin`（466MB），速度与精度的甜点。

```bash
# 下载更大模型
cd ~/projects/stt/whisper.cpp
bash models/download-ggml-model.sh large-v3-turbo   # 1.5GB，最高精度
bash models/download-ggml-model.sh medium            # 1.5GB，均衡
```

## 架构

```
ffmpeg (avfoundation)
    │  raw s16le PCM pipe
    ▼
accumulating ring buffer
    │  build WAV + POST every 0.5s
    ▼
whisper-server (model loaded once, resident)
    │  POST /inference → {"text": "..."}
    ▼
三层输出防护 ──► stdout
```

### 三层抗幻觉

1. **能量门控** — 短时帧扫描 (0.1s × 5 连续帧 > 0.01 RMS)，过滤瞬时噪音
2. **whisper no-speech-thold** — server 侧语音概率阈值 0.5
3. **幻觉文本过滤** — 识别音效描述 `(keyboard clicking)`、非拉丁/CJK 脚本垃圾、替换字符 `�`

## 硬件加速

Apple Silicon (M1–M5) 自动启用全部加速后端：

| 加速器 | 用途 |
|--------|------|
| **CoreML** | Apple Neural Engine（编码器） |
| **Metal** | GPU 推理 |
| **Accelerate** | BLAS 矩阵运算 |

M5 Max + 128GB 实测：small 模型推理 ~80ms/次，large-v3-turbo ~200ms/次。

## Claude Code Skill

已注册为 `/stt` skill。在对话中说「帮我转写这段录音」即可触发。

```bash
# Agent 调用规范
stt record -d 30 --json    # 始终用 --json
stt file audio.mp3 -l zh   # 中文文件显式指定语言
```

## 项目结构

```
~/projects/stt/
├── stt                  # CLI 入口（Python stdlib only，零 pip 依赖）
├── whisper.cpp/         # whisper.cpp 引擎
│   ├── build/bin/
│   │   ├── whisper-cli       # 批处理转写
│   │   └── whisper-server   # HTTP 流式服务
│   └── models/
│       └── ggml-small.bin   # 默认模型
├── CLAUDE.md            # 项目文档
└── README.md
```

## License

MIT — whisper.cpp is MIT, stt wrapper is MIT.
