# Vendored dependencies

## whisper.cpp

The `whisper.cpp/` directory contains a vendored copy of upstream
[ggerganov/whisper.cpp](https://github.com/ggerganov/whisper.cpp).

- Version: 1.8.6
- License: MIT (`whisper.cpp/LICENSE`)

When updating it:

1. Record the upstream release and commit in this file.
2. Replace the vendored source without copying `build/` or model binaries.
3. Run the Python tests and build both whisper.cpp and the Xcode project.
4. Verify the runtime libraries copied by
   `stt-app/scripts/embed-whisper-runtime.sh` still match the dylib names
   emitted by the new version.

The exact upstream commit for the current vendored snapshot was not recorded
when it was imported. Pinning that commit is required on the next update.
