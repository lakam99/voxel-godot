#!/usr/bin/env node
import { runToolMain } from './lib/voxel-tool-runtime.mjs';

await runToolMain('build-native-terrain-meshing');
