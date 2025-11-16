import strutils, times, parseopt, os, tables
when not defined(emscripten):
  import posix, termios

const version = "0.1.0"

type
  Color* = object
    r*, g*, b*: uint8
  
  Style* = object
    fg*: Color
    bg*: Color
    bold*: bool
    underline*: bool
    italic*: bool
    dim*: bool

  Cell = object
    ch: string
    style: Style

  TermBuffer* = object
    width*, height*: int
    cells: seq[Cell]
    clipX*, clipY*, clipW*, clipH*: int  # Clipping region
    offsetX*, offsetY*: int  # Scroll offset

  Alignment* = enum
    AlignLeft, AlignCenter, AlignRight

  PluginModule* = object
    name*: string
    initProc*: proc(state: var AppState) {.nimcall.}
    updateProc*: proc(state: var AppState, dt: float) {.nimcall.}
    renderProc*: proc(state: var AppState) {.nimcall.}
    handleInputProc*: proc(state: var AppState, key: char): bool {.nimcall.}  # Returns true if handled
    shutdownProc*: proc(state: var AppState) {.nimcall.}

  AppState* = object
    running*: bool
    termWidth*, termHeight*: int
    currentBuffer*: TermBuffer
    previousBuffer*: TermBuffer
    frameCount*: int
    totalTime*: float
    fps*: float
    lastFpsUpdate*: float
    colorSupport*: int
    styles*: Table[string, Style]
    plugins*: seq[PluginModule]
    pluginData*: Table[string, pointer]  # For plugins to store custom data

when not defined(emscripten):
  var oldTermios: Termios
  var globalRunning {.global.} = true

# Color utilities
proc rgb*(r, g, b: uint8): Color =
  Color(r: r, g: g, b: b)

proc gray*(level: uint8): Color =
  rgb(level, level, level)

proc toAnsi256*(c: Color): int =
  ## Convert RGB to closest ANSI 256 color
  # Use the 216-color cube (16-231)
  let r = int(c.r) * 5 div 255
  let g = int(c.g) * 5 div 255
  let b = int(c.b) * 5 div 255
  return 16 + 36 * r + 6 * g + b

proc toAnsi8*(c: Color): int =
  ## Convert RGB to closest ANSI 8 color
  let bright = (int(c.r) + int(c.g) + int(c.b)) div 3 > 128
  var code = 30
  if c.r > 128: code += 1
  if c.g > 128: code += 2
  if c.b > 128: code += 4
  if bright and code == 30: code = 37  # White instead of black for bright
  return code

# Named colors
proc black*(): Color = rgb(0, 0, 0)
proc red*(): Color = rgb(255, 0, 0)
proc green*(): Color = rgb(0, 255, 0)
proc yellow*(): Color = rgb(255, 255, 0)
proc blue*(): Color = rgb(0, 0, 255)
proc magenta*(): Color = rgb(255, 0, 255)
proc cyan*(): Color = rgb(0, 255, 255)
proc white*(): Color = rgb(255, 255, 255)

# Default styles
proc initDefaultStyles*(): Table[string, Style] =
  result = initTable[string, Style]()
  result["default"] = Style(fg: white(), bg: black(), bold: false)
  result["heading"] = Style(fg: yellow(), bg: black(), bold: true)
  result["error"] = Style(fg: red(), bg: black(), bold: true)
  result["success"] = Style(fg: green(), bg: black(), bold: true)
  result["info"] = Style(fg: cyan(), bg: black(), bold: false)
  result["warning"] = Style(fg: yellow(), bg: black(), bold: false)
  result["dim"] = Style(fg: gray(128), bg: black(), dim: true)
  result["highlight"] = Style(fg: black(), bg: yellow(), bold: true)
  result["border"] = Style(fg: cyan(), bg: black(), bold: false)

# Terminal setup
proc detectColorSupport(): int =
  when defined(emscripten):
    return 16777216
  else:
    let colorterm = getEnv("COLORTERM")
    if colorterm in ["truecolor", "24bit"]:
      return 16777216
    let term = getEnv("TERM")
    if "256color" in term:
      return 256
    if term in ["xterm", "screen", "linux"]:
      return 8
    return 0

