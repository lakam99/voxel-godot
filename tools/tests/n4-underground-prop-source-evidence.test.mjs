import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { acquireN4UndergroundPropLease, assertN4CleanGitState,
  expandN4UndergroundPropSourcePaths, godotCompanionExecutable,
  expandN4ResourceDependencyClosure,
  n4GitState, n4GodotRuntimeInventory,
  n4IsProceduralTreeFamily, n4TreeArchitectureFamilyTokens,
  n4UndergroundPropWatchdogIdentity, n4VisualRegistryRuntimeScenePaths,
  n4WindowsCommandLine, resolveN4ImportedArtifacts,
  withN4UndergroundPropLease } from '../lib/n4-underground-prop-source-evidence.mjs';

const project = fileURLToPath(new URL('../../', import.meta.url));

test('N4 source freeze covers every direct underground oracle owner and capture input', async () => {
  const required = [
    'scripts/Main.gd',
    'scripts/MainPropFactory.gd',
    'scripts/MainChunkTerrain.gd',
    'scripts/MainPlaytestTools.gd',
    'scripts/MainInteractionFlow.gd',
    'scripts/MainRuntimeTools.gd',
    'scripts/MainDiscoveryFlow.gd',
    'scripts/MainHudFlow.gd',
    'scripts/MainWorldEntities.gd',
    'scripts/MainCharacterState.gd',
    'scripts/MainGameLoop.gd',
    'scripts/MainSetupScene.gd',
    'scripts/MainSaveState.gd',
    'scripts/MainCore.gd',
    'scripts/MainInterface.gd',
    'scripts/WorldGenerationSystem.gd',
    'scripts/TerrainVolumeService.gd',
    'scripts/world/BiomeRegionField.gd',
    'scripts/StructureSystem.gd',
    'scripts/world/CitadelTerrainAdmission.gd',
    'scripts/world/CitadelSiteField.gd',
    'scripts/environment/ActiveBiomeEnvironmentSnapshot.gd',
    'scripts/visual/ActiveVisualAssetSnapshot.gd',
    'scripts/world/ActiveRemovedPropsSnapshot.gd',
    'scripts/world/ActiveStructureExclusionChunkSnapshot.gd',
    'scripts/world/ActiveEffectiveTerrainChunkPin.gd',
    'scripts/world/ActiveSurfacePropOwnerBundle.gd',
    'scripts/environment/RockRecipeBuilder.gd',
    'scripts/environment/BiomeEnvironmentCatalog.gd',
    'scripts/environment/BiomeEnvironmentProfile.gd',
    'scripts/visual/VisualAssetRegistry.gd',
    'scripts/environment/TreeRuntimeRequestBuilder.gd',
    'scripts/environment/TreeSpawnService.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd',
    'scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd',
    'scripts/visual/ProceduralTreeVisualFactory.gd',
    'resources/visual/tree_wind_material.gdshader',
    'scripts/visual/AnimatedAssetRegistry.gd',
    'assets/visual/generated/visual-manifest.json',
    'project.godot',
    'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension',
    'addons/zylann.voxel/voxel.gdextension',
    'native/world_backend/core/native_underground_prop_stream.cpp',
    'native/terrain_meshing/src/native_world_backend_adapter.cpp',
    'addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_debug.x86_64.dll',
    'addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll',
  ];
  const paths = await expandN4UndergroundPropSourcePaths(project);
  assert.equal(new Set(paths).size, paths.length, 'source freeze paths must be unique');
  for (const path of required) assert.ok(paths.includes(path), path);
  for (const path of paths) {
    assert.equal(path.includes('\\'), false, `source path must be canonical: ${path}`);
    assert.ok(existsSync(resolve(project, path)), `source input must exist: ${path}`);
  }
});

test('N4 exact command reconstruction matches Windows CreateProcess quoting', () => {
  assert.equal(n4WindowsCommandLine(['C:\\Program Files\\Godot.exe', '--path',
    'C:\\a path\\', 'quoted"value', '']),
  '"C:\\Program Files\\Godot.exe" --path "C:\\a path\\\\" "quoted\\"value" ""');
});

