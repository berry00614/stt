# stt — Local Speech-to-Text for macOS

基于 whisper.cpp 的本地语音转写工具，包含 Python CLI 和原生 macOS 菜单栏应用。完全离线，Apple Silicon 原生加速。

## 项目结构

```
stt/
├── stt                    # Python CLI 入口（612 行，stdlib only）
├── stt-app/               # macOS 应用（SwiftUI + AppKit）
│   ├── stt-app.xcodeproj/ # Xcode 项目（自动签名，部署目标 14.6）
│   └── stt-app/
│       ├── stt_appApp.swift           # @main 入口 + AppDelegate
│       ├── Models/
│       │   ├── AppSettings.swift      # UserDefaults 配置
│       │   └── TranscriptionChunk.swift # 流式 JSON 解析
│       ├── Services/
│       │   ├── DictationService.swift      # 一键通（录音→转写→粘贴）
│       │   ├── TranscriptionService.swift  # 实时字幕协调
│       │   ├── FileTranscriptionService.swift # 文件转写（AVFoundation→WAV→whisper-cli）
│       │   ├── AudioCaptureService.swift   # AVAudioEngine 麦克风
│       │   ├── WhisperServerManager.swift  # whisper-server 子进程管理
│       │   ├── HotkeyMonitor.swift         # Carbon 全局热键（右 Option）
│       │   ├── PasteController.swift       # CGEventPost Cmd+V 粘贴
│       │   ├── AntiHallucination.swift     # 三层幻觉过滤
│       │   └── TextNormalizer.swift        # 繁→简 + 标点规范化
│       └── Views/
│           ├── MainWindowView.swift         # 主窗口（听写/字幕/文件转写三个卡片 + 模型选择）
│           ├── MenuBarView.swift            # 菜单栏下拉菜单
│           ├── SettingsView.swift           # 设置窗口（Settings scene，在系统菜单中）
│           ├── CaptionOverlayView.swift     # 浮动字幕内容
│           ├── CaptionWindowController.swift # NSPanel 字幕窗口管理
│           ├── DictationHUDView.swift       # 录音/转写状态指示
│           └── HUDPanelController.swift     # HUD 面板管理
├── whisper.cpp/           # 上游引擎（git-ignored 的 build/ 和 models/*.bin 除外）
│   ├── build/bin/
│   │   ├── whisper-cli    # 核心转写二进制
│   │   └── whisper-server # HTTP API（流式模式必需）
│   └── models/
│       ├── ggml-small.bin         # 默认模型，466MB
│       └── download-ggml-model.sh # 下载其他模型的脚本
└── README.md
```

## 架构

### CLI 层

- **CLI**：`stt`（Python stdlib only，零依赖）
- **引擎**：`whisper-cli`（批处理）/ `whisper-server`（流式，模型常驻内存）
- **音频采集**：`ffmpeg -f avfoundation`（macOS 原生麦克风）
- **数据流**：
  - `record/file`：`ffmpeg 录音 → .wav → whisper-cli 转写 → stdout`
  - `stream`：`ffmpeg segment → chunk_N.wav → POST whisper-server:/inference → 实时输出`

### macOS App 层

- **App**：`stt-app`（SwiftUI MenuBarExtra + AppKit NSPanel）
- **引擎**：复用同一个 `whisper-server` 子进程（`Process()` 启动管理）
- **音频采集**：`AVAudioEngine` 直接采集 float32 PCM
- **热键**：Carbon `RegisterEventHotKey` 监听右 Option 键
- **粘贴**：`CGEventPost` 模拟 Cmd+V
- **数据流**：
  - `按住右 Option` 或 `主窗口点击录音按钮` → `AVAudioEngine 录音` → `whisper-cli 批处理` → `AntiHallucination + TextNormalizer` → `CGEventPost 粘贴`
  - `Start Captions` → `whisper-server 持续运行` → `TranscriptionService` → `CaptionOverlayView 浮动字幕`
  - `Transcribe File` → `选择文件` → `AVFoundation 转 WAV` → `whisper-cli` → `结果展示`
- **窗口管理**：
  - 菜单栏图标始终可见（`MenuBarExtra`）
  - **主窗口**：`Window("stt", id: "main")` — 三个功能区（听写、实时字幕、文件转写），每个区有独立模型选择器
  - 字幕窗口：`NSPanel`，`level = .screenSaver`，`nonactivatingPanel`，全屏置顶
  - HUD 面板：`NSPanel`，录音/转写状态自动显示/隐藏
  - **Settings 场景**：`Settings { SettingsView() }` — 自动添加 Preferences…（⌘,）到系统菜单，独立于主窗口
  - **Dock 自适应**：`MergeMany`（4 个 publisher）监听主窗口/字幕/HUD/Settings 状态 → 有窗口时 `.regular`（显示 Dock），仅菜单栏时 `.accessory`（隐藏 Dock）
  - 窗口打开时自动 `NSApp.activate(ignoringOtherApps:)` 带到前台
