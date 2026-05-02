# GMIDOptimizer — Schemify Python plugin
#
# Build native: make
# Build WASM:   make web
# Install:      make install
#
# Requires: python3-dev
# Runtime:  numpy, scipy, botorch, gpytorch, torch, scikit-learn, matplotlib

PLUGIN_NAME    = GMIDOptimizer
PLUGIN_VERSION = 0.1.0
PLUGIN_MODULE  = plugin
PLUGIN_SCRIPT  = src/plugin.py

EXTRA_INSTALL  = cp -r src/gmid_optimizer "$(INSTALL_DIR)/"
EXTRA_EMBED_FILES = --embed-file src/gmid_optimizer@/gmid_optimizer

include ../../tools/api/python/Makefile