test('N4 source freeze pairs every consumed generated scene with its import descriptor', async () => {
  const paths = await expandN4UndergroundPropSourcePaths(project);
  const scenes = paths.filter(path => path.endsWith('.glb'));
  assert.equal(scenes.length, 18);
  for (const scene of scenes)
    assert.ok(paths.includes(`${scene}.import`), scene);
  const registryScenes = await n4VisualRegistryRuntimeScenePaths(project);
  assert.equal(registryScenes.filter(path => path.endsWith('.glb')).length, 13);
  for (const id of ['bush_01', 'bush_04', 'stump_log_01', 'stump_log_03'])
    assert.ok(registryScenes.includes(`assets/visual/generated/environment/${id}.glb`));
});

test('N4 source inventory expands all manifest groups and extension build inputs', async () => {
  const paths = await expandN4UndergroundPropSourcePaths(project);
  const manifest = JSON.parse(await import('node:fs/promises').then(fs =>
    fs.readFile(join(project, 'native/world_backend/source-manifest.json'), 'utf8')));
  const declared = ['coreSources', 'coreHeaders', 'testSources', 'testHeaders']
    .flatMap(group => manifest[group].map(path => `native/world_backend/${path}`));
  for (const path of declared) assert.ok(paths.includes(path), path);
  for (const path of ['native/terrain_meshing/SConstruct',
    'native/terrain_meshing/scons_tools/windows.py',
    'native/terrain_meshing/godot-cpp-revision.txt',
    'native/terrain_meshing/terrain_meshing_backend.gdextension.in',
    'native/terrain_meshing/src/register_types.cpp',
    'native/terrain_meshing/src/native_world_backend_adapter.cpp'])
    assert.ok(paths.includes(path), path);
});

test('N4 visual scene inventory mirrors the production procedural-tree predicate', async () => {
  const source = await import('node:fs/promises').then(fs =>
    fs.readFile(join(project, 'scripts/environment/TreeRuntimeRequestBuilder.gd'), 'utf8'));
  const tokens = n4TreeArchitectureFamilyTokens(source);
  assert.deepEqual([...tokens].sort(), ['broadleaf', 'conifer', 'savanna']);
  assert.equal(n4IsProceduralTreeFamily('ecological_broadleaf_tree', tokens), true);
  assert.equal(n4IsProceduralTreeFamily('mature_conifer_tree', tokens), true);
  assert.equal(n4IsProceduralTreeFamily('savanna_tree', tokens), true);
  assert.equal(n4IsProceduralTreeFamily('novel_tree', tokens), false);
  const scenes = await n4VisualRegistryRuntimeScenePaths(project);
  assert.equal(scenes.filter(path => path.endsWith('.glb')).length, 13);
});

