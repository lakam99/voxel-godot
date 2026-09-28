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
toolchain and strict floating-point flags. N2 vendors Godot 4.6.1's exact
patched FastNoiseLite 1.1.0 header privately for deterministic source parity;
the lock file records the engine/upstream commits, patch, header, and MIT
license hashes. It is a build-time header dependency, not a runtime service,
and its third-party lines are not part of the first-party coverage denominator.
SHA-256 remains a local, tested implementation of FIPS 180-4 rather than a
dependency or an engine service.
