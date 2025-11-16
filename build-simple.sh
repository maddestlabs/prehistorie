#!/bin/bash

# Simplified build script using Nim's Emscripten support

set -e

echo "Building Prehistorie..."

# Build native version
echo ""
echo "==> Building native version..."
nim c -d:release -o:prehistorie prehistorie.nim
echo "✓ Native binary: ./prehistorie"

# Build WebAssembly version
echo ""
echo "==> Building WebAssembly version..."

# Check for Emscripten
if ! command -v emcc &> /dev/null; then
    echo "⚠ Emscripten not found. Install from: https://emscripten.org"
    echo "  git clone https://github.com/emscripten-core/emsdk.git"
    echo "  cd emsdk && ./emsdk install latest && ./emsdk activate latest"
    echo "  source ./emsdk_env.sh"
    exit 1
fi

# Use Nim's experimental emscripten backend
nim c -d:emscripten \
    --os:linux \
    --cpu:wasm32 \
    --cc:clang \
    --clang.exe:emcc \
    --clang.linkerexe:emcc \
    --passC:"-s WASM=1" \
    --passL:"-s WASM=1" \
    --passL:"-s EXPORTED_FUNCTIONS='[\"_emInit\",\"_emUpdate\",\"_emResize\",\"_emGetWidth\",\"_emGetHeight\",\"_emGetCell\",\"_emGetCellStyle\",\"_emHandleKey\",\"_main\"]'" \
    --passL:"-s EXPORTED_RUNTIME_METHODS='[\"ccall\",\"cwrap\",\"UTF8ToString\"]'" \
    --passL:"-s ALLOW_MEMORY_GROWTH=1" \
    --passL:"-s MODULARIZE=0" \
    --passL:"-s ENVIRONMENT=web" \
    --passL:"-s INITIAL_MEMORY=16MB" \
    -o:prehistorie.wasm.js \
    prehistorie.nim

if [ -f "prehistorie.wasm.js" ]; then
    echo "✓ WebAssembly build successful!"
    echo "  - prehistorie.wasm.js"
    echo "  - prehistorie.wasm"
else
    echo "✗ Build failed. Check errors above."
    exit 1
fi

echo ""
echo "==> Build complete!"
echo ""
echo "Native: ./prehistorie"
echo "Web:    python3 -m http.server 8000"
echo "        Then visit http://localhost:8000"
