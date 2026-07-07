# Terrain Meshing GDExtension

Native backend source for Minecraft-style terrain volume meshing.

This directory is intentionally separate from `res://addons` until it is built. A missing GDExtension library should not be loaded by the Godot project during migration.

Build/install flow:

```powershell
.\tools\build-native-terrain-meshing.ps1 -FetchGodotCpp
```

The build requires:

- a C++ compiler supported by Godot's `godot-cpp` SCons toolchain;
- Python with `scons`;
- `godot-cpp` checked out under `native/terrain_meshing/godot-cpp`.

After a successful build, the script copies the compiled library and generated `.gdextension` file to:

```text
addons/terrain_meshing_backend/
```

Runtime loading is optional while migration is incomplete. `TerrainMeshingService` discovers either an autoload singleton or a registered GDExtension class named `TerrainMeshingBackend`.

The preferred runtime entry points are `build_chunk_mesh_from_sections(payload)` and `build_chunk_fluid_mesh_from_sections(payload)`. `TerrainMeshingService` builds this payload from `TerrainVolumeService` section channel arrays so native code can scan density, solid, material, and fluid data without per-cell GDScript callbacks. The older `build_chunk_mesh(main, cx, cz)` and `build_chunk_fluid_mesh(main, cx, cz)` callback paths remain compatibility fallbacks while the backend is being brought up.
