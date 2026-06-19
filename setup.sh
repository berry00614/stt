#!/usr/bin/env bash
# setup.sh — 在新 Mac 上从头部署 stt
# 用法: bash setup.sh
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log()  { echo -e "${BOLD}[stt-setup]${RESET} $1"; }
ok()   { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET} $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; exit 1; }

PROJ="$(cd "$(dirname "$0")" && pwd)"
WHISPER_DIR="$PROJ/whisper.cpp"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

echo ""
log "stt 一键安装开始..."

# ── 1. 环境检查 ──
log "检查系统环境..."
[[ "$(uname -s)" == "Darwin" ]] || err "仅支持 macOS"
[[ "$(uname -m)" == "arm64" ]] || warn "非 Apple Silicon，CoreML/Metal 加速不可用"

# Python 3.9+
python3 -c 'import sys; assert sys.version_info >= (3,9)' 2>/dev/null \
    || err "需要 Python 3.9+，当前: $(python3 --version)"
ok "Python $(python3 --version)"

# Xcode CLI tools (提供 clang/cmake 编译链)
xcode-select -p &>/dev/null || {
    warn "Xcode CLI tools 未安装，正在安装..."
    xcode-select --install
    echo "安装完成后重新运行本脚本。"
    exit 0
}
ok "Xcode CLI tools"

# ── 2. 安装依赖 ──
log "检查 Homebrew 依赖..."

if ! command -v brew &>/dev/null; then
    err "请先安装 Homebrew: https://brew.sh"
fi

install_if_missing() {
    if ! command -v "$1" &>/dev/null; then
        warn "安装 $1..."
        brew install "$1"
    fi
    ok "$1 ($(command -v "$1"))"
}

install_if_missing ffmpeg
install_if_missing cmake

# ── 3. 编译 whisper.cpp ──
log "编译 whisper.cpp (CoreML + Metal + Accelerate)..."

if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    ok "whisper-cli 已存在"
    read -p "  重新编译？[y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "跳过编译。"
    else
        cmake -B "$WHISPER_DIR/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6 \
            -DWHISPER_COREML=ON \
            -DWHISPER_COREML_ALLOW_FALLBACK=ON \
            -S "$WHISPER_DIR"
        cmake --build "$WHISPER_DIR/build" -j "$(sysctl -n hw.ncpu)"
        ok "whisper.cpp 编译完成"
    fi
else
    cmake -B "$WHISPER_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6 \
        -DWHISPER_COREML=ON \
        -DWHISPER_COREML_ALLOW_FALLBACK=ON \
        -S "$WHISPER_DIR"
    cmake --build "$WHISPER_DIR/build" -j "$(sysctl -n hw.ncpu)"
    ok "whisper.cpp 编译完成"
fi

# ── 4. 下载模型 ──
log "下载默认模型 (ggml-small.bin, 466MB)..."

if [ -f "$WHISPER_DIR/models/ggml-small.bin" ]; then
    ok "ggml-small.bin 已存在"
else
    bash "$WHISPER_DIR/models/download-ggml-model.sh" small
    ok "模型下载完成"
fi

# ── 5. 安装到 PATH ──
log "安装 stt 到 PATH..."

TARGET="$BREW_PREFIX/bin/stt"
if [ -L "$TARGET" ] || [ -f "$TARGET" ]; then
    read -p "  $TARGET 已存在，覆盖？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$TARGET"
        ln -s "$PROJ/stt" "$TARGET"
        ok "已覆盖 $TARGET -> $PROJ/stt"
    else
        ok "保持 $TARGET 不变"
    fi
else
    ln -s "$PROJ/stt" "$TARGET"
    ok "$TARGET -> $PROJ/stt"
fi

# ── 验证 ──
echo ""
log "安装验证..."
if command -v stt &>/dev/null; then
    stt --help >/dev/null 2>&1 && ok "stt 运行正常" || warn "stt 可执行但有警告"
    echo ""
    echo -e "${GREEN}${BOLD}✓ 安装完成！${RESET}"
    echo ""
    echo "  快速开始:"
    echo "    stt list-devices          # 列出麦克风"
    echo "    stt stream                # 实时流式转写"
    echo "    stt record -d 10          # 录 10 秒转写"
    echo "    stt file audio.mp3        # 转写音频文件"
    echo ""
else
    err "stt 未在 PATH 中找到，请检查 $TARGET"
fi
