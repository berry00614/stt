#!/usr/bin/env bash
set -euo pipefail

WHISPER_BUILD="$(cd "${SRCROOT}/../whisper.cpp" && pwd)/build"
FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
BIN_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"

require_file() {
    if [[ ! -e "$1" ]]; then
        echo "error: Missing whisper.cpp runtime file: $1"
        echo "error: Run setup.sh or build whisper.cpp before building the app."
        exit 1
    fi
}

copy_runtime() {
    local source="$1"
    local destination="$2"
    require_file "$source"
    /bin/cp -fL "$source" "$destination"
}

/bin/mkdir -p "$FRAMEWORKS_DIR" "$BIN_DIR"

copy_runtime "$WHISPER_BUILD/src/libwhisper.1.dylib" \
    "$FRAMEWORKS_DIR/libwhisper.1.dylib"
copy_runtime "$WHISPER_BUILD/src/libwhisper.coreml.dylib" \
    "$FRAMEWORKS_DIR/libwhisper.coreml.dylib"
copy_runtime "$WHISPER_BUILD/ggml/src/libggml.0.dylib" \
    "$FRAMEWORKS_DIR/libggml.0.dylib"
copy_runtime "$WHISPER_BUILD/ggml/src/libggml-base.0.dylib" \
    "$FRAMEWORKS_DIR/libggml-base.0.dylib"
copy_runtime "$WHISPER_BUILD/ggml/src/libggml-cpu.0.dylib" \
    "$FRAMEWORKS_DIR/libggml-cpu.0.dylib"
copy_runtime "$WHISPER_BUILD/ggml/src/ggml-blas/libggml-blas.0.dylib" \
    "$FRAMEWORKS_DIR/libggml-blas.0.dylib"
copy_runtime "$WHISPER_BUILD/ggml/src/ggml-metal/libggml-metal.0.dylib" \
    "$FRAMEWORKS_DIR/libggml-metal.0.dylib"
copy_runtime "$WHISPER_BUILD/bin/whisper-cli" \
    "$BIN_DIR/whisper-cli"

for binary in "$FRAMEWORKS_DIR"/*.dylib "$BIN_DIR/whisper-cli"; do
    for build_rpath in \
        "$WHISPER_BUILD/src" \
        "$WHISPER_BUILD/ggml/src" \
        "$WHISPER_BUILD/ggml/src/ggml-blas" \
        "$WHISPER_BUILD/ggml/src/ggml-metal"; do
        /usr/bin/install_name_tool -delete_rpath "$build_rpath" "$binary" \
            2>/dev/null || true
    done
done

for library in "$FRAMEWORKS_DIR"/*.dylib; do
    /usr/bin/install_name_tool -add_rpath "@loader_path" "$library" \
        2>/dev/null || true
done

/usr/bin/install_name_tool -add_rpath "@executable_path/../../Frameworks" \
    "$BIN_DIR/whisper-cli" 2>/dev/null || true

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    for binary in "$FRAMEWORKS_DIR"/*.dylib "$BIN_DIR/whisper-cli"; do
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --preserve-metadata=identifier,entitlements,flags "$binary"
    done
fi
