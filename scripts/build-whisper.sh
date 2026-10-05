#!/bin/bash
# Builds a universal, statically linked whisper-cli (Metal embedded) into Assets/bin.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cmake >/dev/null || { echo "cmake is required: brew install cmake"; exit 1; }
[ -d vendor/whisper.cpp ] || git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git vendor/whisper.cpp
cd vendor/whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DGGML_BLAS=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build --config Release -j 8 --target whisper-cli
mkdir -p ../../Assets/bin
cp build/bin/whisper-cli ../../Assets/bin/whisper-cli
lipo -info ../../Assets/bin/whisper-cli
