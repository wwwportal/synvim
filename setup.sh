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
cp -r "$SCRIPT_DIR/nvim/"* "$TARGET_DIR/"
mkdir -p "$TARGET_DIR/bin"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$TARGET_DIR/bin/agent_transcribe.py"
cp "$SCRIPT_DIR/bin/agent" "$TARGET_DIR/bin/agent"
chmod +x "$TARGET_DIR/bin/agent_transcribe.py" "$TARGET_DIR/bin/agent"

mkdir -p "$LOCAL_BIN"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$LOCAL_BIN/agent_transcribe.py"
cp "$SCRIPT_DIR/bin/agent" "$LOCAL_BIN/agent"
chmod +x "$LOCAL_BIN/agent_transcribe.py" "$LOCAL_BIN/agent"

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
clone_plugin "diffview.nvim" "https://github.com/sindrets/diffview.nvim.git"
clone_plugin "gitsigns.nvim" "https://github.com/lewis6991/gitsigns.nvim.git"

echo "==> [3/3] Verifying configuration..."
nvim --headless -u "$TARGET_DIR/init.lua" -c "qall"

echo "=========================================================="
echo "  SUCCESS: synvim is installed and verified!              "
echo "  Run 'nvim' to begin.                                    "
echo "=========================================================="
