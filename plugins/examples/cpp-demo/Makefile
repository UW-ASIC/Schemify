# Schemify Plugin — C++ demo
#
# Uses the raw C API (works with both C and C++ code).
# For the C++ wrapper class, see tools/api/cpp/inc/lib.h.
#
# Build native: make
# Build WASM:   make web
# Install:      make install

PLUGIN_NAME = cpp-demo
PLUGIN_SRC  = src/plugin.cpp

# Use the C Makefile since the demo uses the C API directly.
# Override compiler to C++.
CC         = c++
CFLAGS     = -std=c++17 -O2 -Wall -Wextra -fPIC -fvisibility=hidden

include ../../../tools/api/c/Makefile
