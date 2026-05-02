# Schemify Plugin SDK — Python build helper
#
# Builds a native .so (embeds CPython) or a .wasm (via Emscripten + cpython-wasm).
# The Python module must define:
#
#   def schemify_process(in_bytes: bytes) -> bytes
#
# Usage from a plugin Makefile:
#
#   PLUGIN_NAME    = my-plugin
#   PLUGIN_MODULE  = plugin
#   PLUGIN_SCRIPT  = plugin.py
#   include ../../../tools/api/python/Makefile
#
# Targets:
#   make          Build native .so  (requires: python3-dev)
#   make web      Build .wasm       (requires: emscripten + cpython-wasm sysroot)
#   make install  Install .so + .py to ~/.config/Schemify/<name>/
#
# WASM prerequisites:
#   - Emscripten SDK (emcc on PATH)
#   - CPython built for wasm32-emscripten (set CPYTHON_WASM to its sysroot)
#     e.g. from: https://github.com/nicolo-ribaudo/pyodide-build-standalone
#     or build with: ./configure --host=wasm32-unknown-emscripten --build=$(uname -m)-linux-gnu

CC         ?= cc
CFLAGS     ?= -O2 -Wall -Wextra -fPIC

PLUGIN_NAME    ?= plugin
PLUGIN_VERSION ?= 0.1.0
PLUGIN_MODULE  ?= plugin
PLUGIN_SCRIPT  ?= plugin.py

INSTALL_DIR    ?= $(HOME)/.config/Schemify/$(PLUGIN_NAME)

# Resolve paths relative to this Makefile.
_MKDIR  := $(dir $(lastword $(MAKEFILE_LIST)))
BRIDGE  := $(_MKDIR)bridge.c

# Native: link against system CPython.
PY_CFLAGS  := $(shell python3-config --cflags --embed 2>/dev/null || python3-config --cflags)
PY_LDFLAGS := $(shell python3-config --ldflags --embed 2>/dev/null || python3-config --ldflags)

# WASM: Emscripten + cpython-wasm sysroot.
EMCC           ?= emcc
CPYTHON_WASM   ?= $(HOME)/.local/share/cpython-wasm
WASM_PY_INC    ?= $(CPYTHON_WASM)/include/python3.13
WASM_PY_LIB    ?= $(CPYTHON_WASM)/lib/libpython3.13.a

.PHONY: all native web clean install

all: native

native: $(PLUGIN_NAME).so

web: $(PLUGIN_NAME).wasm

# ── Native .so ────────────────────────────────────────────────────────────

$(PLUGIN_NAME).so: $(BRIDGE) $(PLUGIN_SCRIPT)
	$(CC) $(CFLAGS) -shared $(PY_CFLAGS) \
		-DPLUGIN_NAME='"$(PLUGIN_NAME)"' \
		-DPLUGIN_VERSION='"$(PLUGIN_VERSION)"' \
		-DPLUGIN_MODULE='"$(PLUGIN_MODULE)"' \
		-o $@ $(BRIDGE) $(PY_LDFLAGS) -ldl

# ── WASM (Emscripten + embedded CPython) ──────────────────────────────────

$(PLUGIN_NAME).wasm: $(BRIDGE) $(PLUGIN_SCRIPT)
	@command -v $(EMCC) >/dev/null 2>&1 || \
		{ echo "Error: emcc not found. Install Emscripten SDK."; exit 1; }
	@test -f "$(WASM_PY_LIB)" || \
		{ echo "Error: cpython-wasm not found at $(CPYTHON_WASM)"; \
		  echo "Set CPYTHON_WASM to your wasm32-emscripten CPython sysroot."; exit 1; }
	$(EMCC) -O2 \
		-I"$(WASM_PY_INC)" \
		-DPLUGIN_NAME='"$(PLUGIN_NAME)"' \
		-DPLUGIN_VERSION='"$(PLUGIN_VERSION)"' \
		-DPLUGIN_MODULE='"$(PLUGIN_MODULE)"' \
		-s EXPORTED_FUNCTIONS="['_schemify_plugin','_python_bridge_process']" \
		-s ALLOW_MEMORY_GROWTH=1 \
		-s STANDALONE_WASM=1 \
		--embed-file $(PLUGIN_SCRIPT)@/$(PLUGIN_MODULE).py \
		$(EXTRA_EMBED_FILES) \
		-o $@ $(BRIDGE) "$(WASM_PY_LIB)"

# ── Install ───────────────────────────────────────────────────────────────

install: $(PLUGIN_NAME).so
	mkdir -p "$(INSTALL_DIR)"
	cp $(PLUGIN_NAME).so "$(INSTALL_DIR)/"
	cp $(PLUGIN_SCRIPT) "$(INSTALL_DIR)/$(PLUGIN_MODULE).py"
	cp "$(_MKDIR)src/lib.py" "$(INSTALL_DIR)/schemify_sdk.py"
	$(EXTRA_INSTALL)

# ── Clean ─────────────────────────────────────────────────────────────────

clean:
	rm -f $(PLUGIN_NAME).so $(PLUGIN_NAME).wasm
