# Schemify Plugin SDK — C++ build helper
#
# Copy inc/lib.h AND tools/api/c/inc/lib.h (as schemify_c.h) into your project.
#
#   make PLUGIN_SRC=src/plugin.cpp PLUGIN_NAME=myplugin

CXX        ?= c++
CXXFLAGS   ?= -std=c++17 -O2 -Wall -Wextra -fPIC -fvisibility=hidden
WASM_CXX   ?= clang++
WASM_FLAGS ?= --target=wasm32 --no-standard-libraries \
              -Wl,--export-dynamic -Wl,--no-entry -Wl,--allow-undefined \
              -fno-exceptions -fno-rtti

PLUGIN_SRC  ?= src/plugin.cpp
PLUGIN_NAME ?= plugin
_MKDIR      := $(dir $(lastword $(MAKEFILE_LIST)))
INC         := $(_MKDIR)inc $(_MKDIR)../c/inc

.PHONY: all native web clean install
all: native

native: $(PLUGIN_NAME).so

web: $(PLUGIN_NAME).wasm

INCS := $(addprefix -I,$(INC))

$(PLUGIN_NAME).so: $(PLUGIN_SRC)
	$(CXX) $(CXXFLAGS) -shared $(INCS) -o $@ $^

$(PLUGIN_NAME).wasm: $(PLUGIN_SRC)
	$(WASM_CXX) $(WASM_FLAGS) $(INCS) -o $@ $^

install: $(PLUGIN_NAME).so
	mkdir -p "$(HOME)/.config/Schemify/$(PLUGIN_NAME)"
	cp $(PLUGIN_NAME).so "$(HOME)/.config/Schemify/$(PLUGIN_NAME)/"

clean:
	rm -f $(PLUGIN_NAME).so $(PLUGIN_NAME).wasm
