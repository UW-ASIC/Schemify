# Schemify Plugin SDK — C build helper
#
# Copy inc/lib.h into your project, then:
#
#   make PLUGIN_SRC=src/plugin.c PLUGIN_NAME=myplugin
#
# Outputs:
#   myplugin.so   — native Linux/macOS shared library
#   myplugin.wasm — WASM module for Schemify web target

CC         ?= cc
CFLAGS     ?= -std=c99 -O2 -Wall -Wextra -fPIC
WASM_CC    ?= clang
WASM_FLAGS ?= --target=wasm32 --no-standard-libraries \
              -Wl,--export-dynamic -Wl,--no-entry -Wl,--allow-undefined

PLUGIN_SRC  ?= src/plugin.c
PLUGIN_NAME ?= plugin

# Resolve include dir relative to this Makefile so it works from any location.
_MKDIR := $(dir $(lastword $(MAKEFILE_LIST)))
INC    := $(_MKDIR)inc

.PHONY: all native web clean
all: native

native: $(PLUGIN_NAME).so

web: $(PLUGIN_NAME).wasm

$(PLUGIN_NAME).so: $(PLUGIN_SRC)
	$(CC) $(CFLAGS) -shared -I$(INC) -o $@ $^

$(PLUGIN_NAME).wasm: $(PLUGIN_SRC)
	$(WASM_CC) $(WASM_FLAGS) -I$(INC) -o $@ $^

# Install to ~/.config/Schemify/<PLUGIN_NAME>/
install: $(PLUGIN_NAME).so
	mkdir -p "$(HOME)/.config/Schemify/$(PLUGIN_NAME)"
	cp $(PLUGIN_NAME).so "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/"

clean:
	rm -f $(PLUGIN_NAME).so $(PLUGIN_NAME).wasm
