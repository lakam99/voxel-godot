# Voxel Tools Dependency

VOX-59 uses the Voxel Tools GDExtension as the candidate production terrain
runtime.

Pinned release:

- Project: `Zylann/godot_voxel`
- Tag: `v1.6x`
- Asset: `GodotVoxelExtension.zip`
- Published SHA-256: `dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a`
- License: MIT, included at `addons/zylann.voxel/LICENSE.md`

Install the native binaries before opening or testing the project:

```powershell
.\tools\dependencies\install-voxel-tools.ps1
```

The installer downloads the pinned release, verifies its digest before
extraction, and installs the upstream add-on under `addons/zylann.voxel`.
Native binaries are deliberately excluded from Git. The add-on descriptor,
icons, license, and this lock document remain tracked.

Do not update the tag or digest without rerunning the VOX-60 backend smoke,
the project compile smoke, and the export dependency check.
