// Prehistorie Web Terminal Renderer
(function() {
    'use strict';
    
    const canvas = document.getElementById('canvas');
    const ctx = canvas.getContext('2d');
    const loading = document.getElementById('loading');
    const errorDiv = document.getElementById('error');
    
    // Terminal configuration
    const CHAR_WIDTH = 9;
    const CHAR_HEIGHT = 16;
    const COLS = 80;
    const ROWS = 24;
    
    let Module = null;
    let animationId = null;
    let lastTime = 0;
    
    // Font setup
    ctx.font = `${CHAR_HEIGHT}px 'Courier New', monospace`;
    ctx.textBaseline = 'top';
    
    function setupCanvas() {
        canvas.width = COLS * CHAR_WIDTH;
        canvas.height = ROWS * CHAR_HEIGHT;
        canvas.classList.remove('hidden');
        loading.classList.add('hidden');
    }
    
    function rgbToStyle(r, g, b) {
        return `rgb(${r},${g},${b})`;
    }
    
    function renderFrame() {
        if (!Module || !Module._emGetWidth) {
            return;
        }
        
        const width = Module._emGetWidth();
        const height = Module._emGetHeight();
        
        // Clear canvas
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        
        // Render each cell
        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                // Get cell character
                const charPtr = Module._emGetCell(x, y);
                const char = charPtr ? Module.UTF8ToString(charPtr) : ' ';
                
                // Get cell style
                const fgR = Module._emGetCellStyle(x, y, 0);
                const fgG = Module._emGetCellStyle(x, y, 1);
                const fgB = Module._emGetCellStyle(x, y, 2);
                const bgR = Module._emGetCellStyle(x, y, 3);
                const bgG = Module._emGetCellStyle(x, y, 4);
                const bgB = Module._emGetCellStyle(x, y, 5);
                const bold = Module._emGetCellStyle(x, y, 6);
                const underline = Module._emGetCellStyle(x, y, 7);
                const italic = Module._emGetCellStyle(x, y, 8);
                const dim = Module._emGetCellStyle(x, y, 9);
                
                const px = x * CHAR_WIDTH;
                const py = y * CHAR_HEIGHT;
                
                // Draw background
                if (bgR > 0 || bgG > 0 || bgB > 0) {
                    ctx.fillStyle = rgbToStyle(bgR, bgG, bgB);
                    ctx.fillRect(px, py, CHAR_WIDTH, CHAR_HEIGHT);
                }
                
                // Set font style
                let fontStyle = `${CHAR_HEIGHT}px `;
                if (italic) fontStyle = 'italic ' + fontStyle;
                if (bold) fontStyle = 'bold ' + fontStyle;
                fontStyle += "'Courier New', monospace";
                ctx.font = fontStyle;
                
                // Draw character
                let fgColor = rgbToStyle(fgR, fgG, fgB);
                if (dim) {
                    // Dim by reducing brightness
                    fgColor = rgbToStyle(
                        Math.floor(fgR * 0.5),
                        Math.floor(fgG * 0.5),
                        Math.floor(fgB * 0.5)
                    );
                }
                ctx.fillStyle = fgColor;
                ctx.fillText(char, px, py);
                
                // Draw underline
                if (underline) {
                    ctx.strokeStyle = fgColor;
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.moveTo(px, py + CHAR_HEIGHT - 2);
                    ctx.lineTo(px + CHAR_WIDTH, py + CHAR_HEIGHT - 2);
                    ctx.stroke();
                }
            }
        }
    }
    
    function gameLoop(currentTime) {
        const deltaTime = lastTime ? currentTime - lastTime : 16.67;
        lastTime = currentTime;
        
        // Update game state
        if (Module && Module._emUpdate) {
            Module._emUpdate(deltaTime);
        }
        
        // Render
        renderFrame();
        
        // Continue loop
        animationId = requestAnimationFrame(gameLoop);
    }
    
    function handleKeyPress(event) {
        if (!Module || !Module._emHandleKey) {
            return;
        }
        
        let key = event.key;
        
        // Convert special keys
        if (key === 'Escape') {
            Module._emHandleKey(0x1b); // ESC
            event.preventDefault();
            return;
        }
        
        if (key === 'Enter') {
            Module._emHandleKey(0x0d); // CR
            event.preventDefault();
            return;
        }
        
        if (key.length === 1) {
            const charCode = key.charCodeAt(0);
            Module._emHandleKey(charCode);
            event.preventDefault();
        }
    }
    
    function handleResize() {
        if (!Module || !Module._emResize) {
            return;
        }
        
        // Calculate new dimensions based on window size
        const terminalDiv = document.getElementById('terminal');
        const maxWidth = terminalDiv.clientWidth - 40;
        const maxHeight = window.innerHeight - 100;
        
        const newCols = Math.max(40, Math.floor(maxWidth / CHAR_WIDTH));
        const newRows = Math.max(20, Math.floor(maxHeight / CHAR_HEIGHT));
        
        canvas.width = newCols * CHAR_WIDTH;
        canvas.height = newRows * CHAR_HEIGHT;
        
        Module._emResize(newCols, newRows);
    }
    
    function showError(message) {
        errorDiv.textContent = 'Error: ' + message;
        errorDiv.style.display = 'block';
        loading.classList.add('hidden');
    }
    
    // WebAssembly module configuration
    window.Module = {
        preRun: [],
        postRun: [function() {
            console.log('Prehistorie module loaded');
            Module = window.Module;
            
            setupCanvas();
            
            // Initialize with default size
            if (Module._emInit) {
                Module._emInit(COLS, ROWS);
                console.log('Initialized with ' + COLS + 'x' + ROWS);
            }
            
            // Setup event listeners
            window.addEventListener('keydown', handleKeyPress);
            window.addEventListener('resize', handleResize);
            
            // Start game loop
            lastTime = 0;
            animationId = requestAnimationFrame(gameLoop);
            
            console.log('Game loop started');
        }],
        print: function(text) {
            console.log('STDOUT:', text);
        },
        printErr: function(text) {
            console.error('STDERR:', text);
        },
        canvas: canvas,
        setStatus: function(text) {
            if (text) {
                console.log('Status:', text);
                if (text.includes('Exception') || text.includes('Error')) {
                    showError(text);
                }
            }
        },
        totalDependencies: 0,
        monitorRunDependencies: function(left) {
            this.totalDependencies = Math.max(this.totalDependencies, left);
            const message = left ? 
                'Preparing... (' + (this.totalDependencies - left) + '/' + this.totalDependencies + ')' : 
                'All downloads complete.';
            console.log(message);
        },
        onRuntimeInitialized: function() {
            console.log('Runtime initialized');
        }
    };
    
    // Load the WebAssembly module
    const script = document.createElement('script');
    script.src = 'prehistorie.wasm.js';
    script.onerror = function() {
        showError('Failed to load prehistorie.wasm.js. Make sure it exists in the same directory.');
    };
    document.body.appendChild(script);
})();
