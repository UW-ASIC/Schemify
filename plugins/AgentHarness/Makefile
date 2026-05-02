# AgentHarness — Schemify LLM agent plugin
#
# Build native: make
# Install:      make install

PLUGIN_NAME    = AgentHarness
PLUGIN_VERSION = 0.1.0
PLUGIN_MODULE  = plugin
PLUGIN_SCRIPT  = src/plugin.py

INSTALL_DIR    = $(HOME)/.config/Schemify/plugins/AgentHarness

SDK_LIB        = ../../tools/api/python/src/lib.py

EXTRA_INSTALL  = cp -r src/*.py "$(INSTALL_DIR)/" && cp -r skills "$(INSTALL_DIR)/" && cp $(SDK_LIB) "$(INSTALL_DIR)/lib.py"

include ../../tools/api/python/Makefile
