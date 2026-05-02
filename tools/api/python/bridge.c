/*
 * bridge.c — CPython bridge for Schemify plugins  (ABI v7)
 *
 * Embeds the Python interpreter in a .so and delegates the plugin
 * process call to a Python function:
 *
 *   def schemify_process(in_bytes: bytes) -> bytes
 *
 * Configure via preprocessor defines:
 *   PLUGIN_NAME     Plugin name string       (default: "python-plugin")
 *   PLUGIN_VERSION  Plugin version string    (default: "0.1.0")
 *   PLUGIN_MODULE   Python module to import  (default: "plugin")
 *
 * The bridge locates the Python script in the same directory as the .so
 * using dladdr, then prepends that directory to sys.path.
 *
 * Build:
 *   cc -shared -fPIC $(python3-config --cflags --embed) \
 *      -DPLUGIN_NAME='"demo"' -DPLUGIN_VERSION='"0.1.0"' \
 *      -o libdemo.so bridge.c $(python3-config --ldflags --embed) -ldl
 */

#define _GNU_SOURCE
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#ifndef __EMSCRIPTEN__
#include <dlfcn.h>
#include <libgen.h>
#endif
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* ── Plugin ABI ────────────────────────────────────────────────────────── */

#define SCHEMIFY_ABI_VERSION 8

#ifndef PLUGIN_NAME
#define PLUGIN_NAME "python-plugin"
#endif
#ifndef PLUGIN_VERSION
#define PLUGIN_VERSION "0.1.0"
#endif
#ifndef PLUGIN_MODULE
#define PLUGIN_MODULE "plugin"
#endif

typedef size_t (*SchemifyProcessFn)(
    const uint8_t*, size_t, uint8_t*, size_t);

typedef struct {
    uint32_t          abi_version;
    const char*       name;
    const char*       version_str;
    SchemifyProcessFn process;
} SchemifyDescriptor;

/* ── Internals ─────────────────────────────────────────────────────────── */

static PyObject* g_process_fn = NULL;
static int       g_init_done  = 0;

/* Return the directory containing this .so (or "/" for WASM). */
static const char* self_dir(void) {
#ifdef __EMSCRIPTEN__
    return "/";  /* Embedded files live at root in Emscripten VFS. */
#else
    static char buf[4096];
    Dl_info info;
    if (dladdr((const void*)self_dir, &info) && info.dli_fname) {
        strncpy(buf, info.dli_fname, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        char* d = dirname(buf);
        if (d != buf) memmove(buf, d, strlen(d) + 1);
        return buf;
    }
    return ".";
#endif
}

static void init_python(void) {
    if (g_init_done) return;
    g_init_done = 1;

    if (!Py_IsInitialized()) Py_Initialize();

    /* Prepend plugin directory (and its src/ subdirectory) to sys.path. */
    const char* pdir = self_dir();
    PyObject* sys_path = PySys_GetObject("path");
    if (sys_path) {
        PyObject* d = PyUnicode_DecodeFSDefault(pdir);
        if (d) { PyList_Insert(sys_path, 0, d); Py_DECREF(d); }

        char src_dir[4096];
        snprintf(src_dir, sizeof(src_dir), "%s/src", pdir);
        PyObject* sd = PyUnicode_DecodeFSDefault(src_dir);
        if (sd) { PyList_Insert(sys_path, 1, sd); Py_DECREF(sd); }
    }

    /* Import the plugin module and grab schemify_process. */
    PyObject* mod = PyImport_ImportModule(PLUGIN_MODULE);
    if (!mod) { PyErr_Print(); return; }

    g_process_fn = PyObject_GetAttrString(mod, "schemify_process");
    Py_DECREF(mod);

    if (!g_process_fn || !PyCallable_Check(g_process_fn)) {
        fprintf(stderr, "[%s] '%s' has no callable schemify_process\n",
                PLUGIN_NAME, PLUGIN_MODULE);
        Py_XDECREF(g_process_fn);
        g_process_fn = NULL;
    }
}

/* ── Process entry point ───────────────────────────────────────────────── */

static size_t python_bridge_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    init_python();
    if (!g_process_fn) return (size_t)-1;

    /* GIL is already held — we never release it (single-threaded bridge). */

    PyObject* arg = PyBytes_FromStringAndSize((const char*)in_ptr,
                                              (Py_ssize_t)in_len);
    if (!arg) { return (size_t)-1; }

    PyObject* res = PyObject_CallOneArg(g_process_fn, arg);
    Py_DECREF(arg);

    if (!res)              { PyErr_Print(); return (size_t)-1; }
    if (!PyBytes_Check(res)) { Py_DECREF(res); return (size_t)-1; }

    Py_ssize_t rlen = PyBytes_GET_SIZE(res);
    if ((size_t)rlen > out_cap) { Py_DECREF(res); return (size_t)-1; }

    memcpy(out_ptr, PyBytes_AS_STRING(res), (size_t)rlen);
    Py_DECREF(res);
    return (size_t)rlen;
}

/* ── Exported descriptor ───────────────────────────────────────────────── */

__attribute__((visibility("default")))
const SchemifyDescriptor schemify_plugin = {
    .abi_version = SCHEMIFY_ABI_VERSION,
    .name        = PLUGIN_NAME,
    .version_str = PLUGIN_VERSION,
    .process     = python_bridge_process,
};
