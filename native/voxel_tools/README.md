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

To review an install without changing the addon, pass the ready build receipt
to the separate installer. The earlier `cd5f2b52-707` build also requires its
matching MSVC preflight receipt because its build report predates toolchain
hash recording:

```powershell
node tools/dependencies/install-staged-voxel-tools-mesh-preparation.mjs --build-report=artifacts/vt/b/cd5f2b52-707/build-report.json --preflight-report=artifacts/vt/b/msvc-preflight-d9ff5ade-690.json
```

Only an explicit `--install` copies the verified editor and release pair into
the addon. Before copying, it preserves the original pair under ignored
`artifacts/vt/install/backups/` and writes an active install receipt. Run the
same command with `--restore` to reinstate that exact backup. While the patched
receipt exists, the upstream installer validates ordinary use and refuses
`--force`; restore first before deliberately reinstalling upstream binaries.
