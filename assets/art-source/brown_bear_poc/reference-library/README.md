# Brown Bear Anatomy Reference Library

This compact library supports region-specific sculpt and critic passes. It is not texture source material.

- `images/` contains normalized, deduplicated references capped at 1600 pixels.
- `contact-sheets/` groups evidence by anatomical region.
- `manifest.json` records source pages, licenses, authors, hashes, region tags, and modeling notes.
- User references remain the primary whole-animal target. Skeletal and close-up evidence explains structure hidden by fur.

Rebuild with `tools/blender/build_bear_anatomy_reference_library.py`. Do not add untracked full-resolution downloads; add a curated manifest entry instead.