- **权限**：
  - Accessibility（检测热键 + 模拟粘贴）
  - Microphone（录音）
  - 无 App Sandbox（需要 `Process()` 启动子进程）
  - 启用了 Hardened Runtime

## CLI 命令

| 命令 | 用途 | 实现 |
|------|------|------|
| `stt record -d N` | 录 N 秒后转写 | ffmpeg → temp.wav → whisper-cli |
| `stt record` | 无限录音，Ctrl+C 转写 | Popen + signal handler |
| `stt file <path>` | 转写已有音频文件 | whisper-cli directly |
| `stt stream` | 实时流转写 | whisper-server 常驻 + ffmpeg segment + HTTP POST |
| `stt list-devices` | 列出麦克风设备 | ffmpeg -list_devices |

## 关键参数（CLI）

- `-m MODEL` — 模型名（在 models/ 下查找）。默认 `ggml-small.bin`
- `-l LANG` — 语言：`auto`/`zh`/`en`。默认 `auto`
- `--json` — JSON 输出（含时间戳、置信度），agent 调用时必用
- `-o FILE` — 保存转写结果到文件
- `-D DEVICE` — 音频输入设备（如 `:0`、`:1`）
- `-s SILENCE` — stream 模式能量阈值

## Agent 集成要点

- **始终用 `--json`**：agent 需要结构化输出解析文本
- **模型选择**：small（默认，466MB，快）→ medium（1.5GB，均衡）→ large-v3-turbo（1.5GB，最佳）
- **中文场景**：加 `-l zh` 强制中文识别，避免中英混淆
- **长录音**：`record` 模式在内存中缓存整个录音，超长（>1h）建议用 `file` 模式分片处理

## 修改指南

### CLI

- CLI 逻辑全在 `stt` 一个文件里，直接改
- whisper.cpp 本身不动，除非需要新功能/性能优化
- 添加新模型：`bash whisper.cpp/models/download-ggml-model.sh <name>`
- stream 模式通过 whisper-server + ffmpeg pipe 实现实时流式转写
- 新增 `-D` / `--device` 参数支持选择音频输入设备
- stream `--json` 输出 JSON lines（chunk / time / text）

### macOS App

- `stt_appApp.swift`：入口点，AppDelegate 管理生命周期、热键、Dock 可见性、权限提示
- `DictationService`：一键通状态机（idle → recording → transcribing → done/error → idle）。`startRecording()` 和 `stopAndTranscribe()` 为非 private，支持主窗口 UI 按钮调用
- `FileTranscriptionService`：文件转写，`selectFile()` 调用 NSOpenPanel，`transcribe()` 用 `Task.detached` + `nonisolated` 静态方法在后台完成 AVFoundation 音频转换（→ 16kHz mono WAV）和 whisper-cli 调用
- `TranscriptionService`：实时字幕协调，管理 whisper-server 启停
- `WhisperServerManager`：`Process()` 管理 whisper-server 子进程生命周期，监控健康状态
- `AntiHallucination`：三层过滤 — 能量门控、no-speech-thold 0.5、模式匹配过滤（音效描述、非 CJK 垃圾、替换字符）。`buildWAV` 为 nonisolated
- `TextNormalizer`：ICU `Hant-Hans` 繁→简转换 + 标点规范化
- `AppSettings`：`@AppStorage` 持久化配置。静态路径解析方法（`whisperCppRoot`、`whisperCliPath`、`modelsDirectory` 等）均为 nonisolated，可从后台任务安全调用
- `HotkeyMonitor`：Carbon `RegisterEventHotKey` 监听右 Option 键（kVK_RightOption）
- `PasteController`：先尝试 `NSPasteboard` + `CGEventPost Cmd+V`，失败则写剪贴板
- `MainWindowView`：主窗口内容，三个 `CardView`（听写/字幕/文件转写），每个卡片有独立模型 `Picker`（听写用 `modelName`，字幕用 `streamModelName`）
- **窗口层级**：CaptionWindowController 和 HUDPanelController 都使用 `NSPanel`（`nonactivatingPanel`、`level: .screenSaver`），不会抢焦点
- **Dock 可见性**：`AppDelegate.observeWindows()` 用 `MergeMany`（4 个 publisher）监听 `captionWindowController.isOpen`、`hudController.isOpen`、`isSettingsOpen`、`isMainWindowOpen`，动态切换 `NSApp.setActivationPolicy(.regular)` / `(.accessory)`
- **Settings 场景**：`Settings { SettingsView() }`，Preferences…（⌘,）自动出现在系统菜单栏（stt → Preferences…），不同于主窗口
- **配置**：`AppSettings` 通过 `@AppStorage` 持久化到 UserDefaults（模型名、语言、stream 参数等）
- 应用使用自动签名 + Hardened Runtime，无 App Sandbox（需要 `Process()` 和 `CGEventPost`）
- 最低部署目标 macOS 14.6
