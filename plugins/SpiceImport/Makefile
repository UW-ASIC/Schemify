# SpiceImport — Schemify Python plugin
#
# Build native: make
# Build WASM:   make web
# Install:      make install
#
# Requires: python3-dev

PLUGIN_NAME    = SpiceImport
PLUGIN_VERSION = 0.1.0
PLUGIN_MODULE  = plugin
PLUGIN_SCRIPT  = src/plugin.py

EXTRA_INSTALL  = cp -r src/spice2schematic "$(INSTALL_DIR)/"
EXTRA_EMBED_FILES = --embed-file src/spice2schematic@/spice2schematic

include ../../tools/api/python/Makefile
