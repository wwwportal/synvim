#!/usr/bin/env bash
# ==============================================================================
# setup.sh: Direct Installer for synvim
# Provisions configuration to ~/.config/nvim and installs CLI binaries.
#
# Usage:
#   ./setup.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
LOCAL_BIN="$HOME/.local/bin"

echo "=========================================================="
echo "          synvim Direct Setup                             "
echo "=========================================================="

echo "==> [1/3] Deploying Neovim configuration and CLI binaries..."
mkdir -p "$TARGET_DIR"

# Clean up deprecated legacy modules and orphaned binaries if upgrading
rm -f "$TARGET_DIR/lua/lgcc.lua" "$TARGET_DIR/lua/specs.lua" "$TARGET_DIR/lua/tasks.lua" "$TARGET_DIR/lua/onboarding.lua" "$TARGET_DIR/syntra_config.json"
rm -rf "$TARGET_DIR/scripts" "$TARGET_DIR/bin/lgcc" "$TARGET_DIR/bin/tasks" "$TARGET_DIR/bin/specs"
rm -f "$LOCAL_BIN/lgcc" "$LOCAL_BIN/tasks" "$LOCAL_BIN/specs"

cp -r "$SCRIPT_DIR/nvim/"* "$TARGET_DIR/"
mkdir -p "$TARGET_DIR/bin"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$TARGET_DIR/bin/agent_transcribe.py"
cp "$SCRIPT_DIR/bin/agent" "$TARGET_DIR/bin/agent"
chmod +x "$TARGET_DIR/bin/agent_transcribe.py" "$TARGET_DIR/bin/agent"

mkdir -p "$LOCAL_BIN"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$LOCAL_BIN/agent_transcribe.py"
cp "$SCRIPT_DIR/bin/agent" "$LOCAL_BIN/agent"
chmod +x "$LOCAL_BIN/agent_transcribe.py" "$LOCAL_BIN/agent"

# Build native C++ FFI engines (DTL & Anchor) if compiler is present
if command -v make >/dev/null 2>&1 && (command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1); then
    echo "--> Compiling native FFI engines (libsynvim_dtl.so & libsynvim_anchor.so)..."
    make -C "$SCRIPT_DIR" all
    mkdir -p "$HOME/.local/lib"
    cp "$SCRIPT_DIR/build/libsynvim_dtl.so" "$HOME/.local/lib/libsynvim_dtl.so"
    cp "$SCRIPT_DIR/build/libsynvim_anchor.so" "$HOME/.local/lib/libsynvim_anchor.so"
fi

echo "==> [2/3] Bootstrapping lazy.nvim and core plugins..."
LAZY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
mkdir -p "$LAZY_DIR"
clone_plugin() {
    local name="$1"
    local url="$2"
    if [ ! -d "$LAZY_DIR/$name" ]; then
        echo "--> Bootstrapping $name..."
        git clone --filter=blob:none "$url" "$LAZY_DIR/$name" 2>/dev/null || true
    fi
}
clone_plugin "lazy.nvim" "https://github.com/folke/lazy.nvim.git"
clone_plugin "plenary.nvim" "https://github.com/nvim-lua/plenary.nvim.git"
clone_plugin "lualine.nvim" "https://github.com/nvim-lualine/lualine.nvim.git"
clone_plugin "nvim-web-devicons" "https://github.com/nvim-tree/nvim-web-devicons.git"
clone_plugin "todo-comments.nvim" "https://github.com/folke/todo-comments.nvim.git"


echo "==> [3/3] Verifying configuration..."
nvim --headless -u "$TARGET_DIR/init.lua" -c "qall"

echo "=========================================================="
echo "  SUCCESS: synvim is installed and verified!              "
echo "  Run 'nvim' to begin.                                    "
echo "=========================================================="
