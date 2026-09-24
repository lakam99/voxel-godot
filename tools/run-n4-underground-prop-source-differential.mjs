import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { findGodot, projectRoot } from './lib/voxel-tool-runtime.mjs';
import { runGodotProcess } from './lib/godot-process.mjs';
import { acquireN4UndergroundPropLease, assertN4CleanGitState,
  expandN4UndergroundPropSourcePaths, n4BuildReceiptInventory,
  n4GitState, n4GodotRuntimeInventory, n4UndergroundPropWatchdogIdentity,
  resolveN4ImportedArtifacts } from './lib/n4-underground-prop-source-evidence.mjs';

const lease = await acquireN4UndergroundPropLease({ project: projectRoot });
try {
const output = join(projectRoot, 'artifacts', 'native-world-backend',
  'n4-underground-prop-source-differential');
await mkdir(output, { recursive: true });
const token = randomUUID();
const probePath = join(output, `probe-${token}.json`);
const reportPath = join(output, `report-${token}.json`);
const executable = await findGodot();
const gitStateBefore = assertN4CleanGitState(n4GitState(projectRoot), 'pre-run');
const sourcePaths = await expandN4UndergroundPropSourcePaths(projectRoot);
const hashPaths = async paths => Object.fromEntries(await Promise.all(paths.map(async path =>
  [path, createHash('sha256').update(await readFile(join(projectRoot, path))).digest('hex')])));
const sourceBefore = await hashPaths(sourcePaths);
const importedPathsBefore = await resolveN4ImportedArtifacts(projectRoot, sourcePaths);
const importedBefore = await hashPaths(importedPathsBefore);
const runtimeBefore = await n4GodotRuntimeInventory(executable);
const buildReceiptsBefore = await n4BuildReceiptInventory(projectRoot);
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
try { ownedProcessIdentity = n4UndergroundPropWatchdogIdentity(processResult,
  { projectPath: projectRoot, executable, args: command }); }
catch (error) { ownedProcessIdentityError = error.message; }
const sourcePathsAfter = await expandN4UndergroundPropSourcePaths(projectRoot);
const sourceAfter = await hashPaths(sourcePathsAfter);
const importedPathsAfter = await resolveN4ImportedArtifacts(projectRoot, sourcePathsAfter);
const importedAfter = await hashPaths(importedPathsAfter);
const runtimeAfter = await n4GodotRuntimeInventory(executable);
const buildReceiptsAfter = await n4BuildReceiptInventory(projectRoot);
const gitStateAfter = n4GitState(projectRoot);
const changedPaths = sourcePaths.filter(path => sourceBefore[path] !== sourceAfter[path]);
if (JSON.stringify(sourcePaths) !== JSON.stringify(sourcePathsAfter)) changedPaths.push('source:inventory');
if (JSON.stringify(importedPathsBefore) !== JSON.stringify(importedPathsAfter))
  changedPaths.push('imported:inventory');
for (const path of importedPathsBefore)
  if (importedBefore[path] !== importedAfter[path]) changedPaths.push(path);
if (JSON.stringify(runtimeBefore) !== JSON.stringify(runtimeAfter)) changedPaths.push('runtime:godot');
if (JSON.stringify(buildReceiptsBefore) !== JSON.stringify(buildReceiptsAfter))
  changedPaths.push('native:build-receipts');
if (!gitStateAfter.clean) changedPaths.push('git:status');
if (gitStateBefore.head !== gitStateAfter.head) changedPaths.push('git:HEAD');
if (gitStateBefore.tree !== gitStateAfter.tree) changedPaths.push('git:tree');
const sourceFreeze = { gitHead: gitStateBefore.head, gitHeadAfter: gitStateAfter.head,
  gitTree: gitStateBefore.tree, gitTreeAfter: gitStateAfter.tree,
  gitStatusBefore: gitStateBefore.status, gitStatusAfter: gitStateAfter.status,
  files: sourceBefore, importedArtifacts: importedBefore,
  godotRuntime: runtimeBefore, nativeBuildReceipts: buildReceiptsBefore,
  installedDebugDllSha256:
    sourceBefore['addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll'],
  voxelToolsEditorDllSha256:
    sourceBefore['addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll'],
  stagedDebugDllMatchesRecordedBuildOutput:
    sourceBefore['addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll']
      === buildReceiptsBefore['native/terrain_meshing/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll']?.sha256,
  dllSourceCorrespondenceProvenByThisRun: false,
  dllSourceCorrespondenceAuthority:
    'Separate prior MSVC/LLVM build receipts; this differential does not rebuild the staged DLL.',
  unchanged: changedPaths.length === 0, changedPaths: [...new Set(changedPaths)] };
const failures = [];
if (ownedProcessIdentityError)
  failures.push(`Owned-process receipt identity invalid: ${ownedProcessIdentityError}`);
if (!sourceFreeze.unchanged)
  failures.push(`Launch-relevant source drift: ${changedPaths.join(', ')}`);
if (!sourceFreeze.stagedDebugDllMatchesRecordedBuildOutput)
  failures.push('Staged debug DLL does not match the recorded debug build output');
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
  executable, command, lease: { schema: lease.schema, key: lease.key,
    runnerId: lease.runnerId, canonicalProject: lease.canonicalProject,
    pid: lease.pid, startIdentity: lease.startIdentity, acquiredAtUtc: lease.acquiredAtUtc },
};
const temporaryReportPath = `${reportPath}.${randomUUID()}.tmp`;
await writeFile(temporaryReportPath, `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' });
await rename(temporaryReportPath, reportPath);
console.log(`${report.status}: ${reportPath}`);
if (failures.length) { console.error(failures.slice(0, 10).join('\n')); process.exitCode = 1; }
} finally {
  await lease.release();
}
