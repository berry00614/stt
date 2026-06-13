# stt — Local Speech-to-Text CLI

基于 whisper.cpp 的本地语音转写命令行工具，完全离线，macOS Apple Silicon 原生加速。

## 项目结构

```
stt/
├── stt                    # 唯一入口：Python CLI（644 行）
├── whisper.cpp/           # 上游引擎（git-ignored 的 build/ 和 models/*.bin 除外）
│   ├── build/bin/
│   │   ├── whisper-cli    # 核心转写二进制
│   │   └── whisper-server # HTTP API（可选）
│   └── models/
│       ├── ggml-small.bin         # 默认模型，466MB
│       └── download-ggml-model.sh # 下载其他模型的脚本
└── README.md
```

## 架构

- **CLI 层**：`stt`（Python stdlib only，零依赖）
- **引擎层**：`whisper-cli`（批处理）/ `whisper-server`（流式，模型常驻内存）
- **音频采集**：`ffmpeg -f avfoundation`（macOS 原生麦克风）
- **数据流**：
  - `record/file`：`ffmpeg 录音 → .wav → whisper-cli 转写 → stdout`
  - `stream`：`ffmpeg segment → chunk_N.wav → POST whisper-server:/inference → 实时输出`

## 命令

| 命令 | 用途 | 实现 |
|------|------|------|
| `stt record -d N` | 录 N 秒后转写 | ffmpeg → temp.wav → whisper-cli |
| `stt record` | 无限录音，Ctrl+C 转写 | Popen + signal handler |
| `stt file <path>` | 转写已有音频文件 | whisper-cli directly |
| `stt stream` | 实时流转写 | whisper-server 常驻 + ffmpeg segment + HTTP POST |
| `stt list-devices` | 列出麦克风设备 | ffmpeg -list_devices |

## 关键参数

- `-m MODEL` — 模型名（在 models/ 下查找）。默认 `ggml-small.bin`
- `-l LANG` — 语言：`auto`/`zh`/`en`。默认 `auto`
- `--json` — JSON 输出（含时间戳、置信度），agent 调用时必用
- `-o FILE` — 保存转写结果到文件

## Agent 集成要点

- **始终用 `--json`**：agent 需要结构化输出解析文本
- **模型选择**：small（默认，466MB，快）→ medium（1.5GB，均衡）→ large-v3-turbo（1.5GB，最佳）
- **中文场景**：加 `-l zh` 强制中文识别，避免中英混淆
- **长录音**：`record` 模式在内存中缓存整个录音，超长（>1h）建议用 `file` 模式分片处理

## 修改指南

- CLI 逻辑全在 `stt` 一个文件里，直接改
- whisper.cpp 本身不动，除非需要新功能/性能优化
- 添加新模型：`bash whisper.cpp/models/download-ggml-model.sh <name>`
- 不支持 stdin 流式转写 → 需要改上游 whisper.cpp 或改用 Python 封装
