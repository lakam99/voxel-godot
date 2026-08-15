# Brown Bear Anatomy Reference Library

This compact library supports region-specific sculpt and critic passes. It is not texture source material.

- `images/` contains normalized, deduplicated references capped at 1600 pixels.
- `contact-sheets/` groups evidence by anatomical region.
- `manifest.json` records source pages, licenses, authors, hashes, region tags, and modeling notes.
- User references remain the primary whole-animal target. Skeletal and close-up evidence explains structure hidden by fur.

Rebuild with the bundled Codex workspace Python (reported by `codex_app__load_workspace_dependencies`), because macOS system Python does not include Pillow:

```bash
"$CODEX_WORKSPACE_PYTHON" tools/blender/build_bear_anatomy_reference_library.py \
  --user-reference /absolute/path/to/front-reference.jpg \
  --user-reference /absolute/path/to/side-reference.jpg
```

Set `CODEX_WORKSPACE_PYTHON` to the dependency loader's Python executable. Do not add untracked full-resolution downloads; add a curated manifest entry instead.
