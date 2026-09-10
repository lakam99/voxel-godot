# Terrain Meshing GDExtension

Native backend source for Minecraft-style terrain volume meshing.

This directory is intentionally separate from `res://addons` until it is built. A missing GDExtension library should not be loaded by the Godot project during migration.

Build/install flow:

```text
node tools/build-native-terrain-meshing.mjs --fetch-godot-cpp --target template_debug --api-version 4.6
node tools/build-native-terrain-meshing.mjs --target template_release --api-version 4.6
```

The build requires:

- a C++ compiler supported by Godot's `godot-cpp` SCons toolchain;
- Python with `scons`;
- `godot-cpp` checked out under `native/terrain_meshing/godot-cpp`.

The bindings revision is pinned in `godot-cpp-revision.txt`. Use a clean dependency checkout, Godot 4.6 API and single-precision engine builds. Record dependency status and effective build flags when validating new binaries. Debug and release libraries must both be rebuilt after native source changes.

The extension also registers `BuildingSupportKernel`, a private accelerator for ordered physical-support queries. It consumes the blueprint's classified geometry and candidate order; the blueprint remains the validation authority. Only owned resolution passes on supported blueprint implementations use it. Missing extensions, custom implementations and extreme numerical inputs retain the GDScript path. Protocol or index corruption fails explicitly. The kernel alone uses strict floating-point compilation (`/fp:strict` on MSVC, `-ffp-contract=off` otherwise) and rejects incompatible engine precision.

After a successful build, the script copies the compiled library and generated `.gdextension` file to:

```text
addons/terrain_meshing_backend/
```

Runtime loading is optional while migration is incomplete. `TerrainMeshingService` discovers either an autoload singleton or a registered GDExtension class named `TerrainMeshingBackend`.

The preferred runtime entry points are `build_chunk_mesh_from_sections(payload)` and `build_chunk_fluid_mesh_from_sections(payload)`. `TerrainMeshingService` builds this payload from `TerrainVolumeService` section channel arrays so native code can scan density, solid, material, and fluid data without per-cell GDScript callbacks. The older `build_chunk_mesh(main, cx, cz)` and `build_chunk_fluid_mesh(main, cx, cz)` callback paths remain compatibility fallbacks while the backend is being brought up.
