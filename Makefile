# ==============================================================================
# Makefile: Builds synvim native FFI core libraries:
#   - libsynvim_dtl.so: Deontic Temporal Logic (DTL) native trajectory engine
#   - libsynvim_anchor.so: Language-agnostic context hunk and anti-duplication engine
#   - libsynvim_search.so: Hybrid FZF/Smith-Waterman + BM25 + AST Symbol search engine
#   - libsynvim_image.so: In-memory libpng crop & Kitty graphics protocol engine
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

SEARCH_TARGET ?= $(TARGET_DIR)/libsynvim_search.so
SEARCH_SRCS = c_src/search_engine.cpp
SEARCH_HEADERS = c_src/search_engine.h

IMAGE_TARGET ?= $(TARGET_DIR)/libsynvim_image.so
IMAGE_SRCS = c_src/image_engine.cpp
IMAGE_HEADERS = c_src/image_engine.h
IMAGE_LIBS ?= -lpng -lz

ALL_TARGETS = $(DTL_TARGET) $(ANCHOR_TARGET) $(SEARCH_TARGET) $(IMAGE_TARGET)

all: $(ALL_TARGETS)

$(DTL_TARGET): $(DTL_SRCS) $(DTL_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(DTL_SRCS)
	@echo "Built $@"

$(ANCHOR_TARGET): $(ANCHOR_SRCS) $(ANCHOR_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(ANCHOR_SRCS)
	@echo "Built $@"

$(SEARCH_TARGET): $(SEARCH_SRCS) $(SEARCH_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(SEARCH_SRCS)
	@echo "Built $@"

$(IMAGE_TARGET): $(IMAGE_SRCS) $(IMAGE_HEADERS)
	@mkdir -p $(TARGET_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(IMAGE_SRCS) $(IMAGE_LIBS)
	@echo "Built $@"

install: $(ALL_TARGETS)
	@mkdir -p $(HOME)/.local/lib
	cp $(DTL_TARGET) $(HOME)/.local/lib/
	cp $(ANCHOR_TARGET) $(HOME)/.local/lib/
	cp $(SEARCH_TARGET) $(HOME)/.local/lib/
	cp $(IMAGE_TARGET) $(HOME)/.local/lib/
	@echo "Installed native libraries to $(HOME)/.local/lib/"

clean:
	rm -rf $(TARGET_DIR)

test: $(ALL_TARGETS)
	@echo "Running verification via Neovim LuaJIT FFI..."
	nvim --headless -u NONE -c 'lua package.path = "./nvim/lua/?.lua;./nvim/lua/?/init.lua;" .. package.path' \
	     -c 'lua local dtl = require("agent.dtl"); assert(dtl.is_available(), "DTL library failed to load"); print("DTL Version: " .. dtl.version())' \
	     -c 'lua local anchor = require("agent.anchor"); assert(anchor.is_available(), "Anchor library failed to load"); print("Anchor Version: " .. anchor.version())' \
	     -c 'lua local search = require("agent.search"); assert(search.is_native_available(), "Search library failed to load"); print("Search Version: " .. search.version())' \
	     -c 'lua local image = require("agent.image"); assert(image.is_available(), "Image library failed to load"); print("Image Version: " .. image.version()); print("FFI Self-Test: PASSED")' \
	     -c 'q'

.PHONY: all install clean test
