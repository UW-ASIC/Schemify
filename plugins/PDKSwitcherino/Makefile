# PDKSwitcherino — Schemify Python plugin
#
# Build native: make
# Build WASM:   make web
# Install:      make install
#
# Requires: python3-dev
# Runtime:  PySpice>=1.5, numpy, scipy

PLUGIN_NAME    = PDKSwitcherino
PLUGIN_VERSION = 0.1.0
PLUGIN_MODULE  = plugin
PLUGIN_SCRIPT  = src/plugin.py

EXTRA_INSTALL  = cp -r src/pdk_switcherino "$(INSTALL_DIR)/"
EXTRA_EMBED_FILES = --embed-file src/pdk_switcherino@/pdk_switcherino

include ../../tools/api/python/Makefile
