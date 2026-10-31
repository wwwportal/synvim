# ==============================================================================
# Makefile: synvim sovereign editor installer
# ==============================================================================

all:
	@echo "synvim is a sovereign Neovim text editor."
	@echo "Run 'make install' or './setup.sh' to deploy to ~/.config/nvim."

install:
	./setup.sh

.PHONY: all install
