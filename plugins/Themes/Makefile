# Themes — Schemify Python plugin
#
# Build native: make
# Build WASM:   make web
# Install:      make install
#
# Requires: python3-dev

PLUGIN_NAME    = Themes
PLUGIN_VERSION = 0.1.0
PLUGIN_MODULE  = plugin
PLUGIN_SCRIPT  = src/plugin.py

EXTRA_INSTALL  = cp -r themes "$(INSTALL_DIR)/"
EXTRA_EMBED_FILES = --embed-file themes@/themes

include ../../tools/api/python/Makefile
