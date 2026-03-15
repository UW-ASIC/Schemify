//! Build dependency helper for NGSpice and Xyce.
//!
//! Import this from your `build.zig` and call `addSpiceDeps` to wire up
//! both simulator backends to your executable or library.
//!
//! ## Directory Layout (expected)
//!
//! ```
//! project/
//! ├── build.zig
//! ├── tools/
//! │   └── build_dep.zig          # this file
//! ├── src/
//! └── deps/
//!     ├── ngspice.zig            # Zig bindings for ngspice
//!     ├── xyce.zig               # Zig bindings for Xyce
//!     ├── lib.zig                # unified interface
//!     ├── ngspice/               # cloned & built ngspice source
//!     │   └── ...
//!     └── Xyce/                  # cloned & built Xyce source + Trilinos
//!         ├── xyce_c_api.h       # C shim header  (shipped with project)
//!         ├── xyce_c_api.cpp     # C shim impl    (shipped with project)
//!         ├── XyceLibs/Serial/   # Trilinos install prefix
//!         ├── install/            # Xyce install prefix
//!         │   ├── include/
//!         │   └── lib/libxyce.so
//!         └── ...                # Xyce & Trilinos source trees
//! ```
//!
//! ## Setup Commands
//!
//! ### Prerequisites (Ubuntu/Debian)
//!
//! ```sh
//! sudo apt-get install -y \
//!   gcc g++ gfortran make cmake \
//!   autoconf automake libtool \
//!   bison flex libfftw3-dev \
//!   libsuitesparse-dev liblapack-dev libblas-dev git
//! ```
//!
//! ### Clone sources
//!
//! ```sh
//! # NGSpice
//! git clone https://github.com/ngspice/ngspice.git deps/ngspice
//!
//! # Xyce + Trilinos (into the same deps/Xyce directory)
//! git clone https://github.com/Xyce/Xyce.git deps/Xyce/src
//! git clone https://github.com/trilinos/Trilinos.git deps/Xyce/Trilinos
//! ```
//!
//! ### Build NGSpice
//!
//! ```sh
//! cd deps/ngspice
//! ./autogen.sh
//! ./configure --with-ngshared --enable-xspice --enable-cider
//! make -j$(nproc)
//! cd ../..
//! ```
//!
//! ### Build Trilinos (with -fPIC — required for shared Xyce)
//!
//! ```sh
//! mkdir -p deps/Xyce/trilinos-build && cd deps/Xyce/trilinos-build
//!
//! SRCDIR="$(cd ../Trilinos && pwd)"
//! ARCHDIR="$(cd .. && pwd)/XyceLibs/Serial"
//! FLAGS="-O3 -fPIC"
//!
//! cmake \
//!   -G "Unix Makefiles" \
//!   -DCMAKE_C_COMPILER=gcc \
//!   -DCMAKE_CXX_COMPILER=g++ \
//!   -DCMAKE_Fortran_COMPILER=gfortran \
//!   -DCMAKE_CXX_FLAGS="$FLAGS" \
//!   -DCMAKE_C_FLAGS="$FLAGS" \
//!   -DCMAKE_Fortran_FLAGS="$FLAGS" \
//!   -DCMAKE_INSTALL_PREFIX=$ARCHDIR \
//!   -DTrilinos_ENABLE_NOX=ON \
//!   -DNOX_ENABLE_LOCA=ON \
//!   -DTrilinos_ENABLE_EpetraExt=ON \
//!   -DEpetraExt_BUILD_BTF=ON \
//!   -DEpetraExt_BUILD_EXPERIMENTAL=ON \
//!   -DEpetraExt_BUILD_GRAPH_REORDERINGS=ON \
//!   -DTrilinos_ENABLE_TrilinosCouplings=ON \
//!   -DTrilinos_ENABLE_Ifpack=ON \
//!   -DTrilinos_ENABLE_AztecOO=ON \
//!   -DTrilinos_ENABLE_Belos=ON \
//!   -DTrilinos_ENABLE_Teuchos=ON \
//!   -DTeuchos_ENABLE_COMPLEX=ON \
//!   -DTrilinos_ENABLE_Amesos=ON \
//!   -DAmesos_ENABLE_KLU=ON \
//!   -DTrilinos_ENABLE_Amesos2=ON \
//!   -DAmesos2_ENABLE_KLU2=ON \
//!   -DAmesos2_ENABLE_Basker=ON \
//!   -DTrilinos_ENABLE_Sacado=ON \
//!   -DTrilinos_ENABLE_Stokhos=ON \
//!   -DTrilinos_ENABLE_Kokkos=ON \
//!   -DTrilinos_ENABLE_ALL_OPTIONAL_PACKAGES=OFF \
//!   -DTPL_ENABLE_AMD=ON \
//!   -DAMD_LIBRARY_DIRS="/usr/lib" \
//!   -DTPL_AMD_INCLUDE_DIRS="/usr/include/suitesparse" \
//!   -DTPL_ENABLE_BLAS=ON \
//!   -DTPL_ENABLE_LAPACK=ON \
//!   $SRCDIR
//!
//! make -j$(nproc)
//! make install
//! cd ../../..
//! ```
//!
//! ### Build Xyce (Autotools — shared library)
//!
//! ```sh
//! cd deps/Xyce/src
//! ./bootstrap
//! cd ..
//! mkdir -p xyce-build && cd xyce-build
//!
//! ../src/configure \
//!   CXXFLAGS="-O3 -fPIC" \
//!   ARCHDIR="$(cd .. && pwd)/XyceLibs/Serial" \
//!   CPPFLAGS="-I/usr/include/suitesparse" \
//!   --enable-shared \
//!   --enable-xyce-shareable \
//!   --prefix="$(cd .. && pwd)/install"
//!
//! make -j$(nproc)
//! make install
//! cd ../../..
//! ```
//!
//! ### Build Xyce (CMake alternative)
//!
//! ```sh
//! mkdir -p deps/Xyce/xyce-build && cd deps/Xyce/xyce-build
//!
//! cmake \
//!   -DCMAKE_INSTALL_PREFIX="$(cd .. && pwd)/install" \
//!   -DTrilinos_ROOT="$(cd .. && pwd)/XyceLibs/Serial" \
//!   -DBUILD_SHARED_LIBS=ON \
//!   -DCMAKE_CXX_FLAGS="-O3 -fPIC" \
//!   -DCMAKE_C_FLAGS="-O3 -fPIC" \
//!   ../src
//!
//! cmake --build . -j$(nproc)
//! cmake --build . --target install
//! cd ../../..
//! ```
//!
//! ## build.zig usage
//!
//! ```zig
//! const std = @import("std");
//! const build_dep = @import("tools/build_dep.zig");
//!
//! pub fn build(b: *std.Build) void {
//!     const target = b.standardTargetOptions(.{});
//!     const optimize = b.standardOptimizeOption(.{});
//!
//!     const exe = b.addExecutable(.{
//!         .name = "my_app",
//!         .root_source_file = .{ .cwd_relative = "src/main.zig" },
//!         .target = target,
//!         .optimize = optimize,
//!     });
//!
//!     // Wire up both SPICE backends + the unified deps/lib.zig module
//!     build_dep.addSpiceDeps(b, exe, .{});
//!
//!     b.installArtifact(exe);
//! }
//! ```

