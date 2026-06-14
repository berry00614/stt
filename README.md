# STT for Mac — Local Speech-to-Text

> A fully offline, low-latency speech-to-text tool powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Includes both a Python CLI and a native macOS menu bar app. **Zero network requests**, **sub-second latency**, with native Apple Silicon acceleration (CoreML + Metal + Accelerate).

[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://python.org)
[![macOS](https://img.shields.io/badge/macOS-14.6%2B-black)](https://apple.com)
![Apple Silicon](https://img.shields.io/badge/-Apple%20Silicon-333333?logo=apple&logoColor=white)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- **Fully Offline** — No internet connection required. Your audio never leaves your machine.
- **Low Latency** — Sliding-window streaming via whisper-server (model stays resident in memory). Text appears in under 500ms.
- **Anti-Hallucination** — Three-layer protection (energy gating, speech probability threshold, pattern-matching filter). Silence stays silent.
- **Native Acceleration** — CoreML (ANE), Metal (GPU), and Accelerate (BLAS) on all Apple Silicon chips.
- **Multi-language** — Auto-detects 99 languages including Chinese, English, Japanese, and more.
- **macOS App** — Menu bar icon, global hotkey dictation, floating live captions (NSPanel), and file transcription.
- **Agent-Friendly** — JSON output, CLI-first design, ready for integration with LLM tools.

## Quick Start

### One-Click Setup

```bash
git clone https://github.com/berry00614/stt.git ~/projects/stt
cd ~/projects/stt
bash setup.sh
```

The setup script handles everything: Homebrew dependencies, whisper.cpp compilation (CoreML + Metal + Accelerate), model download, and PATH installation.

### Manual Setup

```bash
# 1. Install system dependencies
brew install ffmpeg cmake

# 2. Build whisper.cpp
cd whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
cmake --build build -j $(sysctl -n hw.ncpu)

# 3. Download the default model (466MB)
bash models/download-ggml-model.sh small

# 4. Install the CLI wrapper to PATH
cd ..
ln -s "$(pwd)/stt" /opt/homebrew/bin/stt
```

### Dependencies

- macOS on Apple Silicon, Python 3.9+
- ffmpeg (audio capture), cmake (compilation)
- whisper.cpp (CoreML + Metal + Accelerate)

## Usage

### CLI Commands

```bash
# ── Record and transcribe ──
stt record -d 30              # Record 30 seconds, then transcribe
stt record                    # Record indefinitely, Ctrl+C to stop
stt record -d 30 -l zh        # Force Chinese recognition
stt record -D ":1" -d 10      # Specify a microphone device

# ── Transcribe an audio file ──
stt file meeting.mp3          # Supports wav/mp3/flac/ogg
stt file audio.wav --json     # JSON output with timestamps and confidence

# ── Real-time streaming ──
stt stream                    # Default: 0.5s push interval, 3s context window
stt stream -i 0.3 -c 2.0      # Low-latency mode
stt stream --json              # JSON lines output
stt stream -s 0.005            # Quiet environment (lower energy threshold)
stt stream -v                  # Debug: show RMS and raw server responses
stt stream -D ":2"             # Specify a microphone device

# ── List audio devices ──
stt list-devices               # List available microphones
```

### Streaming Tuning

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-i`, `--interval` | `0.5` | Push interval in seconds — lower means faster response |
| `-c`, `--chunk` | `3.0` | Context window in seconds — larger improves accuracy |
| `-s`, `--silence` | `0.01` | Energy threshold per 0.1s frame — sustained 0.5s above this triggers speech |
| `-l`, `--language` | `auto` | Language: `zh`, `en`, `ja`, or `auto` for auto-detect |
| `-D`, `--device` | `:0` | Audio input device; use `stt list-devices` to find yours |
| `--json` | `false` | Output JSON lines (chunk / time / text) in stream mode |
| `-v`, `--verbose` | `false` | Show per-frame RMS energy and raw server responses |

### Models

The default `ggml-small.bin` (466 MB) balances speed and accuracy for most use cases.

```bash
# Download larger models for higher accuracy
cd ~/projects/stt/whisper.cpp
bash models/download-ggml-model.sh large-v3-turbo   # 1.5 GB, highest accuracy
bash models/download-ggml-model.sh medium            # 1.5 GB, balanced
```

## macOS App

The native macOS menu bar app provides one-click voice input with a global hotkey, live captions, and file transcription — no terminal needed.

### Getting Started

1. Open `stt-app/stt-app.xcodeproj` in Xcode and press ⌘R to build and run.
2. The 🎤 icon appears in the menu bar.
3. Click the menu bar icon to access quick actions, or open the main window.
4. Choose between **Hold to dictate** (press and hold the right Option key to record, release to transcribe) or **Click to dictate** (press once to start, again to stop) in Settings.
5. Use the main window to record, start live captions, or transcribe a file.

### Features

| Feature | Description |
|---------|-------------|
| **Dictation** | Click the record button or use the right Option hotkey (hold/click mode). Auto-pastes transcribed text. |
| **Live Captions** | Floating overlay window (NSPanel) that displays real-time streaming transcriptions. |
| **File Transcription** | Select an audio file, and the app converts it (AVFoundation → WAV) and transcribes it via whisper-cli. |
| **Model Selection** | Choose separate models for dictation and live captions from the main window. |
| **Anti-Hallucination** | Three-layer filter: energy gating, speech probability threshold, and pattern-matching hallucination cleanup. |
| **Text Normalization** | Traditional → Simplified Chinese conversion (ICU Hant-Hans) and punctuation normalization. |
| **Adaptive Dock** | Dock icon appears when any window is open; hides to `.accessory` mode when only the menu bar icon is visible. |
| **Zero Dependencies** | Pure Swift stdlib + AppKit + AVFoundation — no third-party packages. |

### Permissions

| Permission | Purpose |
|------------|---------|
| **Accessibility** | Detect the right Option key press and simulate Cmd+V paste |
| **Microphone** | Record audio input |

The app will guide you through granting these permissions on first launch.

### Architecture

```
Menu Bar Icon ──── Hotkey dictation + quick actions
    │
    ▼
Main Window ──── Dictation / Live Captions / File Transcription
    │
    ├── Dictation
    │   └── Click record button or press right Option (hold/click mode)
    │       │  PCM stream (AVAudioEngine)
    │       ▼
    │    Build WAV → whisper-cli → transcribe + paste
    │
    ├── Live Captions
    │   └── whisper-server (resident in memory)
    │       │  HTTP POST /inference
    │       ▼
    │   TranscriptionService → CaptionOverlayView (floating NSPanel)
    │
    └── File Transcription
        └── Select file → AVFoundation convert to WAV → whisper-cli → result

All transcriptions pass through AntiHallucination + TextNormalizer.
```

### Building

The Xcode project uses automatic signing (`CODE_SIGN_STYLE = Automatic`) — no configuration needed to build locally. Minimum deployment target: macOS 14.6.

```bash
# Command-line build (requires Xcode 16+)
cd stt-app
xcodebuild -project stt-app.xcodeproj -scheme "STT for Mac" -configuration Release build
```

## Project Structure

```
~/projects/stt/
├── stt                        # Python CLI (stdlib only, no pip dependencies)
├── stt-app/                   # macOS menu bar app (SwiftUI + AppKit)
│   ├── stt-app.xcodeproj/     # Xcode project
│   └── stt-app/
│       ├── Models/            # AppSettings, TranscriptionChunk
│       ├── Services/          # Audio capture, transcription, hotkey, paste, anti-hallucination
│       └── Views/             # Main window, menu bar, captions, HUD, settings
├── whisper.cpp/               # whisper.cpp engine (upstream)
│   ├── build/bin/
│   │   ├── whisper-cli        # Batch transcription binary
│   │   └── whisper-server     # HTTP streaming server
│   └── models/
│       └── ggml-small.bin     # Default model
├── CLAUDE.md                  # Project documentation (for Claude Code)
└── README.md
```

## Architecture

### CLI Pipeline

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
Three-layer output guard ──► stdout
```

### Anti-Hallucination (Three Layers)

1. **Energy Gating** — Short-frame scan (5 consecutive 0.1s frames with RMS > threshold) filters transient noise.
2. **whisper no-speech-thold** — Server-side speech probability threshold at 0.5.
3. **Pattern Matching** — Filters sound-effect descriptions (`(keyboard clicking)`), non-CJK/non-Latin garbage, and replacement characters (`�`).

### Hardware Acceleration

Apple Silicon (M1–M5) automatically uses all available acceleration backends:

| Accelerator | Role |
|-------------|------|
| **CoreML** | Apple Neural Engine (encoder) |
| **Metal** | GPU inference |
| **Accelerate** | BLAS matrix operations |

Measured on M5 Max + 128 GB: small model ~80ms/inference, large-v3-turbo ~200ms/inference.

## License

MIT — whisper.cpp is MIT, the STT for Mac wrapper is MIT.
