#!/usr/bin/env node
import { runToolMain } from '../lib/voxel-tool-runtime.mjs';

await runToolMain('npc/assert-npc-legacy-pathfinding-clean');
