# Animated Asset Pipeline

Generated animated proof-of-concept assets live in `assets/generated/animated/`.

Regenerate them with:

```powershell
.\tools\blender\build-animated-assets.ps1
```

To use an explicit Blender install:

```powershell
.\tools\blender\build-animated-assets.ps1 -BlenderPath "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
```

The generator exports:

- `door_open_close.glb`
- `chest_open_close.glb`
- `boar_idle_walk.glb`

Static item and utility meshes live in `assets/generated/static/`.

Regenerate them with:

```powershell
.\tools\blender\build-static-item-assets.ps1
```

This exports Blender-authored GLBs for tool meshes, ranged tools, utility objects, campfires, lanterns/beacons, armor, packs, and navigation/accessory items. Runtime factories load them through `StaticItemAssetRegistry` and fall back to procedural meshes if a generated asset is unavailable.

Godot preview/import validation:

```powershell
$env:VOXEL_ANIMATED_PREVIEW_QUIT="1"
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --headless --path . --scene res://scenes/AnimatedAssetPreview.tscn
Remove-Item Env:\VOXEL_ANIMATED_PREVIEW_QUIT
```

Static item import validation:

```powershell
$env:VOXEL_STATIC_ITEM_PREVIEW_QUIT="1"
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --headless --path . --scene res://scenes/StaticItemAssetPreview.tscn
Remove-Item Env:\VOXEL_STATIC_ITEM_PREVIEW_QUIT
```