proc setupRawMode() =
  when not defined(emscripten):
    discard tcGetAttr(STDIN_FILENO, addr oldTermios)
    var raw = oldTermios
    # Don't disable ISIG - we want Ctrl+C to work
    raw.c_lflag = raw.c_lflag and not(ECHO or ICANON or IEXTEN)
    raw.c_iflag = raw.c_iflag and not(IXON or ICRNL or BRKINT or INPCK or ISTRIP)
    raw.c_oflag = raw.c_oflag and not(OPOST)
    raw.c_cc[VMIN] = 0.char
    raw.c_cc[VTIME] = 0.char
    discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)

proc restoreTerminal() =
  when not defined(emscripten):
    discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr oldTermios)
    stdout.write("\e[2J\e[H\e[?25h\e[0m")
    stdout.flushFile()
    # Make sure we're really done
    stdout.write("\n")
    stdout.flushFile()

proc hideCursor() =
  when not defined(emscripten):
    stdout.write("\e[?25l")
    stdout.flushFile()

proc getTermSize(): (int, int) =
  when defined(emscripten):
    return (80, 24)
  else:
    var ws: IOctl_WinSize
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, addr ws) != -1:
      return (ws.ws_col.int, ws.ws_row.int)
    return (80, 24)

proc getKey(): char =
  when defined(emscripten):
    return '\0'
  else:
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(STDIN_FILENO, fds)
    var tv = Timeval(tv_sec: posix.Time(0), tv_usec: 0)
    if select(STDIN_FILENO + 1, addr fds, nil, nil, addr tv) > 0:
      var c: char
      if read(STDIN_FILENO, addr c, 1) == 1:
        return c
    return '\0'

# Buffer operations
proc newTermBuffer*(w, h: int): TermBuffer =
  result.width = w
  result.height = h
  result.cells = newSeq[Cell](w * h)
  result.clipX = 0
  result.clipY = 0
  result.clipW = w
  result.clipH = h
  result.offsetX = 0
  result.offsetY = 0
  let defaultStyle = Style(fg: white(), bg: black(), bold: false)
  for i in 0 ..< result.cells.len:
    result.cells[i] = Cell(ch: " ", style: defaultStyle)

proc setClip*(tb: var TermBuffer, x, y, w, h: int) =
  ## Set clipping region for rendering
  tb.clipX = max(0, x)
  tb.clipY = max(0, y)
  tb.clipW = min(w, tb.width - tb.clipX)
  tb.clipH = min(h, tb.height - tb.clipY)

proc clearClip*(tb: var TermBuffer) =
  ## Reset clipping to full buffer
  tb.clipX = 0
  tb.clipY = 0
  tb.clipW = tb.width
  tb.clipH = tb.height

proc setOffset*(tb: var TermBuffer, x, y: int) =
  ## Set scroll offset for rendering
  tb.offsetX = x
  tb.offsetY = y

proc write*(tb: var TermBuffer, x, y: int, ch: string, style: Style) =
  ## Write a single character with clipping and offset
  let screenX = x + tb.offsetX
  let screenY = y + tb.offsetY
  
  # Check clipping bounds
  if screenX < tb.clipX or screenX >= tb.clipX + tb.clipW:
    return
  if screenY < tb.clipY or screenY >= tb.clipY + tb.clipH:
    return
  
  # Check buffer bounds
  if screenX >= 0 and screenX < tb.width and screenY >= 0 and screenY < tb.height:
    let idx = screenY * tb.width + screenX
    tb.cells[idx] = Cell(ch: ch, style: style)

proc writeText*(tb: var TermBuffer, x, y: int, text: string, style: Style) =
  ## Write text with UTF-8 support, clipping, and offset
  var currentX = x
  var i = 0
  while i < text.len:
    let b = text[i].ord
    var charLen = 1
    var ch = ""
    
    # UTF-8 handling
    if (b and 0x80) == 0:
      ch = $text[i]
    elif (b and 0xE0) == 0xC0 and i + 1 < text.len:
      ch = text[i..i+1]
      charLen = 2
    elif (b and 0xF0) == 0xE0 and i + 2 < text.len:
      ch = text[i..i+2]
      charLen = 3
    elif (b and 0xF8) == 0xF0 and i + 3 < text.len:
      ch = text[i..i+3]
      charLen = 4
    else:
      ch = "?"
    
    tb.write(currentX, y, ch, style)
    currentX += 1
    i += charLen

