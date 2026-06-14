# stt — Local Speech-to-Text for macOS

> 基于 whisper.cpp 的本地语音转写 CLI。**完全离线**，**亚秒级延迟**，M 系列芯片原生加速。

[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://python.org)
[![macOS](https://img.shields.io/badge/macOS-14.6%2B-black)](https://apple.com)
![Apple Silicon](https://img.shields.io/badge/-Apple%20Silicon-333333?logo=apple&logoColor=white)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org)

## 特性 Features

- **完全离线** — 零网络请求，隐私绝对安全
- **低延迟** — 滑动窗口 + whisper-server 长驻内存，<500ms 出字
- **智能抗幻觉** — 三层防护（能量门控 + 语音检测阈值 + 幻觉文本过滤），静音不抽风
- **原生加速** — CoreML + Metal + Accelerate，M5 Max 上推理 <100ms
- **Agent 友好** — JSON 输出、CLI first、可作 Claude Code skill 调用
- **多语言** — 自动检测中/英/日等 99 种语言
- **macOS 原生 App** — 菜单栏图标 + 全局快捷键听写 + 浮动字幕

## 安装

### 一键安装脚本

```bash
git clone https://github.com/berry00614/stt.git ~/projects/stt
cd ~/projects/stt
bash setup.sh
```

脚本自动完成：Homebrew 依赖 → whisper.cpp 编译（CoreML/Metal/Accelerate）→ 模型下载 → PATH 安装。

### 手动安装

```bash
# 1. 系统依赖
brew install ffmpeg cmake

# 2. 编译 whisper.cpp
cd whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
cmake --build build -j $(sysctl -n hw.ncpu)

# 3. 下载模型（466MB）
bash models/download-ggml-model.sh small

# 4. 安装到 PATH
cd ..
ln -s "$(pwd)/stt" /opt/homebrew/bin/stt
```

### 依赖

- macOS (Apple Silicon)，Python 3.9+
- ffmpeg（录音） + cmake（编译）
- whisper.cpp（CoreML + Metal + Accelerate）

## 使用

```bash
# ── 录音转写 ──
stt record -d 30                # 录 30 秒 → 转写
stt record                      # 无限录音，Ctrl+C 停
stt record -d 30 -l zh          # 强制中文
stt record -D ":1" -d 10       # 指定麦克风设备

# ── 文件转写 ──
stt file meeting.mp3            # 支持 wav/mp3/flac/ogg
stt file audio.wav --json       # JSON 输出（时间戳+置信度）

# ── 实时流 ──
stt stream                      # 默认：0.5s 推送，3s 上下文
stt stream -i 0.3 -c 2.0       # 极速模式
stt stream --json               # JSON lines 输出
stt stream -s 0.005             # 安静环境（降低能量阈值）
stt stream -v                   # 调试模式（显示 RMS 和原始响应）
stt stream -D ":2"              # 指定麦克风设备

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
| `-D`, `--device` | `:0` | 音频输入设备，`stt list-devices` 查看可用设备 |
| `--json` | `false` | stream 模式输出 JSON lines（chunk / time / text） |
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

## macOS App

除了 CLI，项目还包含 `stt-app` — 原生 macOS 菜单栏应用，提供一键语音输入（全局热键 + 实时字幕 + 自动粘贴）。

### 使用方式

1. 用 Xcode 打开 `stt-app/stt-app.xcodeproj`，Build & Run（⌘R）
2. 菜单栏出现 🎤 图标
3. 点击菜单栏图标 → **Show Main Window** → 主窗口有三个功能区
4. **按住右 Option 键** → 开始录音 → 松开 → 自动转写并粘贴到光标位置
5. 主窗口中可点击录音按钮替代热键，或启动实时字幕，或选择文件转写
6. Preferences（⌘,）在 macOS 系统菜单栏中（stt → Preferences…）

### 功能

| 功能 | 描述 |
|------|------|
| **主窗口** | 三个功能区：听写、实时字幕、文件转写 |
| **听写 Dictation** | 点击按钮录音/停止，或按住右 Option 热键，自动转写粘贴 |
| **实时字幕** | 浮动 NSPanel 窗口，置顶显示流转写结果 |
| **文件转写** | 选择音频文件 → AVFoundation 转 WAV → whisper-cli 转写 |
| **模型选择** | 主窗口中可为听写和字幕分别选择模型 |
| **抗幻觉** | 三层防护：能量门控 + 语音概率阈值 + 模式匹配过滤 |
| **文本规范化** | 繁体→简体中文转换，标点规范化 |
| **Dock 自适应** | 有窗口时显示 Dock 图标，仅菜单栏时隐藏 |
| **零依赖** | 纯 Swift stdlib + AppKit + AVFoundation，无第三方包 |

### 权限

| 权限 | 用途 |
|------|------|
| **Accessibility** | 检测右 Option 键 + 模拟 Cmd+V 粘贴 |
| **Microphone** | 录音输入 |

首次启动会自动引导授权。

### 架构

```
菜单栏图标 (MenuBarExtra) ── 快捷键听写 + 快速访问
    │
    ▼
主窗口 (MainWindowView) ── 听写 / 实时字幕 / 文件转写
    │
    ├── 听写 Dictation
    │   └── 点击录音按钮 或 按住右 Option 键
    │       │  PCM 流 (AVAudioEngine)
    │       ▼
    │   构建 WAV → whisper-cli → 转写 + 粘贴
    │
    ├── 实时字幕 Live Captions
    │   └── whisper-server 长驻内存
    │       │  HTTP POST /inference
    │       ▼
    │   TranscriptionService → CaptionOverlayView (浮动字幕)
    │
    └── 文件转写 File Transcription
        └── 选择文件 → AVFoundation 转 WAV → whisper-cli → 结果

所有转写经 AntiHallucination + TextNormalizer 过滤

Preferences (Settings scene) ── ⌘, 系统菜单，独立窗口
```

### 构建

Xcode 项目使用自动签名（`CODE_SIGN_STYLE = Automatic`），无需额外配置即可在本地运行。部署目标为至少 macOS 14.6。

```bash
# 命令行构建（需要 Xcode 16+）
cd stt-app
xcodebuild -project stt-app.xcodeproj -scheme stt-app -configuration Release build
```

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
├── stt                    # CLI 入口（Python stdlib only，零 pip 依赖）
├── stt-app/               # macOS 菜单栏应用（SwiftUI + AppKit）
│   ├── stt-app.xcodeproj/ # Xcode 项目
│   └── stt-app/
│       ├── Models/        # AppSettings, TranscriptionChunk
│       ├── Services/      # 录音、转写、热键、粘贴、抗幻觉、文件转写
│       └── Views/         # 主窗口、菜单栏、字幕、HUD、设置
├── whisper.cpp/           # whisper.cpp 引擎
│   ├── build/bin/
│   │   ├── whisper-cli       # 批处理转写
│   │   └── whisper-server   # HTTP 流式服务
│   └── models/
│       └── ggml-small.bin   # 默认模型
├── CLAUDE.md              # 项目文档
└── README.md
```

## License

MIT — whisper.cpp is MIT, stt wrapper is MIT.
