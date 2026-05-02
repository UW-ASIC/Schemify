cmake_minimum_required(VERSION 3.14)
project(SchemifyPlugin CXX)
set(CMAKE_CXX_STANDARD 17)

set(PLUGIN_NAME  "plugin"        CACHE STRING "Output library name")
set(PLUGIN_SRC   "src/plugin.cpp" CACHE STRING "Plugin source file(s)")

add_library(${PLUGIN_NAME} SHARED ${PLUGIN_SRC})
target_include_directories(${PLUGIN_NAME} PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/inc        # C++ wrapper header
    ${CMAKE_CURRENT_LIST_DIR}/../c/inc   # C ABI header (schemify_c.h)
)
target_compile_options(${PLUGIN_NAME} PRIVATE -fvisibility=hidden)
set_target_properties(${PLUGIN_NAME} PROPERTIES
    PREFIX ""
    CXX_VISIBILITY_PRESET hidden
)

install(TARGETS ${PLUGIN_NAME}
    LIBRARY DESTINATION "$ENV{HOME}/.config/Schemify/${PLUGIN_NAME}"
)