proc fillRect*(tb: var TermBuffer, x, y, w, h: int, ch: string, style: Style) =
  ## Fill rectangle with character and style
  for dy in 0 ..< h:
    for dx in 0 ..< w:
      tb.write(x + dx, y + dy, ch, style)

proc drawBox*(tb: var TermBuffer, x, y, w, h: int, style: Style, double: bool = false) =
  ## Draw a box with unicode characters
  if w < 2 or h < 2:
    return
  
  let (tl, tr, bl, br, horiz, vert) = if double:
    ("╔", "╗", "╚", "╝", "═", "║")
  else:
    ("┌", "┐", "└", "┘", "─", "│")
  
  # Corners
  tb.write(x, y, tl, style)
  tb.write(x + w - 1, y, tr, style)
  tb.write(x, y + h - 1, bl, style)
  tb.write(x + w - 1, y + h - 1, br, style)
  
  # Horizontal lines
  for i in 1 ..< w - 1:
    tb.write(x + i, y, horiz, style)
    tb.write(x + i, y + h - 1, horiz, style)
  
  # Vertical lines
  for i in 1 ..< h - 1:
    tb.write(x, y + i, vert, style)
    tb.write(x + w - 1, y + i, vert, style)

proc drawLine*(tb: var TermBuffer, x1, y1, x2, y2: int, ch: string, style: Style) =
  ## Draw a line (horizontal or vertical only for now)
  if y1 == y2:
    # Horizontal
    let startX = min(x1, x2)
    let endX = max(x1, x2)
    for x in startX..endX:
      tb.write(x, y1, ch, style)
  elif x1 == x2:
    # Vertical
    let startY = min(y1, y2)
    let endY = max(y1, y2)
    for y in startY..endY:
      tb.write(x1, y, ch, style)

proc clear*(tb: var TermBuffer) =
  let defaultStyle = Style(fg: white(), bg: black(), bold: false)
  for i in 0 ..< tb.cells.len:
    tb.cells[i] = Cell(ch: " ", style: defaultStyle)

# Text layout utilities
proc wrapText*(text: string, maxWidth: int): seq[string] =
  ## Wrap text to fit within maxWidth
  result = @[]
  if maxWidth <= 0:
    return
  
  var currentLine = ""
  let words = text.split(' ')
  
  for word in words:
    if currentLine.len + word.len + 1 <= maxWidth:
      if currentLine.len > 0:
        currentLine.add(" ")
      currentLine.add(word)
    else:
      if currentLine.len > 0:
        result.add(currentLine)
      currentLine = word
      # Handle words longer than maxWidth
      if currentLine.len > maxWidth:
        result.add(currentLine)
        currentLine = ""
  
  if currentLine.len > 0:
    result.add(currentLine)

proc getAlignedX*(text: string, containerWidth: int, align: Alignment): int =
  ## Calculate X position for aligned text
  case align
  of AlignLeft:
    return 0
  of AlignCenter:
    return max(0, (containerWidth - text.len) div 2)
  of AlignRight:
    return max(0, containerWidth - text.len)

proc writeAligned*(tb: var TermBuffer, y: int, text: string, containerWidth: int, 
                   align: Alignment, style: Style) =
  ## Write text with specified alignment
  let x = getAlignedX(text, containerWidth, align)
  tb.writeText(x, y, text, style)

# Display
proc colorsEqual(a, b: Color): bool =
  a.r == b.r and a.g == b.g and a.b == b.b

proc stylesEqual(a, b: Style): bool =
  colorsEqual(a.fg, b.fg) and colorsEqual(a.bg, b.bg) and
  a.bold == b.bold and a.underline == b.underline and
  a.italic == b.italic and a.dim == b.dim

proc cellsEqual(a, b: Cell): bool =
  a.ch == b.ch and stylesEqual(a.style, b.style)

