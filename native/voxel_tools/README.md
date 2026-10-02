# Mesh-preparation viewer: isolated Windows build

This directory pins a Voxel Tools `v1.6x` source patch and a separate
`godot-cpp` toolchain workaround. The build runner stages Windows editor and
release DLLs under ignored `artifacts/vt/b/`. It never installs them into
`addons/zylann.voxel`; the existing upstream installer remains unchanged.

From the project root, obtain the pinned source checkouts in ignored paths:

```powershell
git clone --branch v1.6x https://github.com/Zylann/godot_voxel.git artifacts/vt/source
git clone --branch godot-4.5-stable https://github.com/godotengine/godot-cpp.git artifacts/vt/godot-cpp-4.5
```

The runner rejects a checkout unless its HEAD equals the exact commit in
`mesh_preparation.lock.json`. It also verifies both tracked patch digests,
discovers the local MSVC installation with `vswhere`, and checks the selected
toolset version, compiler and linker banners, and hashes of `vcvars64.bat`,
`cl.exe`, and `link.exe`. Python must provide SCons. Set
`VOXEL_TOOLS_BUILD_JOBS` to limit parallel compiler jobs if needed.

```powershell
node tools/dependencies/build-voxel-tools-mesh-preparation.mjs --verify-toolchain-only
node tools/dependencies/build-voxel-tools-mesh-preparation.mjs
```

The first command writes an ignored preflight report; the second writes a
build report with owned-process watchdog receipts and hashes for both staged
DLLs. The `ready/` directory appears only when both builds and output checks
succeed. These files are isolated build artifacts, not a production install.
