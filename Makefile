# ==============================================================================
# Makefile: Builds synvim native FFI core libraries:
#   - libsynvim_dtl.so: Deontic Temporal Logic (DTL) native trajectory engine
#   - libsynvim_anchor.so: Language-agnostic context hunk and anti-duplication engine
# ==============================================================================

CXX ?= g++
CXXFLAGS ?= -O3 -fPIC -std=c++20 -Wall -Wextra -Wno-unused-parameter
TARGET_DIR ?= build

DTL_TARGET ?= $(TARGET_DIR)/libsynvim_dtl.so
DTL_SRCS = c_src/dtl_engine.cpp
DTL_HEADERS = c_src/dtl_engine.h

ANCHOR_TARGET ?= $(TARGET_DIR)/libsynvim_anchor.so
ANCHOR_SRCS = c_src/anchor_engine.cpp
ANCHOR_HEADERS = c_src/anchor_engine.h

ALL_TARGETS = $(DTL_TARGET) $(ANCHOR_TARGET)

all: $(ALL_TARGETS)

$(DTL_TARGET): $(DTL_SRCS) $(DTL_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(DTL_SRCS)
	@echo "Built $@"

$(ANCHOR_TARGET): $(ANCHOR_SRCS) $(ANCHOR_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(ANCHOR_SRCS)
	@echo "Built $@"

install: $(ALL_TARGETS)
	@mkdir -p $(HOME)/.local/lib
	cp $(DTL_TARGET) $(HOME)/.local/lib/
	cp $(ANCHOR_TARGET) $(HOME)/.local/lib/
	@echo "Installed native libraries to $(HOME)/.local/lib/"

clean:
	rm -rf $(TARGET_DIR)

test: $(ALL_TARGETS)
	@echo "Running verification via Neovim LuaJIT FFI..."
	nvim --headless -u NONE -c 'lua package.path = package.path .. ";./nvim/lua/?.lua;./nvim/lua/?/init.lua"' \
	     -c 'lua local dtl = require("agent.dtl"); assert(dtl.is_available(), "DTL library failed to load"); print("DTL Version: " .. dtl.version())' \
	     -c 'lua local anchor = require("agent.anchor"); assert(anchor.is_available(), "Anchor library failed to load"); print("Anchor Version: " .. anchor.version()); print("FFI Self-Test: PASSED")' \
	     -c 'q'

.PHONY: all install clean test
