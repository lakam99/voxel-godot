# Node Tooling

All active tooling has a Node.js entry point with the same name and directory
as its former PowerShell command. Use Node directly from the project root:

```sh
node tools/run-playtest.mjs
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/run-all-test-runners.mjs -Seed atlas-1492
node tools/blender/build-environment-assets.mjs
```

The runner accepts both PowerShell-style parameter names (`-ReportPath`) and
portable kebab-case parameters (`--report-path`). This keeps existing report
commands usable while new documentation can use ordinary command-line syntax.

`GODOT_EXE` or `GODOT_BIN` may point to a Godot executable. `BLENDER_EXE` or
`BLENDER_BIN` may point to Blender. Without an override, the runtime checks the
PATH and standard macOS application locations before failing with the required
override.

The old `.ps1` files remain as Windows reference implementations during the
migration. Active registries and the project guidance use the Node entries, so
macOS, Windows, and Linux no longer require PowerShell to run the supported
tooling.

Godot runners preserve report paths, generated run tokens, output directories,
watchdogs, and evidence validation. A synthetic or static tool remains labeled
as such; the Node conversion does not upgrade it into live gameplay evidence.

## macOS Native Setup

The terrain-meshing GDExtension and Voxel Tools require macOS binaries on a
fresh checkout. After installing Godot 4.6 and SCons, run:

```sh
brew install scons
node tools/build-native-terrain-meshing.mjs --fetch-godot-cpp
node tools/dependencies/install-voxel-tools.mjs --force
```

The terrain build produces a universal Apple Silicon/Intel debug library. Its
compiler intermediates stay under ignored native build directories, while the
Voxel Tools installer extracts outside the Godot project to avoid a duplicate
GDExtension registration.
