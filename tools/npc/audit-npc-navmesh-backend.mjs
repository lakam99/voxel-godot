#!/usr/bin/env node
import { runSourceAudit } from '../lib/npc-source-audit.mjs';

await runSourceAudit('npc/audit-npc-navmesh-backend');