const std = @import("std");
const Build = std.Build;

// ============================================================================
// Configuration
// ============================================================================

pub const SpiceConfig = struct {
    // ── NGSpice ────────────────────────────────────────────────────────────

    /// Enable the NGSpice backend.
    enable_ngspice: bool = true,

    /// Path to the built ngspice source tree.
    ngspice_src: []const u8 = "deps/ngspice",

    /// Override: directory containing libngspice.so / .dylib.
    ngspice_lib_path: ?[]const u8 = null,

    /// Override: directory containing sharedspice.h.
    ngspice_include_path: ?[]const u8 = null,

    // ── Xyce ───────────────────────────────────────────────────────────────

    /// Enable the Xyce backend.
    enable_xyce: bool = true,

    /// Path to the deps/Xyce directory (contains xyce_c_api.h/cpp,
    /// install/, XyceLibs/, etc.).
    xyce_dir: []const u8 = "deps/Xyce",

    /// Subdirectory under xyce_dir where Xyce was installed.
    xyce_install_subdir: []const u8 = "install",
};

// ============================================================================
// Public API
// ============================================================================

/// Wire up NGSpice and/or Xyce as dependencies for a compile step,
/// and add the `spice` module (deps/lib.zig) so user code can:
///
/// ```zig
/// const spice = @import("spice");
/// ```
pub fn addSpiceDeps(b: *Build, compile: *Build.Step.Compile, config: SpiceConfig) void {
    // -- Create the module tree: spice → lib.zig → {ngspice.zig, xyce.zig}

    const ngspice_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "deps/ngspice.zig" },
    });

    const xyce_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "deps/xyce.zig" },
    });

    const lib_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "deps/lib.zig" },
        .imports = &.{
            .{ .name = "ngspice", .module = ngspice_mod },
            .{ .name = "xyce", .module = xyce_mod },
        },
    });

    // Expose as "spice" to the application
    compile.root_module.addImport("spice", lib_mod);
    // Also expose individual backends if wanted
    compile.root_module.addImport("ngspice", ngspice_mod);
    compile.root_module.addImport("xyce", xyce_mod);

    // -- Link NGSpice native library ────────────────────────────────────────

    if (config.enable_ngspice) {
        // Include path: sharedspice.h
        if (config.ngspice_include_path) |p| {
            ngspice_mod.addIncludePath(.{ .cwd_relative = p });
        } else {
            ngspice_mod.addIncludePath(.{ .cwd_relative = config.ngspice_src ++ "/src/include" });
        }

        // Library path: libngspice.so
        const ng_lib = config.ngspice_lib_path orelse (config.ngspice_src ++ "/src/.libs");
        ngspice_mod.addLibraryPath(.{ .cwd_relative = ng_lib });
        ngspice_mod.linkSystemLibrary("ngspice", .{ .preferred_link_mode = .dynamic });
        ngspice_mod.link_libc = true;

        compile.addRPath(.{ .cwd_relative = ng_lib });
    }

    // -- Link Xyce native library (via C++ shim) ───────────────────────────

    if (config.enable_xyce) {
        const xyce_inc = config.xyce_dir ++ "/" ++ config.xyce_install_subdir ++ "/include";
        const xyce_lib = config.xyce_dir ++ "/" ++ config.xyce_install_subdir ++ "/lib";
        const shim_cpp = config.xyce_dir ++ "/xyce_c_api.cpp";

        // Compile the C++ shim as part of this module
        xyce_mod.addCSourceFile(.{
            .file = .{ .cwd_relative = shim_cpp },
            .flags = &.{
                "-std=c++17",
                "-fPIC",
                "-O2",
                b.fmt("-I{s}", .{xyce_inc}),
            },
        });

        // Include path for xyce_c_api.h
        xyce_mod.addIncludePath(.{ .cwd_relative = config.xyce_dir });

        // Library path for libxyce.so
        xyce_mod.addLibraryPath(.{ .cwd_relative = xyce_lib });
        xyce_mod.linkSystemLibrary("xyce", .{ .preferred_link_mode = .dynamic });
        xyce_mod.link_libcpp = true;
        xyce_mod.link_libc = true;

        compile.addRPath(.{ .cwd_relative = xyce_lib });
    }
}
