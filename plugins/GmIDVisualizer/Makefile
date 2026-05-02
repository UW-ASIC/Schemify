# GmIDVisualizer — Schemify plugin (C++)
#
# Build:
#   make           → libGmIDVisualizer.so  (native)
#   make web       → GmIDVisualizer.wasm   (requires emscripten)
#   make install   → install to ~/.config/Schemify/
#   make runner    → standalone CLI (no Schemify host needed)
#   make clean     → remove build artefacts

CXX       ?= c++
CXXFLAGS  := -std=c++23 -O2 -Wall -Wextra -Wpedantic -fPIC -fvisibility=hidden \
             -fno-exceptions -fno-rtti

# Paths
SDK_INC   := ../../tools/api/c/inc
DEP_INC   := dep/include
PLUGIN_SRC := src/plugin.cpp

DEP_SRCS  := dep/src/lib.cpp \
             dep/src/plots.cpp \
             dep/src/svg.cpp \
             dep/src/model_validator.cpp \
             dep/src/plugin.cpp \
             dep/src/simulators/ngspice.cpp \
             dep/src/simulators/xyce.cpp \
             dep/src/simulators/dispatch.cpp

INCLUDES  := -I$(SDK_INC) -I$(DEP_INC)
OUTPUT    := libGmIDVisualizer.so

ALL_SRCS  := $(PLUGIN_SRC) $(DEP_SRCS)

# WASM
EMCXX      ?= em++
WASM_FLAGS := -std=c++23 -O2 -fno-exceptions -fno-rtti
WASM_OUT   := GmIDVisualizer.wasm

# --------------------------------------------------------------------------

.PHONY: all native web clean install runner

all: native

native: $(OUTPUT)

$(OUTPUT): $(ALL_SRCS)
	$(CXX) $(CXXFLAGS) -shared $(INCLUDES) -o $@ $(ALL_SRCS)

web: $(WASM_OUT)

$(WASM_OUT): $(ALL_SRCS)
	$(EMCXX) $(WASM_FLAGS) $(INCLUDES) \
		-s EXPORTED_FUNCTIONS="['_schemify_plugin']" \
		-s STANDALONE_WASM=1 \
		-s ALLOW_MEMORY_GROWTH=1 \
		-o $@ $(ALL_SRCS)

install: $(OUTPUT)
	mkdir -p "$(HOME)/.config/Schemify/GmIDVisualizer"
	cp $(OUTPUT) "$(HOME)/.config/Schemify/GmIDVisualizer/"

# Standalone runner (for testing without Schemify)
runner: dep/main.cpp $(DEP_SRCS)
	$(CXX) $(CXXFLAGS:-fvisibility=hidden=) $(INCLUDES:-I$(SDK_INC)=) -I$(DEP_INC) \
		-o gmid_runner dep/main.cpp $(DEP_SRCS)

clean:
	rm -f $(OUTPUT) $(WASM_OUT) gmid_runner
