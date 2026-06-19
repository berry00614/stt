# STT for Mac — Local Speech-to-Text for macOS

基于 whisper.cpp 的本地语音转写工具，包含 Python CLI 和原生 macOS 菜单栏应用。完全离线，Apple Silicon 原生加速。

## 项目结构

```
stt/
├── stt                    # Python CLI 入口（612 行，stdlib only）
├── stt-app/               # macOS 应用（SwiftUI + AppKit）
│   ├── stt-app.xcodeproj/ # Xcode 项目（自动签名，部署目标 14.6）
│   └── stt-app/
│       ├── whisper_bridge.h          # C 桥接头（导入 whisper.h + trampoline 声明）
│       ├── whisper_bridge.c          # C callback trampoline + 原子操作 helper
│       ├── stt_appApp.swift          # @main 入口 + AppDelegate
│       ├── Models/
│       │   └── AppSettings.swift     # UserDefaults 配置（含 engine/VAD 设置）
│       ├── Services/
│       │   ├── LiveCaptionService.swift   # 实时字幕协调器（进程内 pipeline）
│       │   ├── WhisperEngine.swift        # whisper.cpp C API Swift actor 封装
│       │   ├── AudioRingBuffer.swift      # 同步 SPSC f32 PCM 环形缓冲区
│       │   ├── TranscriptOutput.swift     # @MainActor UI 桥接（displayText/isSpeaking）
│       │   ├── DictationService.swift     # 一键通（录音→转写→粘贴）
│       │   ├── FileTranscriptionService.swift # 文件转写（AVFoundation→WAV→whisper-cli）
│       │   ├── AudioCaptureService.swift  # AVAudioEngine 麦克风（f32 + Int16 双输出）
│       │   ├── HotkeyMonitor.swift        # Carbon 全局热键（右 Option）
│       │   ├── PasteController.swift      # CGEventPost Cmd+V 粘贴
│       │   ├── AntiHallucination.swift    # 幻觉过滤（VAD 能量门控 + 模式匹配）
│       │   └── TextNormalizer.swift       # 繁→简 + 标点规范化
│       └── Views/
│           ├── MainWindowView.swift         # 主窗口（听写/字幕/文件转写三个卡片 + 模型选择）
│           ├── MenuBarView.swift            # 菜单栏下拉菜单
│           ├── SettingsView.swift           # 设置窗口（Settings scene，在系统菜单中）
│           ├── CaptionOverlayView.swift     # 浮动字幕内容（ScrollView 自动滚底）
│           ├── CaptionWindowController.swift # NSPanel 字幕窗口管理
│           ├── DictationHUDView.swift       # 录音/转写状态指示
│           └── HUDPanelController.swift     # HUD 面板管理
├── whisper.cpp/           # 上游引擎（git-ignored 的 build/ 和 models/*.bin 除外）
│   ├── build/
│   │   ├── bin/
│   │   │   └── whisper-cli    # 批处理转写二进制（Dictation/File 路径用）
│   │   └── src/
│   │       └── libwhisper.dylib  # 核心库（Live Caption 直接链接）
│   └── models/
│       ├── ggml-small.bin              # 默认模型，466MB
│       ├── ggml-silero-v5.1.2.bin     # Silero VAD 模型，864KB
│       └── download-ggml-model.sh     # 下载其他模型的脚本
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

### App

- `STT for Mac` (macOS app, Xcode project at `stt-app/stt-app.xcodeproj`)
- **引擎**：Live Caption 路径使用 whisper.cpp C API 进程内直调（`whisper_init → whisper_full`）；Dictation/File 路径使用 `whisper-cli` 子进程（`Process()`）
- **音频采集**：`AVAudioEngine` 输出 16kHz mono f32 PCM（直接喂给 whisper.cpp）；同时派生 Int16 给 Dictation 兼容
- **热键**：`NSEvent.addGlobalMonitorForEvents(.flagsChanged)` 监听右 Option 键，支持 hold/click 两种模式
- **粘贴**：`CGEventPost` 模拟 Cmd+V
- **数据流**：
  - `按住右 Option 或按一下右 Option（由 dictationMode 决定）或 主窗口点击录音按钮` → `AVAudioEngine 录音` → `whisper-cli 批处理` → `AntiHallucination + TextNormalizer` → `CGEventPost 粘贴`
  - `Start Captions` → `AVAudioEngine → AudioRingBuffer → VAD (Silero) → WhisperEngine (whisper_full 滑动窗口) → TranscriptOutput → CaptionOverlayView 浮动字幕`（全部进程内，无 HTTP）
  - `Transcribe File` → `选择文件` → `AVFoundation 转 WAV` → `whisper-cli` → `结果展示`
- **窗口管理**：
  - 菜单栏图标始终可见（`MenuBarExtra`）
  - **主窗口**：`Window("STT for Mac", id: "main")` — 三个功能区（听写、实时字幕、文件转写），每个区有独立模型选择器
  - 字幕窗口：`NSPanel`，`level = .screenSaver`，`nonactivatingPanel`，全屏置顶。内嵌 `CaptionOverlayView`（`ScrollViewReader` 自动滚到底部显示最新文字）
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

- `stt_appApp.swift`：入口点，AppDelegate 管理生命周期、热键、Dock 可见性、权限提示。持有 `LiveCaptionService`、`DictationService`、`FileTranscriptionService` 三个顶层服务
- `LiveCaptionService`：实时字幕顶层协调器（`@MainActor`）。组装 `AudioCaptureService → AudioRingBuffer → WhisperEngine → TranscriptOutput`。`start()` 负责权限→模型加载→音频→引擎启动；`stop()` 负责逆序停止
- `WhisperEngine`：Swift `actor` 封装 whisper.cpp C API。管理 `whisper_context *` 生命周期（`whisper_init_from_file_with_params` / `whisper_free`）。运行滑动窗口 `whisper_full()`（默认 step=1.5s, length=10s, keep=200ms），`single_segment=true`，`no_context=false` 上下文链接。内置 Silero 神经 VAD（`whisper_vad_detect_speech_no_reset`）或能量 VAD 回退。通过 `onTranscript` / `onStateChange` / `onSpeakingChange` 回调输出结果
- `AudioRingBuffer`：同步 SPSC 环形缓冲区（`@unchecked Sendable`）。`UnsafeMutableBufferPointer<Float>` 底层存储，单个 `os_unfair_lock` 原子发布采样数据与索引，避免读取未完成写入的数据。Audio 线程写，WhisperEngine actor 读。固定容量 30s × 16kHz = 480,000 samples
- `TranscriptOutput`：`@MainActor ObservableObject`，作为 WhisperEngine（后台 actor）和 SwiftUI 之间的桥接。持有 `@Published displayText`（滚动窗口最后 8 段拼接）、`isSpeaking`、`engineState`
- `DictationService`：一键通状态机（idle → recording → transcribing → done/error → idle）。`startRecording()` 和 `stopAndTranscribe()` 为非 private，支持主窗口 UI 按钮调用。支持 hold（按住录/松开关）和 click（按一下开/按一下关）两种模式，由 `AppSettings.dictationMode` 控制
- `FileTranscriptionService`：文件转写，`selectFile()` 调用 NSOpenPanel，`transcribe()` 用 `Task.detached` + `nonisolated` 静态方法在后台完成 AVFoundation 音频转换（→ 16kHz mono WAV）和 whisper-cli 调用
- `AudioCaptureService`：AVAudioEngine 封装。输出双格式：f32 PCM（`onAudioChunkFloats` 回调 → LiveCaptionService）和 Int16 PCM（`accumulatedData` → DictationService）
- `AntiHallucination`：两层过滤 — VAD 能量门控（`hasSpeech`，5 个连续 0.1s 帧 RMS > 阈值）、模式匹配过滤（音效描述、非 CJK 垃圾、替换字符）。`hasSpeech`、`audioRMS`、`buildWAV` 均为 nonisolated
- `TextNormalizer`：ICU `Hant-Hans` 繁→简转换 + 标点规范化
- `AppSettings`：`@AppStorage` 持久化配置。实时字幕使用 `captionsStreamInterval`、`captionsWindowSeconds`、`captionsSilenceThreshold`、`vadMode`、`engineThreads` 配置原生引擎。静态路径解析方法（`whisperCppRoot`、`whisperVadModelPath`、`modelsDirectory` 等）均为 nonisolated，可从后台任务安全调用
- `HotkeyMonitor`：`NSEvent.addGlobalMonitorForEvents(.flagsChanged)` 监听右 Option 键，支持 hold（按住阈值后触发）和 click（按一下切换）两种模式
- `PasteController`：先尝试 `NSPasteboard` + `CGEventPost Cmd+V`，失败则写剪贴板
- `MainWindowView`：主窗口内容，三个 `CardView`（听写/字幕/文件转写），每个卡片有独立模型 `Picker`（听写用 `modelName`，字幕用 `streamModelName`）
- **窗口层级**：CaptionWindowController 和 HUDPanelController 都使用 `NSPanel`（`nonactivatingPanel`、`level: .screenSaver`），不会抢焦点
- **Dock 可见性**：`AppDelegate.observeWindows()` 用 `MergeMany`（4 个 publisher）监听 `captionWindowController.isOpen`、`hudController.isOpen`、`isSettingsOpen`、`isMainWindowOpen`，但 HUD 被排除在激活策略切换之外（它是 `nonactivatingPanel`，不能抢焦点）。仅当主窗口、字幕窗口或设置窗口打开时才切换到 `.regular`，否则 `.accessory`
- **Settings 场景**：`Settings { SettingsView() }`，Preferences…（⌘,）自动出现在系统菜单栏（STT for Mac → Preferences…），独立于主窗口。通过 SwiftUI `SettingsLink` 打开（而非 `NSApp.sendAction`）
- **配置**：`AppSettings` 通过 `@AppStorage` 持久化到 UserDefaults（模型名、语言、dictationMode/holdThreshold/autoPaste、stream 参数等）
- 应用使用自动签名 + Hardened Runtime，无 App Sandbox（需要 `Process()` 和 `CGEventPost`）
- 最低部署目标 macOS 14.6

## C 桥接与构建配置

- **桥接头**：`whisper_bridge.h` 在 `SWIFT_OBJC_BRIDGING_HEADER` 中配置。导入 `whisper.h`（暴露所有 whisper.cpp C API 给 Swift）。声明 callback trampoline 函数（Swift closure 不能直接作为 C 函数指针）
- **C trampoline**：`whisper_bridge.c` 实现 `whisper_segment_callback_trampoline`（从 `user_data` 提取回调函数指针并调用）和 `whisper_abort_callback_trampoline`（读取 `user_data` 指向的 abort flag）。同时提供 `ring_buffer_atomic_store/load` 原子操作 helper
- **构建设置**（`project.pbxproj` target 级别）：
  - `HEADER_SEARCH_PATHS` = `$(SRCROOT)/../whisper.cpp/include` + `$(SRCROOT)/../whisper.cpp/ggml/include`
  - `LIBRARY_SEARCH_PATHS` = `$(SRCROOT)/../whisper.cpp/build/src` + `$(SRCROOT)/../whisper.cpp/build/ggml/src`
  - `OTHER_LDFLAGS` = `-lwhisper -lggml -lggml-base -lggml-cpu`
  - `LD_RUNPATH_SEARCH_PATHS` 包含 build 目录（开发阶段直接找到 dylib）
- **VAD 模型**：`whisper.cpp/models/ggml-silero-v5.1.2.bin`（864KB），通过 `whisper_vad_init_from_file_with_params` 加载。`AppSettings.whisperVadModelPath()` 自动在 models/ 中查找。如果模型不存在，自动回退到能量 VAD
- **音频格式**：whisper.cpp 期望 16kHz f32 mono PCM。`AudioCaptureService` 通过 `AVAudioConverter` 转换为 `.pcmFormatFloat32` 输出，存入 `AudioRingBuffer`。DictationService 通过 f32→Int16 转换获得兼容数据