test('N4 resource inventory recursively closes preload, extends, and resource paths', async t => {
  const root = await mkdtemp(join(tmpdir(), 'n4-resource-closure-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'scripts/sub'), { recursive: true });
  await mkdir(join(root, 'resources'), { recursive: true });
  await writeFile(join(root, 'scripts/main.gd'), 'extends "res://scripts/base.gd"\nconst D = preload("res://scripts/sub/dep.gd")\nvar dynamic = "res://%s" % name\n# const ignored = preload("res://scripts/commented-out.gd")\n');
  await writeFile(join(root, 'scripts/base.gd'), 'extends RefCounted\n');
  await writeFile(join(root, 'scripts/sub/dep.gd'), 'const R = preload("res://resources/item.tres")\n');
  await writeFile(join(root, 'resources/item.tres'), '[resource]\nscript = ExtResource("1")\n[ext_resource path="res://scripts/base.gd" type="Script" id="1"]\n');
  const closure = await expandN4ResourceDependencyClosure(root, ['scripts/main.gd']);
  assert.deepEqual(closure, ['resources/item.tres', 'scripts/base.gd',
    'scripts/main.gd', 'scripts/sub/dep.gd']);
  await rm(join(root, 'scripts/base.gd'));
  await assert.rejects(expandN4ResourceDependencyClosure(root, ['scripts/main.gd']),
    /Missing res dependency/);
});

test('N4 imported artifact resolution binds descriptor path and required artifact', async t => {
  const root = await mkdtemp(join(tmpdir(), 'n4-import-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const paths = [];
  for (let index = 0; index < 18; index++) {
    const descriptor = `asset-${index}.glb.import`;
    const artifact = `.godot/imported/asset-${index}.scn`;
    paths.push(descriptor);
    await mkdir(join(root, '.godot/imported'), { recursive: true });
    await writeFile(join(root, descriptor), `[remap]\npath="res://${artifact}"\n[deps]\ndest_files=["res://${artifact}"]\n`);
    await writeFile(join(root, artifact), `artifact-${index}`);
  }
  const resolved = await resolveN4ImportedArtifacts(root, paths);
  assert.equal(resolved.length, 18);
  await rm(join(root, resolved[0]));
  await assert.rejects(resolveN4ImportedArtifacts(root, paths), /Missing imported PackedScene/);
  await writeFile(join(root, resolved[0]), 'restored');
  await writeFile(join(root, paths[0]), '[remap]\npath="res://.godot/imported/changed.scn"\n[deps]\ndest_files=["res://.godot/imported/other.scn"]\n');
  await assert.rejects(resolveN4ImportedArtifacts(root, paths), /destination mismatch/i);
});

test('N4 runtime inventory binds console, companion engine, hashes, and version', async t => {
  const root = await mkdtemp(join(tmpdir(), 'n4-runtime-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const console = join(root, 'Godot_v4.6.1-stable_win64_console.exe');
  const engine = join(root, 'Godot_v4.6.1-stable_win64.exe');
  await writeFile(console, 'console');
  await writeFile(engine, 'engine');
  assert.equal(godotCompanionExecutable(console), engine);
  const inventory = await n4GodotRuntimeInventory(console,
    { versionReader: path => path === console ? '4.6.1.stable.test' : '' });
  assert.equal(inventory.version, '4.6.1.stable.test');
  assert.equal(inventory.binaries.console.bytes, 7);
  assert.equal(inventory.binaries.engine.bytes, 6);
  assert.notEqual(inventory.binaries.console.sha256, inventory.binaries.engine.sha256);
});

test('N4 clean Git state rejects tracked or untracked dirt', () => {
  const clean = n4GitState('P:/project', { git: args => {
    if (args[1] === 'HEAD') return 'a'.repeat(40);
    if (args[1] === 'HEAD^{tree}') return 'b'.repeat(40);
    return '';
  } });
  assert.equal(assertN4CleanGitState(clean, 'test'), clean);
  const dirty = n4GitState('P:/project', { git: args => args[0] === 'status'
    ? '?? generated.uid' : (args[1] === 'HEAD' ? 'a' : 'b').repeat(40) });
  assert.throws(() => assertN4CleanGitState(dirty, 'test'), /not clean/);
});

test('N4 canonical lease rejects a concurrent launch, releases, and safely recovers stale owner', async t => {
  const root = await mkdtemp(join(tmpdir(), 'n4-lease-test-'));
  const projectPath = join(root, 'project');
  const leaseRoot = join(root, 'leases');
  await mkdir(projectPath);
  t.after(() => rm(root, { recursive: true, force: true }));
  const identities = new Map([[101, 'start-101'], [202, 'start-202'], [303, 'start-303']]);
  const identityForPid = pid => identities.get(pid) ?? null;
  const first = await acquireN4UndergroundPropLease({ project: projectPath,
    leaseRoot, pid: 101, identityForPid });
  let launches = 0;
  await assert.rejects(withN4UndergroundPropLease({ project: projectPath,
    leaseRoot, pid: 202, identityForPid }, async () => { launches++; }), /already held/);
  assert.equal(launches, 0);
  await first.release();
  await withN4UndergroundPropLease({ project: projectPath,
    leaseRoot, pid: 202, identityForPid }, async () => { launches++; });
  assert.equal(launches, 1);
  const stale = await acquireN4UndergroundPropLease({ project: projectPath,
    leaseRoot, pid: 202, identityForPid });
  identities.delete(202);
  const recovered = await acquireN4UndergroundPropLease({ project: projectPath,
    leaseRoot, pid: 303, identityForPid });
  assert.equal(recovered.pid, 303);
  await recovered.release();
  await assert.rejects(stale.release(), /ENOENT|no such file/i);
});

const cleanResult = () => ({
  summaryPath: 'P:\\run\\watchdog.json',
  summary: {
    schema: 'godot-scene-watchdog/v5',
    runId: '0123456789abcdef0123456789abcdef',
    rootPid: 1234,
    launchTimeUtc: '2026-09-24T09:42:48.982Z',
    completedTimeUtc: '2026-09-24T09:46:07.985Z',
    zeroProofSource: 'job_membership_zero',
    ownershipAuthority: 'Windows Job Object membership only',
    cleanupPassed: true,
    authoritativeZeroProven: true,
    rootExited: true,
    finalJobMemberPids: [],
    projectPath: 'P:\\project',
    executable: 'P:\\Godot_console.exe',
    godotExe: 'P:\\Godot_console.exe',
    args: ['--headless', '--path', 'P:\\project'],
    exactCommandLine: 'P:\\Godot_console.exe --headless --path P:\\project',
    summaryPath: 'P:\\run\\watchdog.json',
  },
});

test('N4 report identity binds to the exact watchdog run, command, project, and root process', () => {
  const identity = n4UndergroundPropWatchdogIdentity(cleanResult(), {
    projectPath: 'P:\\project', executable: 'P:\\Godot_console.exe',
    args: ['--headless', '--path', 'P:\\project'],
  });
  assert.deepEqual(identity, {
    schema: 'godot-scene-watchdog/v5',
    runId: '0123456789abcdef0123456789abcdef',
    rootPid: 1234,
    launchTimeUtc: '2026-09-24T09:42:48.982Z',
    completedTimeUtc: '2026-09-24T09:46:07.985Z',
    zeroProofSource: 'job_membership_zero',
    ownershipAuthority: 'Windows Job Object membership only',
    projectPath: 'P:\\project',
    executable: 'P:\\Godot_console.exe',
    args: ['--headless', '--path', 'P:\\project'],
    exactCommandLine: 'P:\\Godot_console.exe --headless --path P:\\project',
    summaryPath: 'P:\\run\\watchdog.json',
  });
  assert.equal(Object.isFrozen(identity), true);
  const later = cleanResult();
  later.summary.runId = 'fedcba9876543210fedcba9876543210';
  later.summary.rootPid = 5678;
  assert.notDeepEqual(n4UndergroundPropWatchdogIdentity(later), identity);
});

test('N4 watchdog identity rejects missing, malformed, or cross-receipt fields', () => {
  const mutations = [
    result => { result.summary = null; },
    result => { result.summary.schema = 'godot-scene-watchdog/v4'; },
    result => { result.summary.runId = 'not-a-run-id'; },
    result => { result.summary.rootPid = 0; },
    result => { result.summary.launchTimeUtc = 'invalid'; },
    result => { result.summary.completedTimeUtc = '2026-09-24T09:40:00.000Z'; },
    result => { result.summary.zeroProofSource = null; },
    result => { result.summary.ownershipAuthority = 'process scan'; },
    result => { result.summary.cleanupPassed = false; },
    result => { result.summary.finalJobMemberPids = [1234]; },
    result => { result.summaryPath = 'P:\\other\\watchdog.json'; },
  ];
  for (const mutate of mutations) {
    const result = cleanResult();
    mutate(result);
    assert.throws(() => n4UndergroundPropWatchdogIdentity(result));
  }
  const expected = { projectPath: 'P:\\project', executable: 'P:\\Godot_console.exe',
    args: ['--headless', '--path', 'P:\\project'] };
  for (const mutate of [
    result => { result.summary.projectPath = 'P:\\other'; },
    result => { result.summary.executable = 'P:\\other.exe'; },
    result => { result.summary.godotExe = 'P:\\other.exe'; },
    result => { result.summary.args = ['--headless']; },
    result => { result.summary.exactCommandLine = 'P:\\other.exe --headless'; },
  ]) {
    const result = cleanResult();
    mutate(result);
    assert.throws(() => n4UndergroundPropWatchdogIdentity(result, expected));
  }
});