proc buildStyleCode(style: Style, colorSupport: int): string =
  result = "\e["
  var codes: seq[string] = @["0"]
  
  if style.bold: codes.add("1")
  if style.dim: codes.add("2")
  if style.italic: codes.add("3")
  if style.underline: codes.add("4")
  
  # Foreground color
  case colorSupport
  of 16777216:  # TrueColor
    codes.add("38;2;" & $style.fg.r & ";" & $style.fg.g & ";" & $style.fg.b)
  of 256:
    codes.add("38;5;" & $toAnsi256(style.fg))
  else:
    codes.add($toAnsi8(style.fg))
  
  # Background color
  if not (style.bg.r == 0 and style.bg.g == 0 and style.bg.b == 0):
    case colorSupport
    of 16777216:
      codes.add("48;2;" & $style.bg.r & ";" & $style.bg.g & ";" & $style.bg.b)
    of 256:
      codes.add("48;5;" & $toAnsi256(style.bg))
    else:
      codes.add($(toAnsi8(style.bg) + 10))
  
  result.add(codes.join(";") & "m")

proc display*(tb: var TermBuffer, prev: var TermBuffer, colorSupport: int) =
  when defined(emscripten):
    discard  # Web rendering handled by JS
  else:
    var output = ""
    let sizeChanged = prev.width != tb.width or prev.height != tb.height
    
    if sizeChanged:
      output.add("\e[2J")
      prev = newTermBuffer(tb.width, tb.height)
    
    for y in 0 ..< tb.height:
      var x = 0
      while x < tb.width:
        let idx = y * tb.width + x
        let cell = tb.cells[idx]
        
        if not sizeChanged and prev.cells.len > 0 and idx < prev.cells.len and
           cellsEqual(prev.cells[idx], cell):
          x += 1
          continue
        
        # Find run of cells with same style
        var runLength = 1
        while x + runLength < tb.width:
          let nextIdx = idx + runLength
          let nextCell = tb.cells[nextIdx]
          
          if not sizeChanged and prev.cells.len > 0 and nextIdx < prev.cells.len and
             cellsEqual(prev.cells[nextIdx], nextCell):
            break
          
          if not cellsEqual(cell, nextCell):
            if stylesEqual(nextCell.style, cell.style):
              runLength += 1
            else:
              break
          else:
            runLength += 1
        
        # Position cursor and apply style
        output.add("\e[" & $(y + 1) & ";" & $(x + 1) & "H")
        output.add(buildStyleCode(cell.style, colorSupport))
        
        # Write characters
        for i in 0 ..< runLength:
          output.add(tb.cells[idx + i].ch)
        
        x += runLength
    
    stdout.write(output)
    stdout.flushFile()

# Plugin system
proc registerPlugin*(state: var AppState, plugin: PluginModule) =
  state.plugins.add(plugin)
  if not plugin.initProc.isNil:
    plugin.initProc(state)

proc updatePlugins*(state: var AppState, deltaTime: float) =
  for plugin in state.plugins:
    if not plugin.updateProc.isNil:
      plugin.updateProc(state, deltaTime)

proc renderPlugins*(state: var AppState) =
  for plugin in state.plugins:
    if not plugin.renderProc.isNil:
      plugin.renderProc(state)

proc shutdownPlugins*(state: var AppState) =
  for plugin in state.plugins:
    if not plugin.shutdownProc.isNil:
      plugin.shutdownProc(state)

