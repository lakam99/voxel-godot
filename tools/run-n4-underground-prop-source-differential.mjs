import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { findGodot, projectRoot } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';
import { N4_UNDERGROUND_PROP_SOURCE_PATHS,
  n4UndergroundPropWatchdogIdentity } from './lib/n4-underground-prop-source-evidence.mjs';

const output = join(projectRoot, 'artifacts', 'native-world-backend',
  'n4-underground-prop-source-differential');
await mkdir(output, { recursive: true });
const token = randomUUID();
const probePath = join(output, `probe-${token}.json`);
const reportPath = join(output, `report-${token}.json`);
const executable = await findGodot();
const sourcePaths = N4_UNDERGROUND_PROP_SOURCE_PATHS;
const hashSources = async () => Object.fromEntries(await Promise.all(sourcePaths.map(async path =>
  [path, createHash('sha256').update(await readFile(join(projectRoot, path))).digest('hex')])));
const gitHead = () => execFileSync('git', ['rev-parse', 'HEAD'], {
  cwd: projectRoot, encoding: 'utf8', windowsHide: true,
}).trim();
const sourceBefore = await hashSources();
const gitHeadBefore = gitHead();
const command = ['--headless', '--audio-driver', 'Dummy', '--path', projectRoot,
  '--script', 'res://scripts/testing/native_world/N4UndergroundPropSourceProbe.gd'];
const processResult = await runGodotProcess(executable, command, {
  // Evidence capacity for four source-bound 28x28 scans plus production recipe
  // replay. This is not a gameplay-frame or production scheduling budget.
  cwd: projectRoot, timeoutSeconds: 360, workTimeoutSeconds: 300,
  env: { ...process.env, VOXEL_DISABLE_AUDIO_PLAYBACK: '1',
    N4_UNDERGROUND_PROP_PROBE_REPORT: probePath },
});
let ownedProcessIdentity = null;
let ownedProcessIdentityError = null;
try { ownedProcessIdentity = n4UndergroundPropWatchdogIdentity(processResult); }
catch (error) { ownedProcessIdentityError = error.message; }
const sourceAfter = await hashSources();
const gitHeadAfter = gitHead();
const changedPaths = sourcePaths.filter(path => sourceBefore[path] !== sourceAfter[path]);
if (gitHeadBefore !== gitHeadAfter) changedPaths.unshift('git:HEAD');
const sourceFreeze = { gitHead: gitHeadBefore, gitHeadAfter,
  files: sourceBefore, unchanged: changedPaths.length === 0, changedPaths };
const failures = [];
if (ownedProcessIdentityError)
  failures.push(`Owned-process receipt identity invalid: ${ownedProcessIdentityError}`);
if (!sourceFreeze.unchanged)
  failures.push(`Launch-relevant source drift: ${changedPaths.join(', ')}`);
let probe;
try { probe = JSON.parse(await readFile(probePath, 'utf8')); }
catch (error) { failures.push(`Probe report unavailable: ${error.message}`); }
if (processResult.code !== 0) failures.push(`Godot process failed: ${processResult.code}`);
if (probe?.cases?.length !== 4) failures.push(`Expected four cases, got ${probe?.cases?.length}`);
const uint64 = value => {
  try {
    if (value === null || value === undefined || value === '') return null;
    return BigInt.asUintN(64, BigInt(value)).toString();
  } catch { return null; }
};
const floatBuffer = new ArrayBuffer(4);
const floatView = new DataView(floatBuffer);
const bits = value => {
  floatView.setFloat32(0, Number(value), true);
  return floatView.getUint32(0, true);
};
const vectorBits = value => Array.isArray(value) && value.length === 3
  ? value.map(bits) : [];
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const expectedFamily = row => ({ 1: 'none', 2: 'none', 3: 'ironOre', 4: 'copperOre',
  5: 'rock', 6: 'forage' })[row.outcome];
