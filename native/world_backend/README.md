# Native world backend

`core/` is a Godot-free C++17 library. It contains only owned values and
deterministic kernels: no Godot headers, scene objects, global RNG, file I/O, or
wall-clock policy. `tests/` builds as a standalone executable through the
existing `native/terrain_meshing` SCons stack.

`source-manifest.json` is only the pure-core standalone build, test, and
coverage denominator. The build and the Node receipt runner both compare it
with recursive `core/` and `tests/` discovery and fail if a first-party C++
source/header is omitted. It does not claim standalone coverage of the Godot
adapter. The N1 receipt separately inventories and hashes every extension
source/header and adapter/build/test input before and after the run, joins that
inventory to each build manifest and installed binary, and records the Godot
load/invoke/unload smoke as integration evidence.

N1 guarantees compatibility only for Windows x86-64 with the recorded MSVC
toolchain and strict floating-point flags. The core has no third-party runtime
dependency. SHA-256 is a local, tested implementation of FIPS 180-4 rather than
a dependency or an engine service.
