#!/bin/bash

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

# Fix the double .wasm.wasm extension
if [ -f "prehistorie.wasm.wasm" ]; then
    echo "✓ Renaming: prehistorie.wasm.wasm → prehistorie.wasm"
    mv prehistorie.wasm.wasm prehistorie.wasm
fi

# Fix references in the .js file
if [ -f "prehistorie.wasm.js" ]; then
    echo "✓ Fixing .wasm references in prehistorie.wasm.js"
    
    # Replace all occurrences of .wasm.wasm with .wasm in the JS file
    # Use different approaches for macOS (BSD sed) vs Linux (GNU sed)
    if sed --version 2>&1 | grep -q GNU; then
        # GNU sed (Linux)
        sed -i 's/prehistorie\.wasm\.wasm/prehistorie.wasm/g' prehistorie.wasm.js
    else
        # BSD sed (macOS)
        sed -i '' 's/prehistorie\.wasm\.wasm/prehistorie.wasm/g' prehistorie.wasm.js
    fi
    
    # Verify the fix worked
    if grep -q "prehistorie\.wasm\.wasm" prehistorie.wasm.js; then
        echo "⚠ Warning: Some .wasm.wasm references may still remain"
    else
        echo "✓ All references updated to prehistorie.wasm"
    fi
fi

# Verify build succeeded
if [ -f "prehistorie.wasm.js" ] && [ -f "prehistorie.wasm" ]; then
    echo ""
    echo "✓ WebAssembly build successful!"
    echo "  - prehistorie.wasm.js (Emscripten glue, $(ls -lh prehistorie.wasm.js | awk '{print $5}'))"
    echo "  - prehistorie.wasm (WebAssembly binary, $(ls -lh prehistorie.wasm | awk '{print $5}'))"
else
    echo ""
    echo "✗ Build failed. Check errors above."
    if [ ! -f "prehistorie.wasm.js" ]; then
        echo "  Missing: prehistorie.wasm.js"
    fi
    if [ ! -f "prehistorie.wasm" ]; then
        echo "  Missing: prehistorie.wasm"
    fi
    exit 1
fi

echo ""
echo "==> Build complete!"
echo ""
echo "Native: ./prehistorie"
echo "Web:    python3 -m http.server 8000"
echo "        Then visit http://localhost:8000"