# Default demo rendering
proc renderDemo(state: var AppState) =
  state.currentBuffer.clear()
  
  let boxW = min(60, state.termWidth - 4)
  let boxH = min(14, state.termHeight - 4)
  let boxX = max(0, (state.termWidth - boxW) div 2)
  let boxY = max(0, (state.termHeight - boxH) div 2)
  
  if boxW >= 10 and boxH >= 8:
    state.currentBuffer.drawBox(boxX, boxY, boxW, boxH, state.styles["border"])
  
  # Title
  state.currentBuffer.writeAligned(boxY - 2, "PREHISTORIE", state.termWidth, AlignCenter, state.styles["heading"])
  state.currentBuffer.writeAligned(boxY - 1, "Terminal Engine", state.termWidth, AlignCenter, state.styles["info"])
  
  # Content inside box
  var contentY = boxY + 2
  let contentWidth = boxW - 4
  let contentX = boxX + 2
  
  let dimText = "Terminal: " & $state.termWidth & " × " & $state.termHeight
  state.currentBuffer.writeAligned(contentY, dimText, state.termWidth, AlignCenter, state.styles["default"])
  contentY += 2
  
  let fpsText = "FPS: " & formatFloat(state.fps, ffDecimal, 1)
  state.currentBuffer.writeAligned(contentY, fpsText, state.termWidth, AlignCenter, state.styles["success"])
  contentY += 1
  
  let frameText = "Frame: " & $state.frameCount
  state.currentBuffer.writeAligned(contentY, frameText, state.termWidth, AlignCenter, state.styles["info"])
  contentY += 1
  
  let timeText = "Time: " & formatFloat(state.totalTime, ffDecimal, 2) & "s"
  state.currentBuffer.writeAligned(contentY, timeText, state.termWidth, AlignCenter, state.styles["default"])
  contentY += 2
  
  # Color support
  let colorText = case state.colorSupport
    of 16777216: "Colors: TrueColor (16.7M)"
    of 256: "Colors: 256-color"
    of 8: "Colors: 8-color"
    else: "Colors: Monochrome"
  state.currentBuffer.writeAligned(contentY, colorText, state.termWidth, AlignCenter, state.styles["warning"])
  contentY += 2
  
  # Instructions
  state.currentBuffer.writeAligned(contentY, "Press Ctrl+C to exit", state.termWidth, AlignCenter, state.styles["dim"])

proc showHelp() =
  echo """prehistorie v""", version, """

Minimal terminal rendering engine with plugin system.

Usage:
  prehistorie [options]

Options:
  -h, --help       Show this help message
  -v, --version    Show version information

Controls:
  Ctrl+C / ESC     Exit (default, plugins may override)

Features:
  • Zero dependencies (pure Nim + stdlib)
  • Module-based plugin system
  • Double-buffered rendering
  • Terminal resize handling
  • Full Unicode support
  • RGB color support with fallback (8/256/truecolor)
  • Text wrapping and alignment
  • Clipping and offset rendering
  • Named style system
  • Native and Web compilation targets

Plugin Development:
  Create a module that exports:
    - proc init*(state: var AppState) - called once at startup
    - proc update*(state: var AppState, dt: float) - called each frame
    - proc render*(state: var AppState) - called each frame
    - proc shutdown*(state: var AppState) - called at exit
  
  Register with: state.registerPlugin(PluginModule(...))
"""
  quit(0)

when not defined(emscripten):
  proc signalHandler(sig: cint) {.noconv.} =
    globalRunning = false

# Web exports
when defined(emscripten):
  var globalState: AppState
  
  proc emInit(width, height: int) {.exportc.} =
    globalState.termWidth = width
    globalState.termHeight = height
    globalState.currentBuffer = newTermBuffer(width, height)
    globalState.previousBuffer = newTermBuffer(width, height)
    globalState.colorSupport = detectColorSupport()
    globalState.styles = initDefaultStyles()
    globalState.running = true
  
  proc emUpdate(deltaMs: float) {.exportc.} =
    let dt = deltaMs / 1000.0
    globalState.totalTime += dt
    globalState.frameCount += 1
    
    if globalState.totalTime - globalState.lastFpsUpdate >= 0.5:
      globalState.fps = 1.0 / dt
      globalState.lastFpsUpdate = globalState.totalTime
    
    updatePlugins(globalState, dt)
    
    swap(globalState.currentBuffer, globalState.previousBuffer)
    renderPlugins(globalState)
    if globalState.plugins.len == 0:
      renderDemo(globalState)
  
  proc emResize(width, height: int) {.exportc.} =
    globalState.termWidth = width
    globalState.termHeight = height
    globalState.currentBuffer = newTermBuffer(width, height)
    globalState.previousBuffer = newTermBuffer(width, height)
  
  proc emGetWidth(): int {.exportc.} =
    return globalState.currentBuffer.width
  
  proc emGetHeight(): int {.exportc.} =
    return globalState.currentBuffer.height
  
  proc emGetCell(x, y: int): cstring {.exportc.} =
    ## Get cell character at position
    if x < 0 or x >= globalState.currentBuffer.width or
       y < 0 or y >= globalState.currentBuffer.height:
      return ""
    let idx = y * globalState.currentBuffer.width + x
    return globalState.currentBuffer.cells[idx].ch.cstring
  
  proc emGetCellStyle(x, y: int, component: int): int {.exportc.} =
    ## Get style component: 0=fg.r, 1=fg.g, 2=fg.b, 3=bg.r, 4=bg.g, 5=bg.b, 6=bold, 7=underline, 8=italic, 9=dim
    if x < 0 or x >= globalState.currentBuffer.width or
       y < 0 or y >= globalState.currentBuffer.height:
      return 0
    let idx = y * globalState.currentBuffer.width + x
    let style = globalState.currentBuffer.cells[idx].style
    case component
    of 0: return style.fg.r.int
    of 1: return style.fg.g.int
    of 2: return style.fg.b.int
    of 3: return style.bg.r.int
    of 4: return style.bg.g.int
    of 5: return style.bg.b.int
    of 6: return if style.bold: 1 else: 0
    of 7: return if style.underline: 1 else: 0
    of 8: return if style.italic: 1 else: 0
    of 9: return if style.dim: 1 else: 0
    else: return 0
  
  proc emHandleKey(key: char) {.exportc.} =
    ## Handle keyboard input from browser
    if key == '\x1b':  # ESC
      globalState.running = false
    # Plugin input handling
    for plugin in globalState.plugins:
      if not plugin.handleInputProc.isNil:
        if plugin.handleInputProc(globalState, key):
          break  # Plugin handled the input

