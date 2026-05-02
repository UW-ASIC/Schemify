cmake_minimum_required(VERSION 3.14)
project(SchemifyPlugin C)
set(CMAKE_C_STANDARD 99)

# ── Options ────────────────────────────────────────────────────────────────
set(PLUGIN_NAME "plugin"       CACHE STRING "Output library name")
set(PLUGIN_SRC  "src/plugin.c" CACHE STRING "Plugin source file(s)")

# ── Native shared library ──────────────────────────────────────────────────
add_library(${PLUGIN_NAME} SHARED ${PLUGIN_SRC})
target_include_directories(${PLUGIN_NAME} PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/inc
)
set_target_properties(${PLUGIN_NAME} PROPERTIES
    PREFIX ""                     # no "lib" prefix → plugin.so not libplugin.so
    C_VISIBILITY_PRESET hidden    # hide all symbols except SCHEMIFY_PLUGIN export
)

# ── Install to ~/.config/Schemify/<PLUGIN_NAME>/ ────────────────────────────
install(TARGETS ${PLUGIN_NAME}
    LIBRARY DESTINATION "$ENV{HOME}/.config/Schemify/${PLUGIN_NAME}"
)
