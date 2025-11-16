# Prehistorie

Template for building interesting things in Nim. Runs natively on Linux/macOS/Windows and compiles to WebAssembly for browser deployment for easy prototyping.

[![Use this template](https://img.shields.io/badge/use%20this-template-blue?logo=github)](https://github.com/yourusername/prehistorie/generate)

## Features

- ✨ **Zero dependencies** - Pure Nim
- 🎮 **Plugin system** - Modular, extensible architecture
- 🎨 **TrueColor support** - RGB colors with 8/256-color fallback
- 🌐 **Web + Native** - Single codebase for terminal and browser
- 📦 **Double-buffered** - Smooth rendering with diff-based updates
- 🔤 **Full Unicode** - UTF-8 character support
- 📐 **Layout utilities** - Text wrapping, alignment, clipping
- 🎯 **Resize handling** - Automatic terminal size detection

## Quick Start

Simply create a repo from this template, customize prehistorie.nim and it will automatically compile for web. Enable GitHub Pages and it serves the results.

### Native Build

```bash
# Install Nim if you haven't already
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Build and run
nim c -r prehistorie.nim
```

### Web Build

```bash
# Install Emscripten
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh
cd ..

# Build
./build-simple.sh

# Serve
python3 -m http.server 8000
# Visit http://localhost:8000
```

## Architecture

The codebase uses conditional compilation to handle native vs web targets:

```nim
when defined(emscripten):
  # Web-specific code
  proc emInit(width, height: int) {.exportc.} = ...
  proc emUpdate(deltaMs: float) {.exportc.} = ...
else:
  # Native-specific code
  import posix, termios
  setupRawMode()
```

### Key Components

#### Core Types

- **`Color`** - RGB color with utilities for named colors and palette conversion
- **`Style`** - Text styling (fg/bg colors, bold, italic, underline, dim)
- **`TermBuffer`** - Character grid with clipping and offset support
- **`AppState`** - Global state container for plugins and rendering

#### Plugin System

Plugins are modules that hook into the engine lifecycle:

```nim
type PluginModule* = object
  name*: string
  initProc*: proc(state: var AppState)
  updateProc*: proc(state: var AppState, dt: float)
  renderProc*: proc(state: var AppState)
  handleInputProc*: proc(state: var AppState, key: char): bool
  shutdownProc*: proc(state: var AppState)
```

Example plugin structure:

```nim
# plugins/my_plugin.nim
import ../prehistorie

proc myInit(state: var AppState) =
  echo "Plugin initialized!"

proc myUpdate(state: var AppState, dt: float) =
  # Update game logic

proc myRender(state: var AppState) =
  state.currentBuffer.writeText(0, 0, "Hello!", state.styles["default"])

proc createMyPlugin*(): PluginModule =
  result.name = "MyPlugin"
  result.initProc = myInit
  result.updateProc = myUpdate
  result.renderProc = myRender
```

#### Web Exports

The web version exports these functions via `{.exportc.}`:

- `emInit(width, height)` - Initialize engine with terminal dimensions
- `emUpdate(deltaMs)` - Update game state (called each frame)
- `emResize(width, height)` - Handle window resize
- `emGetWidth/emGetHeight()` - Get current buffer dimensions
- `emGetCell(x, y)` - Get character at position
- `emGetCellStyle(x, y, component)` - Get style component at position
- `emHandleKey(key)` - Handle keyboard input

## Rendering Pipeline

### Native

1. `setupRawMode()` - Configure terminal for raw input
2. `getTermSize()` - Query terminal dimensions via ioctl
3. Main loop:
   - `getKey()` - Non-blocking input check
   - `updatePlugins()` - Update game state
   - `renderPlugins()` - Render to buffer
   - `display()` - Diff buffers and output ANSI codes
4. `restoreTerminal()` - Clean up on exit

### Web

1. JavaScript loads `prehistorie.wasm.js`
2. `Module.onRuntimeInitialized` → call `emInit(80, 24)`
3. `requestAnimationFrame` loop:
   - Call `emUpdate(deltaTime)`
   - Iterate buffer via `emGetCell/emGetCellStyle`
   - Render to HTML5 Canvas with proper fonts/colors
4. Event listeners pipe keyboard/resize events to Wasm

## Drawing API

### Basic Drawing

```nim
var buf = newTermBuffer(80, 24)
let style = Style(fg: green(), bg: black(), bold: true)

# Write text
buf.writeText(0, 0, "Hello, World!", style)

# Draw box
buf.drawBox(10, 5, 30, 10, style)

# Fill rectangle
buf.fillRect(5, 5, 10, 3, "█", style)

# Draw line
buf.drawLine(0, 0, 20, 0, "─", style)
```

### Text Layout

```nim
# Text wrapping
let lines = wrapText("Long text that needs wrapping...", 40)
for i, line in lines:
  buf.writeText(0, i, line, style)

# Alignment
buf.writeAligned(5, "Centered!", 80, AlignCenter, style)
```

### Clipping and Offsets

```nim
# Clip to region
buf.setClip(10, 10, 40, 20)
buf.writeText(0, 0, "This will be clipped", style)
buf.clearClip()

# Scroll offset
buf.setOffset(-10, -5)  # Shift everything
buf.writeText(10, 5, "Appears at 0,0", style)
```

## Color System

```nim
# Named colors
let c1 = red()
let c2 = blue()

# RGB
let c3 = rgb(128, 255, 64)

# Grayscale
let c4 = gray(128)

# Style with colors
let style = Style(
  fg: rgb(255, 100, 50),
  bg: black(),
  bold: true,
  italic: false
)
```

The engine automatically converts to the best available color format:

- **TrueColor** (16.7M) - Direct RGB via ANSI 38;2;R;G;B
- **256-color** - Converts to 6x6x6 color cube
- **8-color** - Converts to basic ANSI colors

## Build Targets

### Native

```bash
nim c prehistorie.nim              # Debug build
nim c -d:release prehistorie.nim   # Optimized
nim c -d:danger prehistorie.nim    # Maximum optimization
```

### WebAssembly

**Method 1: Using build script**

```bash
./build-simple.sh
```

**Method 2: Manual compilation**

```bash
nim c -d:emscripten \
  --os:linux --cpu:wasm32 \
  --cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
  --passL:"-s WASM=1 -s EXPORTED_FUNCTIONS='[...]'" \
  -o:prehistorie.wasm.js \
  prehistorie.nim
```

## Deployment

### Native

Just distribute the compiled binary. It has no runtime dependencies.

### GitHub Pages

1. Build the WebAssembly version
2. Create a repository with:
   - `index.html`
   - `prehistorie.js`
   - `prehistorie.wasm.js`
   - `prehistorie.wasm`
3. Enable GitHub Pages in repo settings
4. Visit `https://yourusername.github.io/yourrepo/`

### itch.io

1. Build WebAssembly version
2. Create a `.zip` with all web files
3. Upload to itch.io as "HTML5" project
4. Set viewport to 1200x800 (or adjust to your needs)

## Performance

### Native

- ~30 FPS cap (configurable)
- Non-blocking input via `select()`
- Diff-based rendering (only changed cells update)
- Zero allocations in hot path after init

### Web

- 60 FPS via `requestAnimationFrame`
- Canvas-based rendering with text measurement
- Full Unicode support via browser fonts
- ~1-2MB Wasm binary (can be gzipped)

## Troubleshooting

### "Emscripten not found"

Install Emscripten SDK:

```bash
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh  # Add to .bashrc for persistence
```

### "Module not loading in browser"

Check browser console. Common issues:

- Missing `prehistorie.wasm` file
- CORS errors (must serve via HTTP, not `file://`)
- Wrong paths in `prehistorie.js`

Solution: Always use a local server:

```bash
python3 -m http.server 8000
# or
npx http-server -p 8000
```

### Colors not working in terminal

Check `TERM` environment variable:

```bash
echo $TERM           # Should be xterm-256color or similar
export TERM=xterm-256color
```

For TrueColor support:

```bash
export COLORTERM=truecolor
```

## Examples

See the built-in demo (runs when no plugins loaded):

- Centered box with borders
- FPS counter
- Terminal dimensions
- Color capability detection
- Styled text examples

## License

MIT License - See code for details

## Contributing

1. Fork the repository
2. Create a plugin or feature
3. Test on both native and web
4. Submit a pull request

## Resources

- [Nim Documentation](https://nim-lang.org/docs/)
- [Emscripten Documentation](https://emscripten.org/docs/)
- [ANSI Escape Codes](https://en.wikipedia.org/wiki/ANSI_escape_code)
- [WebAssembly](https://webassembly.org/)

---

Built with ❤️ using Nim