proc main() =
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": showHelp()
      of "version", "v":
        echo "prehistorie version ", version
        quit(0)
      else: discard
    of cmdArgument: discard
    else: discard
  
  when not defined(emscripten):
    var state = AppState()
    state.colorSupport = detectColorSupport()
    state.styles = initDefaultStyles()
    state.pluginData = initTable[string, pointer]()
    
    setupRawMode()
    hideCursor()
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    
    let (w, h) = getTermSize()
    state.termWidth = w
    state.termHeight = h
    state.currentBuffer = newTermBuffer(w, h)
    state.previousBuffer = newTermBuffer(w, h)
    state.running = true
    
    # Example: Import and register plugins
    # Uncomment these lines after creating plugins/input_handler.nim:
    # import plugins/input_handler
    # state.registerPlugin(createInputHandlerPlugin())
    
    var lastTime = epochTime()
    
    try:
      while state.running and globalRunning:
        # Check signal first
        if not globalRunning:
          break
          
        let currentTime = epochTime()
        let deltaTime = currentTime - lastTime
        lastTime = currentTime
        
        # Check for input (ESC to exit)
        let key = getKey()
        if key == '\x1b':  # ESC
          state.running = false
          break
        
        # Check for terminal resize
        let (newW, newH) = getTermSize()
        if newW != state.termWidth or newH != state.termHeight:
          state.termWidth = newW
          state.termHeight = newH
          state.currentBuffer = newTermBuffer(newW, newH)
          state.previousBuffer = newTermBuffer(newW, newH)
          stdout.write("\e[2J\e[H")
          stdout.flushFile()
        
        # Update
        state.totalTime += deltaTime
        state.frameCount += 1
        
        if state.totalTime - state.lastFpsUpdate >= 0.5:
          state.fps = 1.0 / deltaTime
          state.lastFpsUpdate = state.totalTime
        
        updatePlugins(state, deltaTime)
        
        # Render
        swap(state.currentBuffer, state.previousBuffer)
        renderPlugins(state)
        
        # If no plugins registered, show demo
        if state.plugins.len == 0:
          renderDemo(state)
        
        state.currentBuffer.display(state.previousBuffer, state.colorSupport)
        
        # Cap at ~30 FPS
        let frameTime = epochTime() - currentTime
        const targetFrameTime = 1.0 / 30.0
        let sleepTime = targetFrameTime - frameTime
        if sleepTime > 0:
          sleep(int(sleepTime * 1000))
        
        # Check if signal was caught during sleep
        if not globalRunning:
          break
    finally:
      shutdownPlugins(state)
      restoreTerminal()

when isMainModule:
  main()