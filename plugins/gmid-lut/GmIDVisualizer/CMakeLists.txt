cmake_minimum_required(VERSION 3.25)
project(GmIDVisualizer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

set(GMID_SOURCES
    src/svg.cpp
    src/plots.cpp
    src/lib.cpp
    src/model_validator.cpp
    src/plugin.cpp
    src/simulators/ngspice.cpp
    src/simulators/xyce.cpp
    src/simulators/dispatch.cpp
)

# --------------------------------------------------------------------------
# Shared library  (Schemify plugin)
# --------------------------------------------------------------------------

add_library(GmIDVisualizer SHARED ${GMID_SOURCES})

target_include_directories(GmIDVisualizer PUBLIC include)

target_compile_options(GmIDVisualizer PRIVATE
    -Wall -Wextra -Wpedantic
    -O2
    -fno-exceptions          # data-oriented: we use std::expected, not throw
    -fno-rtti
)

set_target_properties(GmIDVisualizer PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "GmIDVisualizer"
    POSITION_INDEPENDENT_CODE ON
)

# --------------------------------------------------------------------------
# Standalone runner  (for testing without Schemify host)
# --------------------------------------------------------------------------

add_executable(gmid_runner main.cpp ${GMID_SOURCES})

target_include_directories(gmid_runner PUBLIC include)

target_compile_options(gmid_runner PRIVATE
    -Wall -Wextra -Wpedantic
    -O2
    -fno-rtti
)
