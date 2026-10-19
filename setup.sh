#!/usr/bin/env bash
# ==============================================================================
# setup.sh: Direct Installer for Syntra Neovim
# Provisions configuration to ~/.config/nvim and links the native lgcc compiler.
#
# Usage:
#   ./setup.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

echo "=========================================================="
echo "          Syntra Neovim Direct Setup                      "
echo "=========================================================="

echo "==> [1/4] Ensuring native lgcc compiler binary..."
if [ ! -x "$SCRIPT_DIR/bin/lgcc" ]; then
    if command -v cargo &>/dev/null; then
        echo "--> Building lgcc via cargo..."
        make -C "$SCRIPT_DIR" all
    else
        echo "ERROR: bin/lgcc is missing and cargo is not installed." >&2
        exit 1
    fi
fi

echo "==> [2/4] Deploying Neovim configuration and CLI binaries..."
mkdir -p "$TARGET_DIR"
cp -r "$SCRIPT_DIR/nvim/"* "$TARGET_DIR/"
mkdir -p "$TARGET_DIR/bin"
cp "$SCRIPT_DIR/bin/lgcc" "$TARGET_DIR/bin/lgcc"
cp "$SCRIPT_DIR/bin/tasks" "$TARGET_DIR/bin/tasks"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$TARGET_DIR/bin/agent_transcribe.py"
ln -sf tasks "$TARGET_DIR/bin/specs"
chmod +x "$TARGET_DIR/bin/lgcc" "$TARGET_DIR/bin/tasks" "$TARGET_DIR/bin/agent_transcribe.py"

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
cp "$SCRIPT_DIR/bin/lgcc" "$LOCAL_BIN/lgcc"
cp "$SCRIPT_DIR/bin/tasks" "$LOCAL_BIN/tasks"
cp "$SCRIPT_DIR/bin/agent_transcribe.py" "$LOCAL_BIN/agent_transcribe.py"
ln -sf tasks "$LOCAL_BIN/specs"
chmod +x "$LOCAL_BIN/lgcc" "$LOCAL_BIN/tasks" "$LOCAL_BIN/agent_transcribe.py"

echo "==> [3/4] Checking lazy.nvim and statusline plugins..."
LAZY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim"
if [ ! -d "$LAZY_DIR" ]; then
    echo "--> Bootstrapping lazy.nvim..."
    git clone --filter=blob:none https://github.com/folke/lazy.nvim.git --branch=stable "$LAZY_DIR" 2>/dev/null || true
fi
LUALINE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lualine.nvim"
if [ ! -d "$LUALINE_DIR" ]; then
    echo "--> Bootstrapping lualine.nvim..."
    git clone --filter=blob:none https://github.com/nvim-lualine/lualine.nvim.git "$LUALINE_DIR" 2>/dev/null || true
fi
DEVICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/nvim-web-devicons"
if [ ! -d "$DEVICONS_DIR" ]; then
    echo "--> Bootstrapping nvim-web-devicons..."
    git clone --filter=blob:none https://github.com/nvim-tree/nvim-web-devicons.git "$DEVICONS_DIR" 2>/dev/null || true
fi

echo "==> [4/4] Verifying lgcc contract and task pipeline..."
"$LOCAL_BIN/lgcc" --lint-tasks "$SCRIPT_DIR" > /dev/null

echo "=========================================================="
echo "  SUCCESS: Syntra Neovim is installed and verified!       "
echo "  Run 'nvim' to begin.                                    "
echo "=========================================================="

