#!/usr/bin/env bash
# ==============================================================================
# setup.sh: Direct Installer for synvim
# Provisions configuration to ~/.config/nvim and bootstraps plugins.
#
# Usage:
#   ./setup.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
LOCAL_BIN="$HOME/.local/bin"

echo "=========================================================="
echo "          synvim Sovereign Editor Setup                   "
echo "=========================================================="

echo "==> [1/2] Deploying Neovim configuration..."
mkdir -p "$TARGET_DIR"

# Clean up deprecated legacy modules if upgrading
rm -rf "$TARGET_DIR/lua/agent" "$TARGET_DIR/lua/agent.lua" "$TARGET_DIR/bin"
rm -f "$LOCAL_BIN/agent" "$LOCAL_BIN/agent_transcribe.py"

cp -r "$SCRIPT_DIR/nvim/"* "$TARGET_DIR/"

echo "==> [2/2] Bootstrapping lazy.nvim and core plugins..."
if command -v nvim >/dev/null 2>&1; then
    nvim --headless "+Lazy! sync" +qa 2>/dev/null || true
    echo "--> Plugins synchronized."
fi

echo "=========================================================="
echo "  synvim installed successfully!                          "
echo "  Launch with: nvim                                       "
echo "=========================================================="
