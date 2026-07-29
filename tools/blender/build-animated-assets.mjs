#!/usr/bin/env node
import { runToolMain } from '../lib/voxel-tool-runtime.mjs';

await runToolMain('blender/build-animated-assets');