const comparedFamilies = new Set();
for (const [caseIndex, sample] of (probe?.cases ?? []).entries()) {
  const label = `case ${caseIndex} chunk ${JSON.stringify(sample.chunk)}`;
  if (sample.initialization !== 'ready' || !sample.bundleReady)
    failures.push(`${label} source admission failed`);
  for (const [key, status] of Object.entries(sample.admissions ?? {}))
    if (status !== 'ready') failures.push(`${label} ${key} admission: ${status}`);
  const native = sample.native ?? {};
  if (native.status !== 'ready') failures.push(`${label} native shadow: ${native.status}/${native.reason}`);
  for (const field of ['publishable', 'channelFootprintsComplete', 'completeFeatureManifest',
    'productionCutover', 'removedPropsMutated',
    'collidersInstalled', 'routingInfluenced'])
    if (native[field] !== false) failures.push(`${label} diagnostic boundary ${field} was not false`);
  const direct = sample.direct ?? [], attempts = native.attempts ?? [], candidates = native.candidates ?? [];
  if (direct.length !== attempts.length || direct.length !== candidates.length)
    failures.push(`${label} counts direct/native/candidates ${direct.length}/${attempts.length}/${candidates.length}`);
  for (let index = 0; index < Math.min(direct.length, attempts.length, candidates.length); index++) {
    const actual = direct[index], shadow = attempts[index], candidate = candidates[index];
    for (const field of ['ordinal', 'durableId', 'material', 'parentTombstoned'])
      if (actual[field] !== shadow[field]) failures.push(`${label} attempt ${index} ${field} mismatch`);
    if (JSON.stringify(actual.floorCell) !== JSON.stringify(shadow.floorCell)
        || JSON.stringify(actual.floorCell) !== JSON.stringify(candidate.floorCell))
      failures.push(`${label} attempt ${index} floor cell mismatch`);
    if (actual.candidateRoll !== candidate.candidateRoll)
      failures.push(`${label} attempt ${index} candidate hash roll mismatch`);
    for (const field of ['stateBefore', 'stateAfterSelection', 'stateAfterRecipe'])
      if (uint64(actual[field]) !== uint64(shadow[field]))
        failures.push(`${label} attempt ${index} ${field} mismatch`);
    for (const field of ['selectionRoll', 'deepIronRoll'])
      if (!actual.parentTombstoned && actual[field] !== shadow[field])
        failures.push(`${label} attempt ${index} ${field} mismatch`);
    const family = expectedFamily(shadow);
    if (actual.family !== family) failures.push(`${label} attempt ${index} family ${actual.family} != ${family}`);
    if (!actual.parentTombstoned) comparedFamilies.add(actual.family);
	const expectedPosition = shadow.outcome === 3 || shadow.outcome === 4
	  ? shadow.feature?.children?.[0]?.localPosition : shadow.localPosition;
	if (actual.localPosition && JSON.stringify(actual.localPosition) !== JSON.stringify(expectedPosition))
	  failures.push(`${label} attempt ${index} local placement mismatch`);
    if (shadow.outcome === 3 || shadow.outcome === 4) {
      if (shadow.feature?.kind !== 'oreCluster' || shadow.feature?.children?.length !== 1
          || shadow.feature.children[0].durableId !== shadow.durableId)
        failures.push(`${label} attempt ${index} one-child ore definition mismatch`);
      else {
        const built = actual.geometry ?? {}, typed = shadow.feature.children[0];
        const oreType = shadow.outcome === 3 ? 'ironOre' : 'copperOre';
        if (built.captureError || built.durableId !== typed.durableId
            || built.oreType !== oreType || built.clusterSize !== 1
            || built.dropCount !== typed.dropCount
            || !same(built.localPositionBits, vectorBits(typed.localPosition))
            || built.rotationYBits !== bits(typed.rotationY)
            || built.meshRadiusBits !== bits(typed.meshRadius)
            || built.meshHeightBits !== bits(typed.meshHeight)
            || !same(built.meshScaleBits, vectorBits(typed.meshScale))
            || built.meshCenterYBits !== bits(typed.meshCenterY)
            || built.colliderRadiusBits !== bits(typed.colliderRadius)
            || built.colliderCenterYBits !== bits(typed.colliderCenterY)
            || built.seamCount !== typed.seams?.length
            || built.glintCount !== typed.glints?.length)
          failures.push(`${label} attempt ${index} typed ore construction mismatch`);
        for (let part = 0; part < Math.min(built.seams?.length ?? 0, typed.seams?.length ?? 0); part++) {
          const directSeam = built.seams[part], nativeSeam = typed.seams[part];
          if (!same(directSeam.positionBits, vectorBits(nativeSeam.localPosition))
              || !same(directSeam.rotationBits, vectorBits(nativeSeam.rotation))
              || !same(directSeam.meshSizeBits, vectorBits(typed.seamMeshSize)))
            failures.push(`${label} attempt ${index} ore seam ${part} mismatch`);
        }
        for (let part = 0; part < Math.min(built.glints?.length ?? 0, typed.glints?.length ?? 0); part++) {
          const directGlint = built.glints[part], nativeGlint = typed.glints[part];
          if (!same(directGlint.positionBits, vectorBits(nativeGlint.localPosition))
              || !same(directGlint.scaleBits, vectorBits(nativeGlint.scale))
              || directGlint.meshRadiusBits !== bits(typed.glintMeshRadius)
              || directGlint.meshHeightBits !== bits(typed.glintMeshHeight))
            failures.push(`${label} attempt ${index} ore glint ${part} mismatch`);
        }
      }
    }
    if (shadow.outcome === 5) {
      const typed = shadow.feature ?? {}, built = actual.geometry ?? {};
      const rawScale = typed.visualScale ?? [], assetSize = typed.assetSize ?? [];
      const profileScale = Math.fround(typed.profileScale);
      const expectedScale = rawScale.length === 3 && assetSize.length === 3 ? [
        Math.fround(Math.fround(typed.visualRadius * 2 * rawScale[0]
          / Math.max(0.1, assetSize[0])) * profileScale),
        Math.fround(Math.fround(typed.visualRadius * typed.visualHeightFactor * rawScale[1]
          / Math.max(0.1, assetSize[2])) * profileScale),
        Math.fround(Math.fround(typed.visualRadius * 2 * rawScale[2]
          / Math.max(0.1, assetSize[1])) * profileScale),
      ] : [];
      if (typed.kind !== 'rock' || built.captureError
          || built.durableId !== typed.durableId || built.visualBiome !== typed.visualBiome
          || built.assetId !== typed.assetId || built.visualSource !== 'generated_asset'
          || built.rotationYBits !== bits(typed.rotationY)
          || built.colliderRadiusBits !== bits(typed.colliderRadius)
          || built.colliderCenterYBits !== bits(typed.colliderCenterY)
          || !same(built.visualScaleBits, vectorBits(expectedScale)))
        failures.push(`${label} attempt ${index} typed rock construction mismatch`);
    }
    if (shadow.outcome === 6) {
      const typed = shadow.feature ?? {}, built = actual.geometry ?? {};
      if (typed.kind !== 'forage' || built.captureError
          || built.materialId !== typed.materialId || built.dropId !== typed.dropId
          || built.dropCount !== typed.dropCount
          || built.rotationYBits !== bits(typed.rotationY)
          || built.collider?.radiusBits !== bits(typed.colliderRadius)
          || built.collider?.centerYBits !== bits(typed.colliderCenterY)
          || built.meshes?.length !== typed.meshes?.length)
        failures.push(`${label} attempt ${index} typed forage construction mismatch`);
      for (let part = 0; part < Math.min(built.meshes?.length ?? 0, typed.meshes?.length ?? 0); part++) {
        const directMesh = built.meshes[part], nativeMesh = typed.meshes[part];
        let matches = directMesh.kind === nativeMesh.kind
          && directMesh.materialId === nativeMesh.materialId
          && same(directMesh.positionBits, vectorBits(nativeMesh.position))
          && same(directMesh.rotationBits, vectorBits(nativeMesh.rotation))
          && same(directMesh.scaleBits, vectorBits(nativeMesh.scale))
          && directMesh.heightBits === bits(nativeMesh.height)
          && directMesh.radialSegments === nativeMesh.radialSegments;
        if (nativeMesh.kind === 1)
          matches &&= directMesh.radiusBits === bits(nativeMesh.radius)
            && directMesh.rings === nativeMesh.rings;
        else
          matches &&= directMesh.topRadiusBits === bits(nativeMesh.topRadius)
            && directMesh.bottomRadiusBits === bits(nativeMesh.bottomRadius);
        if (!matches) failures.push(`${label} attempt ${index} forage mesh ${part} mismatch`);
      }
    }
  }
  if (uint64(sample.directFinalRngState) !== uint64(native.finalRngState))
    failures.push(`${label} final RNG state mismatch`);
  if (uint64(sample.processReplay?.finalRngState) !== uint64(native.finalRngState)
      || JSON.stringify(sample.processReplay?.candidateCells)
        !== JSON.stringify(candidates.map(row => row.floorCell)))
    failures.push(`${label} production process_underground replay mismatch`);
  if (sample.processReplay?.publishedChildCount
      !== direct.filter(row => row.family !== 'none').length)
    failures.push(`${label} production process_underground publication count mismatch`);
}
const tombstone = probe?.cases?.[1];
if (tombstone?.removed?.length !== 1 || tombstone?.native?.attempts?.[0]?.outcome !== 1
    || tombstone?.direct?.[0]?.parentTombstoned !== true)
  failures.push('Root removedProps tombstone case was not exercised');
for (const family of ['none', 'rock', 'forage', 'copperOre', 'ironOre'])
  if (!comparedFamilies.has(family)) failures.push(`No ${family} source outcome was compared`);
const report = {
  schema: 'n4-underground-prop-source-differential/v1',
  status: failures.length ? 'failed' : 'passed',
  evidenceLevel: 'direct production-method/service differential; not headed gameplay acceptance',
  seed: probe?.seed ?? null,
  cases: probe?.cases?.map(sample => ({ chunk: sample.chunk, removed: sample.removed,
    attemptsCompared: Math.min(sample.direct?.length ?? 0, sample.native?.attempts?.length ?? 0) })) ?? [],
  comparedFamilies: [...comparedFamilies].sort(),
  productionCutover: false,
  diagnosticOnly: true,
  sourceFreeze,
  failures: failures.slice(0, 40), probePath, ownedProcess: ownedProcessIdentity,
  processSummaryPath: ownedProcessIdentity?.summaryPath ?? processResult.summaryPath,
  executable, command,
};
await writeFile(reportPath, JSON.stringify(report, null, 2));
console.log(`${report.status}: ${reportPath}`);
if (failures.length) { console.error(failures.slice(0, 10).join('\n')); process.exitCode = 1; }
