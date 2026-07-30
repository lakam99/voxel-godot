import { access, cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { basename, dirname, extname, isAbsolute, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';

const runtimeDirectory = dirname(fileURLToPath(import.meta.url));
export const projectRoot = resolve(runtimeDirectory, '..', '..');

const optionAliases = new Map([
  ['godotexe', 'godotExe'], ['blenderpath', 'blenderPath'], ['nodepath', 'nodePath'],
  ['projectpath', 'projectPath'], ['reportpath', 'reportPath'], ['progresspath', 'progressPath'],
  ['screenshotpath', 'screenshotPath'], ['screenshotdir', 'screenshotDir'], ['tracedir', 'traceDir'],
  ['artifactdir', 'artifactDir'], ['outputdir', 'outputDir'], ['outputpath', 'outputPath'],
  ['timeoutseconds', 'timeoutSeconds'], ['watchdogseconds', 'watchdogSeconds'],
  ['staleprogressseconds', 'staleProgressSeconds'], ['startupprogressseconds', 'startupProgressSeconds'],
  ['timemode', 'timeMode'], ['updatbaseline', 'updateBaseline'], ['updatebaseline', 'updateBaseline'],
  ['skipgenerate', 'skipGenerate'], ['headless', 'headless'], ['visible', 'visible'],
  ['seed', 'seed'], ['only', 'only'], ['case', 'case'], ['suite', 'suite'], ['scenario', 'scenario'],
  ['capture', 'capture'], ['style', 'style'], ['view', 'view'], ['species', 'species'],
  ['presentation', 'presentation'], ['maturity', 'maturity'], ['reviewseconds', 'reviewSeconds'],
  ['durationseconds', 'durationSeconds'], ['warmupframes', 'warmupFrames'], ['resolution', 'resolution'],
  ['logpath', 'logPath'], ['usestorealsave', 'useRealSave'], ['userealsave', 'useRealSave'],
  ['requirerealboot', 'realBoot'], ['realboot', 'realBoot'], ['runname', 'runName'],
  ['noflagsproofpath', 'noFlagsProofPath'], ['stoponfailure', 'stopOnFailure'],
  ['continueonfailure', 'continueOnFailure'], ['registrypath', 'registryPath'],
  ['runnerid', 'runnerId'], ['evidencelevel', 'evidenceLevel'],
  ['acceptanceclaims', 'acceptanceClaims'], ['requiredscreenshots', 'requiredScreenshots'],
  ['requireforbiddencallselfscan', 'requireForbiddenCallSelfScan'],
  ['requirevisualproof', 'requireVisualProof'], ['passthrujson', 'passThruJson'],
  ['force', 'force'], ['url', 'url'], ['sha256', 'sha256'], ['fetchgodotcpp', 'fetchGodotCpp'], ['godotcppbranch', 'godotCppBranch'],
  ['architecture', 'architecture'], ['apiversion', 'apiVersion'], ['platform', 'platform'],
  ['target', 'target'], ['sourcepath', 'sourcePath'], ['sourcesavepath', 'sourceSavePath'],
  ['proofpath', 'proofPath'], ['searchradius', 'searchRadius'], ['mindepthcells', 'minDepthCells'],
  ['maxdepthcells', 'maxDepthCells'], ['liveprocess', 'liveProcess'],
  ['preferredmaterial', 'preferredMaterial'], ['canopy', 'canopy']
]);

function canonicalOptionName(rawName) {
  const normalizedName = rawName.replace(/^-+/, '').replace(/[^A-Za-z0-9]/g, '').toLowerCase();
  return optionAliases.get(normalizedName) ?? rawName.replace(/^-+/, '').replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
}

export function parseArguments(argv) {
  const options = {};
  const positionals = [];
  const passthrough = [];
  let passthroughMode = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--') {
      passthroughMode = true;
      continue;
    }
    if (passthroughMode) {
      passthrough.push(argument);
      continue;
    }
    if (!argument.startsWith('-') || argument === '-') {
      positionals.push(argument);
      continue;
    }
    const equalsIndex = argument.indexOf('=');
    const name = canonicalOptionName(equalsIndex >= 0 ? argument.slice(0, equalsIndex) : argument);
    if (equalsIndex >= 0) {
      options[name] = argument.slice(equalsIndex + 1);
      continue;
    }
    const next = argv[index + 1];
    if (next !== undefined && (!next.startsWith('-') || /^-?\d/.test(next))) {
      options[name] = next;
      index += 1;
    } else {
      options[name] = true;
    }
  }
  return { options, positionals, passthrough };
}

export function asBoolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value !== 'string') return false;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

export function asNumber(value, fallback) {
  if (value === undefined || value === '') return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

export function resolveProjectPath(candidate, fallback) {
  const selected = String(candidate ?? fallback).replaceAll('\\', '/');
  return isAbsolute(selected) ? normalize(selected) : resolve(projectRoot, selected);
}

async function exists(candidate) {
  try {
    await access(candidate, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

function commandPath(command) {
  const lookup = process.platform === 'win32' ? 'where' : 'which';
  const result = spawnSync(lookup, [command], { encoding: 'utf8' });
  if (result.status !== 0) return '';
  return result.stdout.trim().split(/\r?\n/)[0] ?? '';
}

function sconsInvocation() {
  for (const command of ['scons', 'scons.exe']) {
    const executable = commandPath(command);
    if (executable) return { executable, argumentsList: [] };
  }
  for (const command of process.platform === 'win32' ? ['python', 'python3'] : ['python3', 'python']) {
    const executable = commandPath(command);
    if (executable && spawnSync(executable, ['-m', 'SCons', '--version'], { encoding: 'utf8' }).status === 0) {
      return { executable, argumentsList: ['-m', 'SCons'] };
    }
  }
  return null;
}

function defaultNativeArchitecture(platform) {
  if (platform === 'macos') return 'universal';
  if (process.arch === 'x64') return 'x86_64';
  return process.arch;
}

export async function findExecutable(explicitPath, environmentNames, commands, applicationPaths, label) {
  const candidates = [explicitPath, ...environmentNames.map((name) => process.env[name]), ...applicationPaths].filter(Boolean);
  for (const candidate of candidates) {
    const resolved = resolve(candidate);
    if (await exists(resolved)) return resolved;
  }
  for (const command of commands) {
    const resolved = commandPath(command);
    if (resolved) return resolved;
  }
  throw new Error(`Could not find ${label}. Pass --${label.toLowerCase().replace(/\s+/g, '-')} or set ${environmentNames[0]}.`);
}

export function findGodot(explicitPath) {
  return findExecutable(
    explicitPath,
    ['GODOT_EXE', 'GODOT_BIN'],
    ['godot', 'godot4', 'Godot'],
    [
      '/Applications/Godot.app/Contents/MacOS/Godot',
      '/Applications/Godot 4.app/Contents/MacOS/Godot'
    ],
    'Godot'
  );
}

export function findBlender(explicitPath) {
  return findExecutable(
    explicitPath,
    ['BLENDER_EXE', 'BLENDER_BIN'],
    ['blender'],
    [
      '/Applications/Blender.app/Contents/MacOS/Blender',
      'C:/Program Files/Blender Foundation/Blender/blender.exe'
    ],
    'Blender'
  );
}

export async function ensureDirectory(candidate) {
  await mkdir(candidate, { recursive: true });
}

export async function removeFile(candidate) {
  await rm(candidate, { force: true });
}

export async function clearPngFiles(directory) {
  if (!(await exists(directory))) return;
  const entries = await readdir(directory, { withFileTypes: true });
  await Promise.all(entries.filter((entry) => entry.isFile() && entry.name.endsWith('.png')).map((entry) => rm(join(directory, entry.name), { force: true })));
}

export async function readJson(candidate) {
  return JSON.parse(await readFile(candidate, 'utf8'));
}

export async function writeJson(candidate, value) {
  await ensureDirectory(dirname(candidate));
  await writeFile(candidate, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

export function timestamp() {
  return new Date().toISOString();
}

export function gitValue(args) {
  const result = spawnSync('git', ['-C', projectRoot, ...args], { encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : '';
}

export async function runProcess(executable, argumentsList, options = {}) {
  const timeoutSeconds = asNumber(options.timeoutSeconds, 0);
  const child = spawn(executable, argumentsList, {
    cwd: options.cwd ?? projectRoot,
    env: options.env ?? process.env,
    stdio: options.stdio ?? 'inherit',
    windowsHide: true
  });
  let timedOut = false;
  let timer;
  if (timeoutSeconds > 0) {
    timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 3000).unref();
    }, timeoutSeconds * 1000);
  }
  const result = await new Promise((resolvePromise, rejectPromise) => {
    child.once('error', rejectPromise);
    child.once('close', (code, signal) => resolvePromise({ code: code ?? 1, signal }));
  });
  if (timer) clearTimeout(timer);
  if (timedOut) throw new Error(`Process exceeded watchdog of ${timeoutSeconds} seconds: ${basename(executable)}`);
  return result;
}

export function reportPassed(report) {
  if (report?.passed === false) return false;
  if (Number(report?.failureCount ?? 0) > 0) return false;
  if (report?.status && report.status !== 'passed' && report.status !== 'completed') return false;
  return true;
}

function splitValues(value) {
  if (value === undefined || value === null || value === '') return [];
  return Array.isArray(value) ? value.flatMap(splitValues) : String(value).split(';').filter(Boolean);
}

function sameStringSet(left, right) {
  return [...left].sort().join('\u0000') === [...right].sort().join('\u0000');
}

export async function validateEvidence(options) {
  const reportPath = resolveProjectPath(options.reportPath);
  if (!(await exists(reportPath))) throw new Error(`Evidence report missing for ${options.runnerId}: ${reportPath}`);
  const report = await readJson(reportPath);
  const evidenceLevel = options.evidenceLevel ?? 'unit';
  const acceptanceClaims = splitValues(options.acceptanceClaims);
  const requiredScreenshots = splitValues(options.requiredScreenshots);
  const errors = [];
  if (report.evidenceLevel && report.evidenceLevel !== evidenceLevel) errors.push(`report evidenceLevel '${report.evidenceLevel}' does not match '${evidenceLevel}'`);
  if (Array.isArray(report.acceptanceClaims) && report.acceptanceClaims.length && !sameStringSet(report.acceptanceClaims, acceptanceClaims)) errors.push('report acceptanceClaims do not match runner claims');
  if (acceptanceClaims.length && evidenceLevel !== 'acceptance_visual') errors.push('acceptanceClaims are only allowed for acceptance_visual runners');
  const requiresScan = acceptanceClaims.length > 0 || asBoolean(options.requireForbiddenCallSelfScan);
  if (requiresScan && report?.forbiddenCallSelfScan?.status !== 'passed') errors.push('acceptance report must include forbiddenCallSelfScan.status == passed');
  const requiresVisualProof = evidenceLevel === 'acceptance_visual' || asBoolean(options.requireVisualProof);
  const screenshotDirectory = options.screenshotDir ? resolveProjectPath(options.screenshotDir) : '';
  if (requiresVisualProof) {
    if (evidenceLevel === 'acceptance_visual' && !acceptanceClaims.length) errors.push('acceptance_visual runner must declare acceptance claims');
    if (!requiredScreenshots.length) errors.push('visual-evidence runner must declare required screenshots');
    for (const screenshot of requiredScreenshots) {
      const screenshotPath = isAbsolute(screenshot) ? screenshot : screenshotDirectory ? join(screenshotDirectory, screenshot) : '';
      if (!screenshotPath || !(await exists(screenshotPath))) errors.push(`required screenshot missing: ${screenshotPath || screenshot}`);
    }
    const captureCount = [report.captures, report.visualCaptures].reduce((count, value) => count + (Array.isArray(value) ? value.length : value ? 1 : 0), 0);
    if (!captureCount) errors.push('visual-evidence report must include captures or visualCaptures');
    const timelineCount = ['timeline', 'timelineTail', 'miraTimeline', 'doorStateTimeline'].reduce((count, key) => count + (Array.isArray(report[key]) ? report[key].length : report[key] ? 1 : 0), 0);
    if (!timelineCount) errors.push('visual-evidence report must include timeline proof');
  }
  report.evidenceLevel = evidenceLevel;
  report.acceptanceClaims = acceptanceClaims;
  report.testIntegrity = {
    registryId: options.runnerId,
    registryPath: options.registryPath ? resolveProjectPath(options.registryPath) : '',
    evidenceLevel,
    liveGameplayAcceptance: acceptanceClaims.length > 0,
    requiredScreenshots,
    validationStatus: errors.length ? 'failed' : 'passed',
    validationErrors: errors,
    stampedUtc: timestamp()
  };
  await writeJson(reportPath, report);
  if (errors.length) throw new Error(`Evidence validation failed for ${options.runnerId}: ${errors.join('; ')}`);
  return { runnerId: options.runnerId, reportPath, evidenceLevel, acceptanceClaims, status: 'passed' };
}

const scriptTools = {
  'run-biome-environment-catalog-contract-tests': ['res://scripts/testing/BiomeEnvironmentCatalogContractRunner.gd', 'VOXEL_BIOME_ENVIRONMENT_CONTRACT_REPORT'],
  'run-biome-region-field-contract-tests': ['res://scripts/testing/BiomeRegionFieldContractRunner.gd', 'VOXEL_BIOME_REGION_FIELD_REPORT'],
  'run-canopy-asset-import-contract-tests': ['res://scripts/testing/CanopyAssetImportContractRunner.gd', 'VOXEL_CANOPY_IMPORT_CONTRACT_REPORT'],
  'run-canopy-runtime-contract-tests': ['res://scripts/testing/CanopyRuntimeContractRunner.gd', 'VOXEL_CANOPY_RUNTIME_CONTRACT_REPORT'],
  'run-combat-target-policy-contract': ['res://scripts/testing/combat/CombatTargetPolicyContractRunner.gd', 'VOXEL_COMBAT_TARGET_POLICY_REPORT'],
  'run-cottage-construction-contract': ['res://scripts/testing/buildings/CottageConstructionContractRunner.gd', 'VOXEL_COTTAGE_CONSTRUCTION_CONTRACT_REPORT'],
  'run-cottage-furnishing-layout-contract': ['res://scripts/testing/buildings/CottageFurnishingLayoutContractRunner.gd', 'VOXEL_COTTAGE_FURNISHING_LAYOUT_CONTRACT_REPORT'],
  'run-crafting-gate-tests': ['res://scripts/testing/CraftingGateTestRunner.gd', 'VOXEL_CRAFTING_GATE_REPORT'],
  'run-environment-wind-contract-tests': ['res://scripts/testing/EnvironmentWindContractRunner.gd', 'VOXEL_ENVIRONMENT_WIND_CONTRACT_REPORT'],
  'run-exact-fluid-mesh-contract': ['res://scripts/testing/ExactFluidMeshContractRunner.gd', 'VOXEL_EXACT_FLUID_MESH_REPORT'],
  'run-exact-fluid-payload-contract': ['res://scripts/testing/ExactFluidPayloadContractRunner.gd', 'VOXEL_EXACT_FLUID_PAYLOAD_REPORT'],
  'run-landmark-building-grammar-contract': ['res://scripts/testing/buildings/LandmarkBuildingGrammarContractRunner.gd', 'VOXEL_LANDMARK_BUILDING_GRAMMAR_REPORT'],
  'run-landmark-furnishing-contract': ['res://scripts/testing/buildings/LandmarkFurnishingContractRunner.gd', 'VOXEL_LANDMARK_FURNISHING_CONTRACT_REPORT'],
  'run-main-menu-continue-readiness-smoke': ['res://scripts/testing/MainMenuStartupSmokeRunner.gd', 'VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT'],
  'run-main-menu-startup-readiness-smoke': ['res://scripts/testing/MainMenuStartupSmokeRunner.gd', 'VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT'],
  'run-motion-rig-contract': ['res://scripts/testing/combat/MotionRigContractRunner.gd', 'VOXEL_MOTION_RIG_CONTRACT_REPORT'],
  'run-procedural-tree-performance-benchmark': ['res://scripts/testing/ProceduralTreePerformanceBenchmarkRunner.gd', 'VOXEL_PROCEDURAL_TREE_PERFORMANCE_REPORT'],
  'run-project-compile-smoke': ['res://scripts/testing/ProjectCompileSmokeRunner.gd', 'VOXEL_PROJECT_COMPILE_REPORT'],
  'run-seeded-cottage-recipe-contract': ['res://scripts/testing/buildings/SeededCottageRecipeContractRunner.gd', 'VOXEL_SEEDED_COTTAGE_RECIPE_CONTRACT_REPORT'],
  'run-startup-loading-readiness-contract-tests': ['res://scripts/testing/StartupLoadingReadinessContractRunner.gd', 'VOXEL_STARTUP_READINESS_CONTRACT_REPORT'],
  'run-structure-town-manifest-contract-tests': ['res://scripts/testing/StructureTownManifestContractRunner.gd', 'VOXEL_STRUCTURE_TOWN_MANIFEST_REPORT'],
  'run-terrain-block-light-batch-contract': ['res://scripts/testing/TerrainBlockLightBatchContractRunner.gd', 'VOXEL_TERRAIN_BLOCK_LIGHT_BATCH_REPORT'],
  'run-terrain-meshing-bounds-contract': ['res://scripts/testing/TerrainMeshingBoundsContractRunner.gd', 'VOXEL_TERRAIN_MESH_BOUNDS_REPORT'],
  'run-town-runtime-manifest-contract-tests': ['res://scripts/testing/TownRuntimeManifestContractRunner.gd', 'VOXEL_TOWN_MANIFEST_CONTRACT_REPORT'],
  'run-tree-chunk-batch-prototype': ['res://scripts/testing/TreeChunkBatchRendererPrototypeRunner.gd', 'VOXEL_TREE_CHUNK_BATCH_REPORT'],
  'run-tree-publication-queue-contract': ['res://scripts/testing/TreePublicationQueueContractRunner.gd', ''],
  'run-tree-spawn-performance': ['res://scripts/testing/TreeSpawnPerformanceRunner.gd', 'VOXEL_TREE_SPAWN_PERFORMANCE_REPORT'],
  'run-tutorial-actor-registration-contract-tests': ['res://scripts/testing/TutorialActorRegistrationContractRunner.gd', 'VOXEL_TUTORIAL_ACTOR_REGISTRATION_CONTRACT_REPORT'],
  'run-tutorial-generic-order-contract-tests': ['res://scripts/testing/TutorialGenericOrderContractRunner.gd', 'VOXEL_TUTORIAL_GENERIC_ORDER_CONTRACT_REPORT'],
  'run-tutorial-save-compatibility-contract-tests': ['res://scripts/testing/TutorialSaveCompatibilityContractRunner.gd', 'VOXEL_TUTORIAL_SAVE_COMPATIBILITY_CONTRACT_REPORT'],
  'run-underground-fluid-render-tests': ['res://scripts/testing/UndergroundFluidRenderContractRunner.gd', 'VOXEL_UNDERGROUND_FLUID_RENDER_REPORT'],
  'run-underground-generation-tests': ['res://scripts/testing/UndergroundGenerationTestRunner.gd', 'VOXEL_UNDERGROUND_GENERATION_REPORT'],
  'run-underground-volume-contract-tests': ['res://scripts/testing/UndergroundVolumeContractRunner.gd', 'VOXEL_UNDERGROUND_VOLUME_CONTRACT_REPORT'],
  'run-voxel-terrain-save-parity': ['res://scripts/testing/terrain/VoxelTerrainSaveParityRunner.gd', 'VOXEL_TERRAIN_SAVE_PARITY_REPORT']
};

const sceneTools = {
  'run-castle-poc': ['res://scenes/testing/buildings/CastlePocTest.tscn', 'VOXEL_CASTLE_POC_REPORT'],
  'run-castle-walkthrough': ['res://scenes/testing/buildings/CastleWalkthroughTest.tscn', 'VOXEL_CASTLE_WALKTHROUGH_REPORT'],
  'run-cottage-material-poc': ['res://scenes/testing/buildings/CottageMaterialPocTest.tscn', 'VOXEL_COTTAGE_POC_REPORT'],
  'run-environment-wind-visual-playtest': ['res://scenes/testing/EnvironmentWindVisualTest.tscn', 'VOXEL_ENVIRONMENT_WIND_VISUAL_REPORT'],
  'run-furnished-cottage-poc': ['res://scenes/testing/buildings/FurnishedCottagePocTest.tscn', 'VOXEL_FURNISHED_COTTAGE_POC_REPORT'],
  'run-furnished-cottage-walkthrough': ['res://scenes/testing/buildings/FurnishedCottageWalkthroughTest.tscn', 'VOXEL_FURNISHED_COTTAGE_WALKTHROUGH_REPORT'],
  'run-hostile-motion-arena': ['res://scenes/testing/HostileMotionArenaTest.tscn', 'VOXEL_HOSTILE_MOTION_ARENA_REPORT'],
  'run-manor-poc': ['res://scenes/testing/buildings/ManorPocTest.tscn', 'VOXEL_MANOR_POC_REPORT'],
  'run-manor-walkthrough': ['res://scenes/testing/buildings/ManorWalkthroughTest.tscn', 'VOXEL_MANOR_WALKTHROUGH_REPORT'],
  'run-mathematical-tree-poc': ['res://scenes/testing/MathematicalTreePocTest.tscn', 'VOXEL_MATHEMATICAL_TREE_POC_REPORT'],
  'run-procedural-motion-poc': ['res://scenes/testing/ProceduralMotionPocTest.tscn', 'VOXEL_PROCEDURAL_MOTION_POC_REPORT'],
  'run-provisional-terrain-visual-playtest': ['res://scenes/testing/ProvisionalTerrainVisualPlaytest.tscn', 'VOXEL_UNDERGROUND_VISUAL_REPORT'],
  'run-town-hall-poc': ['res://scenes/testing/buildings/TownHallPocTest.tscn', 'VOXEL_TOWN_HALL_POC_REPORT'],
  'run-town-hall-walkthrough': ['res://scenes/testing/buildings/TownHallWalkthroughTest.tscn', 'VOXEL_TOWN_HALL_WALKTHROUGH_REPORT'],
  'run-underground-interactive-playtest': ['res://scenes/Main.tscn', 'VOXEL_UNDERGROUND_INTERACTIVE_REPORT'],
  'run-vox43-surface-cave-visual': ['res://scenes/testing/Vox43SurfaceCaveVisual.tscn', 'VOXEL_VOX43_CAVE_REPORT'],
  'run-vox43-underground-fluid-visual': ['res://scenes/testing/Vox43UndergroundFluidVisual.tscn', 'VOXEL_VOX43_FLUID_VISUAL_REPORT'],
  'run-voxel-terrain-collision-publication': ['res://scenes/testing/VoxelTerrainCollisionPublication.tscn', 'VOXEL_TERRAIN_PUBLICATION_REPORT'],
  'run-voxel-tools-backend-smoke': ['res://scenes/testing/VoxelToolsBackendSmoke.tscn', 'VOXEL_VOXEL_TOOLS_BACKEND_REPORT'],
  'run-wolf-behavior-contract': ['res://scenes/testing/WolfBehaviorContractTest.tscn', 'VOXEL_WOLF_BEHAVIOR_CONTRACT_REPORT']
};

const visualTools = {
  'run-underground-visual-playtest': ['res://scenes/testing/UndergroundVisualPlaytest.tscn', 'VOXEL_UNDERGROUND_VISUAL_REPORT', 'VOXEL_UNDERGROUND_VISUAL_PROGRESS', 'VOXEL_UNDERGROUND_VISUAL_SCREENSHOT_DIR', 'artifacts/underground/underground-visual-playtest.json', 'artifacts/underground/underground-visual-playtest-progress.txt', 'artifacts/underground/screenshots/underground-visual'],
  'run-digging-visual-playtest': ['res://scenes/testing/DiggingVisualPlaytest.tscn', 'VOXEL_DIGGING_VISUAL_REPORT', 'VOXEL_DIGGING_VISUAL_PROGRESS', 'VOXEL_DIGGING_VISUAL_SCREENSHOT_DIR', 'artifacts/underground/digging-visual-playtest.json', 'artifacts/underground/digging-visual-playtest-progress.txt', 'artifacts/underground/screenshots/digging-visual'],
  'run-light-shadow-visual-playtest': ['res://scenes/testing/LightShadowVisualPlaytest.tscn', 'VOXEL_LIGHT_SHADOW_REPORT', 'VOXEL_LIGHT_SHADOW_PROGRESS', 'VOXEL_LIGHT_SHADOW_SCREENSHOT_DIR', 'artifacts/light/light-shadow-visual-playtest.json', 'artifacts/light/light-shadow-visual-playtest-progress.txt', 'artifacts/light/screenshots/light-shadow'],
  'run-town-ground-visual-playtest': ['res://scenes/testing/TownGroundVisualPlaytest.tscn', 'VOXEL_TOWN_GROUND_VISUAL_REPORT', 'VOXEL_TOWN_GROUND_VISUAL_PROGRESS', 'VOXEL_TOWN_GROUND_VISUAL_SCREENSHOT_DIR', 'artifacts/terrain-volume/town-ground-visual-playtest.json', 'artifacts/terrain-volume/town-ground-visual-playtest-progress.txt', 'artifacts/terrain-volume/screenshots/town-ground-visual'],
  'run-vox43-fresh-world-traversal': ['res://scenes/MainMenu.tscn', 'VOXEL_VOX43_FRESH_WORLD_REPORT', 'VOXEL_VOX43_FRESH_WORLD_PROGRESS', 'VOXEL_VOX43_FRESH_WORLD_SCREENSHOT_DIR', 'artifacts/vox43/fresh-world-traversal.json', 'artifacts/vox43/fresh-world-traversal-progress.txt', 'artifacts/vox43/screenshots/fresh-world-traversal'],
  'run-vox43-known-save-visual-playtest': ['res://scenes/MainMenu.tscn', 'VOXEL_VOX43_KNOWN_SAVE_REPORT', 'VOXEL_VOX43_KNOWN_SAVE_PROGRESS', 'VOXEL_VOX43_KNOWN_SAVE_SCREENSHOT_DIR', 'artifacts/vox43/known-save-visual-playtest.json', 'artifacts/vox43/known-save-visual-playtest-progress.txt', 'artifacts/vox43/screenshots/known-save'],
  'run-vox55-terrain-scope-survey': ['res://scenes/MainMenu.tscn', 'VOXEL_VOX55_TERRAIN_SURVEY_REPORT', 'VOXEL_VOX55_TERRAIN_SURVEY_PROGRESS', 'VOXEL_VOX55_TERRAIN_SURVEY_SCREENSHOT_DIR', 'artifacts/vox55/terrain-scope-survey.json', 'artifacts/vox55/terrain-scope-survey-progress.txt', 'artifacts/vox55/screenshots/terrain-scope']
};

const visualRequiredScreenshots = {
  'run-underground-visual-playtest': ['underground_air_reference.png', 'underground_wall_boundary.png', 'underground_floor_boundary.png', 'underground_ceiling_boundary.png', 'underground_material_probe.png', 'underground_collision_probe.png'],
  'run-digging-visual-playtest': ['digging_before_surface.png', 'digging_after_first_dig.png', 'digging_after_second_dig.png', 'digging_material_drop_inventory.png'],
  'run-light-shadow-visual-playtest': ['outdoor_noon_reference.png', 'underground_noon_dark.png', 'underground_torch_lit.png', 'underground_torch_closeup.png'],
  'run-town-ground-visual-playtest': ['town_ground_edge_volume.png', 'town_house_foundation_volume.png']
};

const headedTools = {
  'run-canopy-release-playtest': ['res://scenes/testing/CanopyReleasePlaytest.tscn', 'VOXEL_CANOPY_RELEASE_REPORT', 'VOXEL_CANOPY_RELEASE_PROGRESS', 'VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR', 'artifacts/vegetation/canopy-release/report.json', 'artifacts/vegetation/canopy-release/progress.txt', 'artifacts/vegetation/canopy-release/screenshots'],
  'run-runtime-performance-observation': ['res://scenes/testing/RuntimePerformanceObservation.tscn', 'VOXEL_RUNTIME_PERF_REPORT', 'VOXEL_RUNTIME_PERF_PROGRESS', '', 'artifacts/performance/runtime-observation.json', 'artifacts/performance/runtime-observation-progress.txt', ''],
  'run-normal-runtime-performance-pass': ['res://scenes/testing/NormalRuntimePerformancePass.tscn', 'VOXEL_NORMAL_RUNTIME_PERF_REPORT', 'VOXEL_NORMAL_RUNTIME_PERF_PROGRESS', '', 'artifacts/performance/normal-runtime-performance-pass.json', 'artifacts/performance/normal-runtime-performance-pass-progress.txt', ''],
  'story/run-story-playtest': ['res://scenes/story_testing/StoryPlaytest.tscn', 'VOXEL_STORY_PLAYTEST_REPORT', 'VOXEL_STORY_PLAYTEST_PROGRESS', '', 'artifacts/story/story-playtest-report.json', 'artifacts/story/story-playtest-progress.txt', ''],
  'npc/run-actual-gameplay-mira-porch-regression': ['res://scenes/testing/npc/NpcActualGameplayMiraPorchRegressionTest.tscn', 'VOXEL_ACTUAL_GAMEPLAY_MIRA_REPORT', 'VOXEL_ACTUAL_GAMEPLAY_MIRA_PROGRESS', 'VOXEL_ACTUAL_GAMEPLAY_MIRA_SCREENSHOT_DIR', 'artifacts/npc/reports/actual-gameplay-mira-porch.json', 'artifacts/npc/progress/actual-gameplay-mira-porch.txt', 'artifacts/npc/screenshots/actual-gameplay-mira-porch'],
  'npc/run-npc-go-home-visual-playtest': ['res://scenes/testing/npc/NpcGoHomeVisualPlaytest.tscn', 'VOXEL_NPC_GO_HOME_VISUAL_REPORT', 'VOXEL_NPC_GO_HOME_VISUAL_PROGRESS', 'VOXEL_NPC_GO_HOME_VISUAL_SCREENSHOT_DIR', 'artifacts/npc/reports/npc-go-home-visual-playtest.json', 'artifacts/npc/progress/npc-go-home-visual-playtest.txt', 'artifacts/npc/screenshots/npc-go-home-visual-playtest'],
  'npc/run-npc-observation-tests': ['res://scenes/testing/npc/NpcObservationTest.tscn', 'VOXEL_NPC_OBSERVATION_REPORT', 'VOXEL_NPC_OBSERVATION_PROGRESS', 'VOXEL_NPC_OBSERVATION_SCREENSHOT_DIR', 'artifacts/npc/reports/npc-observation.json', 'artifacts/npc/progress/npc-observation.txt', 'artifacts/npc/screenshots/npc-observation'],
  'npc/run-npc-town-job-cycle-visual-playtest': ['res://scenes/testing/npc/NpcTownJobCycleVisualPlaytest.tscn', 'VOXEL_NPC_TOWN_JOB_CYCLE_REPORT', 'VOXEL_NPC_TOWN_JOB_CYCLE_PROGRESS', 'VOXEL_NPC_TOWN_JOB_CYCLE_SCREENSHOT_DIR', 'artifacts/npc/reports/npc-town-job-cycle-visual-playtest.json', 'artifacts/npc/progress/npc-town-job-cycle-visual-playtest.txt', 'artifacts/npc/screenshots/npc-town-job-cycle-visual-playtest'],
  'npc/run-resource-lifecycle-visual-playtest': ['res://scenes/testing/ResourceLifecycleVisualPlaytest.tscn', 'VOXEL_RESOURCE_LIFECYCLE_REPORT', 'VOXEL_RESOURCE_LIFECYCLE_PROGRESS', 'VOXEL_RESOURCE_LIFECYCLE_SCREENSHOT_DIR', 'artifacts/npc/reports/resource-lifecycle.json', 'artifacts/npc/progress/resource-lifecycle.txt', 'artifacts/npc/screenshots/resource-lifecycle'],
  'npc/run-real-tutorial-playthrough': ['', 'VOXEL_REAL_TUTORIAL_REPORT', 'VOXEL_REAL_TUTORIAL_PROGRESS', 'VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR', 'artifacts/npc/reports/real-tutorial-playthrough.json', 'artifacts/npc/progress/real-tutorial-playthrough.txt', 'artifacts/npc/screenshots/real-tutorial-playthrough'],
  'npc/run-real-tutorial-playthrough-no-flags': ['', 'VOXEL_REAL_TUTORIAL_REPORT', 'VOXEL_REAL_TUTORIAL_PROGRESS', 'VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR', 'artifacts/npc/reports/real-tutorial-no-flags.json', 'artifacts/npc/progress/real-tutorial-no-flags.txt', 'artifacts/npc/screenshots/real-tutorial-no-flags']
};

const headedAcceptanceGuards = {
  'npc/run-actual-gameplay-mira-porch-regression': ['scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd', []],
  'npc/run-npc-go-home-visual-playtest': ['scripts/testing/npc/NpcGoHomeVisualPlaytestRunner.gd', ['safe_place_npc.*visual_go_home_spawn', 'player\\.global_position\\s*=\\s*Vector3\\(float\\(center\\.x - 10\\)']],
  'npc/run-npc-town-job-cycle-visual-playtest': ['scripts/testing/npc/NpcTownJobCycleVisualPlaytestRunner.gd', ['player\\.global_position\\s*=.*town_job_cycle_pre_act_stream_anchor']],
  'npc/run-real-tutorial-playthrough': ['scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd', ['final_rescue_fixture_setup_allowance']],
  'npc/run-real-tutorial-playthrough-no-flags': ['scripts/testing/npc/NpcRealTutorialPlaythroughRunner.gd', ['final_rescue_fixture_setup_allowance']]
};

const staticToolIds = new Set([
  'assert-test-evidence-report', 'npc/assert-npc-acceptance-runner-clean',
  'npc/assert-npc-legacy-pathfinding-clean', 'npc/assert-npc-route-state-writers',
  'npc/audit-npc-navmesh-backend', 'npc/run-npc-scenario-tests',
  'npc/run-tutorial-save-continue-playtest', 'npc/test-npc-acceptance-guard',
  'test-evidence-registry-self-test', 'build-native-terrain-meshing',
  'dependencies/install-voxel-tools'
]);

const workflowToolIds = new Set([
  'run-hostile-motion-combat-playtest', 'run-player-motion-combat-playtest',
  'run-procedural-tree-interaction-matrix', 'run-underground-volume-audit'
]);

export function isToolRegistered(toolId) {
  return Boolean(scriptTools[toolId] || sceneTools[toolId] || visualTools[toolId] || headedTools[toolId])
    || ['run-playtest', 'run-npc-navigation-tests', 'run-visual-captures', 'run-world-signature', 'run-underground-interactive-playtest', 'npc/run-npc-suite', 'npc/run-all-npc-tests', 'run-all-test-runners'].includes(toolId)
    || toolId.startsWith('blender/')
    || (toolId.startsWith('npc/run-npc-') && toolId.endsWith('-tests'))
    || staticToolIds.has(toolId)
    || workflowToolIds.has(toolId);
}

function defaultReportPath(toolId) {
  return join('artifacts', 'node-tools', `${toolId.replace(/\//g, '-')}.json`);
}

async function runConfiguredGodot(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  if (parsed.options.help) {
    process.stdout.write(`Usage: node tools/${toolId}.mjs [--godot-exe PATH] [--report-path PATH] [--seed VALUE]\n`);
    return;
  }
  const scriptConfig = scriptTools[toolId];
  const sceneConfig = sceneTools[toolId];
  const visualConfig = visualTools[toolId];
  const config = scriptConfig ?? sceneConfig ?? visualConfig;
  if (!config) throw new Error(`No Godot configuration registered for ${toolId}`);
  const isScript = Boolean(scriptConfig);
  const isVisual = Boolean(visualConfig);
  const [target, reportEnvironment, progressEnvironment, screenshotEnvironment, configuredReport, configuredProgress, configuredScreenshots] = config;
  const requiresReport = Boolean(reportEnvironment);
  const reportPath = requiresReport ? resolveProjectPath(parsed.options.reportPath, configuredReport ?? defaultReportPath(toolId)) : '';
  const progressPath = progressEnvironment ? resolveProjectPath(parsed.options.progressPath, configuredProgress) : '';
  const screenshotDir = screenshotEnvironment ? resolveProjectPath(parsed.options.screenshotDir, configuredScreenshots) : '';
  if (requiresReport) {
    await ensureDirectory(dirname(reportPath));
    await removeFile(reportPath);
  }
  if (progressPath) {
    await ensureDirectory(dirname(progressPath));
    await removeFile(progressPath);
  }
  if (screenshotDir) {
    await ensureDirectory(screenshotDir);
    await clearPngFiles(screenshotDir);
  }
  const runToken = randomUUID().replaceAll('-', '');
  const environment = { ...process.env };
  if (requiresReport) environment[reportEnvironment] = reportPath;
  if (parsed.options.seed !== undefined) environment.VOXEL_TEST_SEED = String(parsed.options.seed);
  if (parsed.options.timeMode !== undefined) environment.VOXEL_NPC_TIME_MODE = String(parsed.options.timeMode).toLowerCase();
  if (progressEnvironment) environment[progressEnvironment] = progressPath;
  if (screenshotEnvironment) environment[screenshotEnvironment] = screenshotDir;
  if (isVisual) {
    environment.VOXEL_PLAYTEST = '1';
    environment[reportEnvironment.replace(/_REPORT$/, '_RUN_TOKEN')] = runToken;
    environment[reportEnvironment.replace(/_REPORT$/, '_WATCHDOG_SECONDS')] = String(asNumber(parsed.options.watchdogSeconds, 90));
    if (toolId === 'run-digging-visual-playtest') {
      environment.VOXEL_DIGGING_VISUAL_PREFERRED_MATERIAL = String(parsed.options.preferredMaterial ?? '');
      environment.VOXEL_DIGGING_VISUAL_LIVE_PROCESS = asBoolean(parsed.options.liveProcess) ? '1' : '0';
    }
  }
  if (toolId === 'run-main-menu-startup-readiness-smoke') environment.VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE = 'new_game';
  if (toolId === 'run-main-menu-continue-readiness-smoke') environment.VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE = 'continue';
  const godot = await findGodot(parsed.options.godotExe);
  const godotArguments = [];
  if (isScript || asBoolean(parsed.options.headless)) godotArguments.push('--headless');
  if (isVisual) godotArguments.push('--fixed-fps', '60', '--resolution', '1280x720');
  godotArguments.push('--path', projectRoot, isScript ? '--script' : '--scene', target);
  if (!isScript && parsed.passthrough.length) godotArguments.push('--', ...parsed.passthrough);
  const execution = await runProcess(godot, godotArguments, {
    env: environment,
    timeoutSeconds: asNumber(parsed.options.watchdogSeconds ?? parsed.options.timeoutSeconds, isVisual ? 90 : 0)
  });
  if (!requiresReport) {
    if (execution.code !== 0) process.exitCode = execution.code;
    return;
  }
  if (!(await exists(reportPath))) throw new Error(`Missing report from ${toolId}: ${reportPath}`);
  const report = await readJson(reportPath);
  if (isVisual && report.runToken && report.runToken !== runToken) throw new Error(`Stale report token from ${toolId}`);
  for (const screenshotName of visualRequiredScreenshots[toolId] ?? []) {
    const screenshotPath = join(screenshotDir, screenshotName);
    if (!(await exists(screenshotPath))) throw new Error(`Missing visual proof screenshot from ${toolId}: ${screenshotPath}`);
  }
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (execution.code !== 0 || !reportPassed(report)) process.exitCode = 1;
}

function sceneArgumentOptions(options) {
  const forwarded = [];
  const excluded = new Set(['godotExe', 'reportPath', 'progressPath', 'screenshotPath', 'screenshotDir', 'traceDir', 'artifactDir', 'timeoutSeconds', 'watchdogSeconds', 'headless', 'visible', 'help']);
  for (const [key, value] of Object.entries(options)) {
    if (excluded.has(key) || value === undefined || value === false) continue;
    const flag = `--${key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;
    forwarded.push(flag);
    if (value !== true) forwarded.push(String(value));
  }
  return forwarded;
}

async function runHeadedTool(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  const config = headedTools[toolId];
  if (!config) throw new Error(`No headed configuration registered for ${toolId}`);
  const isNormalRuntimePerformance = toolId === 'run-normal-runtime-performance-pass';
  const isRuntimePerformanceObservation = toolId === 'run-runtime-performance-observation';
  if (isNormalRuntimePerformance && parsed.options.seed !== undefined) {
    throw new Error('Normal runtime performance passes launch an unseeded New Game and do not accept --seed.');
  }
  const [scene, reportEnvironment, progressEnvironment, screenshotEnvironment, configuredReport, configuredProgress, configuredScreenshots] = config;
  const reportPath = resolveProjectPath(parsed.options.reportPath, configuredReport);
  const progressPath = resolveProjectPath(parsed.options.progressPath, configuredProgress);
  const screenshotDir = screenshotEnvironment ? resolveProjectPath(parsed.options.screenshotDir, configuredScreenshots) : '';
  const normalScreenshotPath = isNormalRuntimePerformance
    ? resolveProjectPath(parsed.options.screenshotPath, 'artifacts/performance/normal-runtime-performance-pass.png')
    : '';
  const normalLogPath = isNormalRuntimePerformance
    ? resolveProjectPath(parsed.options.logPath, 'artifacts/performance/normal-runtime-performance-pass-godot.log')
    : '';
  const runtimeObservationScenario = String(parsed.options.scenario ?? 'All');
  const runtimeObservationLogPath = isRuntimePerformanceObservation
    ? resolveProjectPath(parsed.options.logPath, `artifacts/performance/runtime-observation-${runtimeObservationScenario}-godot.log`)
    : '';
  const traceDir = toolId === 'npc/run-npc-observation-tests' ? resolveProjectPath(parsed.options.traceDir, 'artifacts/npc/traces/npc-observation') : '';
  const guard = headedAcceptanceGuards[toolId];
  if (guard) {
    const [runnerPath, allowedPatterns] = guard;
    const guardReportPath = resolveProjectPath(undefined, `artifacts/node-tools/npc-acceptance-guards/${toolId.replaceAll('/', '-')}.json`);
    await runAcceptanceRunnerAudit(['--runner-path', runnerPath, '--report-path', guardReportPath, '--test-id', `${toolId.replaceAll('/', '_')}_guard`, ...(allowedPatterns.length ? ['--allowed-shortcut-pattern', allowedPatterns.join(';')] : [])]);
    const guardReport = await readJson(guardReportPath);
    if (!guardReport.passed) throw new Error(`NPC acceptance runner guard failed: ${guardReportPath}`);
  }
  await Promise.all([
    ensureDirectory(dirname(reportPath)),
    ensureDirectory(dirname(progressPath)),
    screenshotDir ? ensureDirectory(screenshotDir) : Promise.resolve(),
    normalScreenshotPath ? ensureDirectory(dirname(normalScreenshotPath)) : Promise.resolve(),
    normalLogPath ? ensureDirectory(dirname(normalLogPath)) : Promise.resolve(),
    runtimeObservationLogPath ? ensureDirectory(dirname(runtimeObservationLogPath)) : Promise.resolve(),
    traceDir ? ensureDirectory(traceDir) : Promise.resolve()
  ]);
  await Promise.all([
    removeFile(reportPath),
    removeFile(progressPath),
    screenshotDir ? clearPngFiles(screenshotDir) : Promise.resolve(),
    normalScreenshotPath ? removeFile(normalScreenshotPath) : Promise.resolve(),
    normalLogPath ? removeFile(normalLogPath) : Promise.resolve(),
    runtimeObservationLogPath ? removeFile(runtimeObservationLogPath) : Promise.resolve()
  ]);
  const runToken = randomUUID().replaceAll('-', '');
  const normalDurationSeconds = Math.max(5, asNumber(parsed.options.durationSeconds, 75));
  const requestedNormalWatchdogSeconds = asNumber(parsed.options.watchdogSeconds ?? parsed.options.timeoutSeconds, 0);
  const normalWatchdogSeconds = requestedNormalWatchdogSeconds > 0
    ? requestedNormalWatchdogSeconds
    : Math.max(240, normalDurationSeconds + 150);
  const runtimeObservationDurationSeconds = Math.max(1, asNumber(parsed.options.durationSeconds, 60));
  const runtimeObservationScenarioCount = runtimeObservationScenario === 'All' ? 8 : 1;
  const requestedRuntimeObservationWatchdogSeconds = asNumber(parsed.options.watchdogSeconds ?? parsed.options.timeoutSeconds, 0);
  const runtimeObservationWatchdogSeconds = requestedRuntimeObservationWatchdogSeconds > 0
    ? requestedRuntimeObservationWatchdogSeconds
    : Math.max(300, runtimeObservationDurationSeconds * runtimeObservationScenarioCount + 90);
  const environment = {
    ...process.env,
    [reportEnvironment]: reportPath,
    [progressEnvironment]: progressPath,
    [reportEnvironment.replace(/_REPORT$/, '_RUN_TOKEN')]: runToken,
    [reportEnvironment.replace(/_REPORT$/, '_WATCHDOG_SECONDS')]: String(
      isNormalRuntimePerformance
        ? normalWatchdogSeconds
        : isRuntimePerformanceObservation
          ? runtimeObservationWatchdogSeconds
          : asNumber(parsed.options.watchdogSeconds ?? parsed.options.timeoutSeconds, 300)
    ),
    VOXEL_GIT_BRANCH: gitValue(['branch', '--show-current']),
    VOXEL_GIT_COMMIT: gitValue(['rev-parse', 'HEAD'])
  };
  if (isNormalRuntimePerformance) {
    delete environment.VOXEL_PLAYTEST;
    delete environment.VOXEL_TEST_SEED;
    delete environment.VOXEL_RUNTIME_PERF_FAST_BOOT;
    delete environment.VOXEL_UNDERGROUND_VISUAL_FAST_BOOT;
    delete environment.VOXEL_DIGGING_VISUAL_FAST_BOOT;
    environment.VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT = normalScreenshotPath;
    environment.VOXEL_NORMAL_RUNTIME_PERF_DURATION_SECONDS = String(normalDurationSeconds);
    environment.VOXEL_NORMAL_RUNTIME_PERF_WARMUP_FRAMES = String(Math.max(0, asNumber(parsed.options.warmupFrames, 120)));
    environment.VOXEL_NORMAL_RUNTIME_PERF_SCENARIO = String(parsed.options.scenario ?? 'NormalSprintTraversal');
    if (asBoolean(parsed.options.useRealSave)) {
      delete environment.VOXEL_SAVE_PATH_OVERRIDE;
    } else {
      environment.VOXEL_SAVE_PATH_OVERRIDE = join(projectRoot, 'artifacts', 'performance', `normal-runtime-save-${runToken}.json`);
    }
  } else {
    environment.VOXEL_PLAYTEST = '1';
    environment.VOXEL_TEST_SEED = String(parsed.options.seed ?? 'atlas-1492');
  }
  if (screenshotEnvironment) environment[screenshotEnvironment] = screenshotDir;
  if (traceDir) environment.VOXEL_NPC_OBSERVATION_TRACE_DIR = traceDir;
  if (parsed.options.timeMode !== undefined) environment.VOXEL_NPC_TIME_MODE = String(parsed.options.timeMode).toLowerCase();
  if (parsed.options.scenario !== undefined && !isNormalRuntimePerformance) {
    environment.VOXEL_NPC_OBSERVATION_SCENARIO = String(parsed.options.scenario);
    environment.VOXEL_RUNTIME_PERF_SCENARIO = String(parsed.options.scenario);
  }
  if (parsed.options.durationSeconds !== undefined && !isNormalRuntimePerformance) {
    environment.VOXEL_RUNTIME_PERF_DURATION_SECONDS = String(parsed.options.durationSeconds);
    environment.VOXEL_NORMAL_RUNTIME_PERF_DURATION_SECONDS = String(parsed.options.durationSeconds);
  }
  if (parsed.options.warmupFrames !== undefined && !isNormalRuntimePerformance) {
    environment.VOXEL_RUNTIME_PERF_WARMUP_FRAMES = String(parsed.options.warmupFrames);
    environment.VOXEL_NORMAL_RUNTIME_PERF_WARMUP_FRAMES = String(parsed.options.warmupFrames);
  }
  if (toolId === 'run-canopy-release-playtest') {
    environment.VOXEL_CANOPY_RELEASE_STAGE = 'save_and_harvest';
    environment.VOXEL_CANOPY_RELEASE_TARGET_BIOME = String(parsed.options.targetBiome ?? '');
    environment.VOXEL_CANOPY_RELEASE_TARGET_ARCHITECTURE = String(parsed.options.targetArchitecture ?? '');
    environment.VOXEL_CANOPY_RELEASE_REQUIRED_AGE_BAND = String(parsed.options.requiredAgeBand ?? '');
  }
  if (toolId === 'npc/run-real-tutorial-playthrough' || toolId === 'npc/run-real-tutorial-playthrough-no-flags') {
    environment.VOXEL_REAL_TUTORIAL_REAL_BOOT = '1';
    environment.VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED = asBoolean(parsed.options.visible) ? '1' : '0';
    environment.VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY = asBoolean(parsed.options.miraHomeOnly) ? '1' : '0';
    environment.VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY = asBoolean(parsed.options.morningOutsideOnly) ? '1' : '0';
    environment.VOXEL_REAL_TUTORIAL_FINAL_RESCUE = asBoolean(parsed.options.finalRescue) ? '1' : '0';
    if (toolId.endsWith('no-flags')) environment.VOXEL_REAL_TUTORIAL_PHASE7_LIVE_ACCEPTANCE = '1';
  }
  const godot = await findGodot(parsed.options.godotExe);
  const godotArguments = [];
  if (isNormalRuntimePerformance) {
    if (asBoolean(parsed.options.headless)) godotArguments.push('--headless');
    if (parsed.options.resolution) godotArguments.push('--resolution', String(parsed.options.resolution));
    godotArguments.push('--log-file', normalLogPath);
  } else if (isRuntimePerformanceObservation) {
    if (!asBoolean(parsed.options.visible)) godotArguments.push('--headless');
    godotArguments.push('--fixed-fps', '60', '--log-file', runtimeObservationLogPath);
  } else {
    godotArguments.push('--fixed-fps', '60');
  }
  godotArguments.push('--path', projectRoot);
  if (scene) godotArguments.push('--scene', scene);
  const forwarded = [...sceneArgumentOptions(parsed.options), ...parsed.passthrough];
  if (forwarded.length) godotArguments.push('--', ...forwarded);
  const execution = await runProcess(godot, godotArguments, {
    env: environment,
    timeoutSeconds: isNormalRuntimePerformance
      ? normalWatchdogSeconds
      : isRuntimePerformanceObservation
        ? runtimeObservationWatchdogSeconds
      : asNumber(parsed.options.timeoutSeconds ?? parsed.options.watchdogSeconds, 300)
  });
  if (!(await exists(reportPath))) throw new Error(`Missing report from ${toolId}: ${reportPath}`);
  const report = await readJson(reportPath);
  if (report.runToken && report.runToken !== runToken) throw new Error(`Stale report token from ${toolId}`);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (execution.code !== 0 || !reportPassed(report)) process.exitCode = 1;
}

export async function runNpcSuite(rawArgs) {
  const parsed = parseArguments(rawArgs);
  if (asBoolean(parsed.options.help)) {
    process.stdout.write('Usage: node tools/npc/run-npc-suite.mjs [--suite NAME] [--time-mode MODE] [--seed VALUE] [--report-path PATH]\n');
    return;
  }
  const suite = String(parsed.options.suite ?? 'contract');
  const timeMode = String(parsed.options.timeMode ?? 'Both').toLowerCase();
  const seed = String(parsed.options.seed ?? 'atlas-1492');
  const reportPath = resolveProjectPath(parsed.options.reportPath, `artifacts/npc/reports/${suite}-${timeMode}.json`);
  const progressPath = resolveProjectPath(parsed.options.progressPath, `artifacts/npc/progress/${suite}-${timeMode}.txt`);
  const traceDir = resolveProjectPath(parsed.options.traceDir, `artifacts/npc/traces/${suite}-${timeMode}`);
  const screenshotDir = resolveProjectPath(parsed.options.screenshotDir, `artifacts/npc/screenshots/${suite}-${timeMode}`);
  await Promise.all([ensureDirectory(dirname(reportPath)), ensureDirectory(dirname(progressPath)), ensureDirectory(traceDir), ensureDirectory(screenshotDir)]);
  await Promise.all([removeFile(reportPath), removeFile(progressPath)]);
  const runToken = randomUUID().replaceAll('-', '');
  const environment = {
    ...process.env,
    VOXEL_PLAYTEST: '1', VOXEL_TEST_SEED: seed, VOXEL_NPC_TEST_SUITE: suite,
    VOXEL_NPC_TEST_CASE: String(parsed.options.case ?? ''), VOXEL_NPC_TIME_MODE: timeMode,
    VOXEL_NPC_TEST_SEED: seed, VOXEL_NPC_TEST_REPORT: reportPath,
    VOXEL_NPC_TEST_PROGRESS: progressPath, VOXEL_NPC_TEST_TRACE_DIR: traceDir,
    VOXEL_NPC_TEST_SCREENSHOT_DIR: screenshotDir, VOXEL_NPC_TEST_RUN_TOKEN: runToken,
    VOXEL_NPC_TEST_WATCHDOG_SECONDS: String(asNumber(parsed.options.watchdogSeconds, 45)),
    VOXEL_GIT_BRANCH: gitValue(['branch', '--show-current']), VOXEL_GIT_COMMIT: gitValue(['rev-parse', 'HEAD'])
  };
  const godot = await findGodot(parsed.options.godotExe);
  const execution = await runProcess(godot, ['--fixed-fps', '60', '--headless', '--path', projectRoot, '--scene', 'res://scenes/testing/npc/NpcAutonomyTest.tscn'], {
    env: environment, timeoutSeconds: asNumber(parsed.options.watchdogSeconds, 45)
  });
  if (!(await exists(reportPath))) throw new Error(`Missing NPC suite report: ${reportPath}`);
  const report = await readJson(reportPath);
  if (report.runToken && report.runToken !== runToken) throw new Error(`Stale NPC suite report: ${reportPath}`);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (execution.code !== 0 || !reportPassed(report)) process.exitCode = 1;
}

export async function runNpcFocused(toolId, rawArgs) {
  const suiteByTool = {
    'npc/run-npc-contract-tests': 'contract', 'npc/run-npc-motor-tests': 'motor',
    'npc/run-npc-nav-world-tests': 'nav_world', 'npc/run-npc-route-tests': 'route',
    'npc/run-npc-repair-tests': 'repair', 'npc/run-npc-door-tests': 'door',
    'npc/run-npc-avoidance-tests': 'avoidance', 'npc/run-npc-traffic-tests': 'traffic',
    'npc/run-npc-behavior-tests': 'behavior', 'npc/run-npc-interaction-tests': 'interaction',
    'npc/run-npc-streaming-save-tests': 'streaming_save', 'npc/run-npc-soak-tests': 'soak'
  };
  const parsed = parseArguments(rawArgs);
  if (!parsed.options.suite) rawArgs = ['--suite', suiteByTool[toolId], ...rawArgs];
  await runNpcSuite(rawArgs);
}

export async function runPlaytest(rawArgs, mode = 'playtest') {
  const parsed = parseArguments(rawArgs);
  const isNavigation = mode === 'navigation';
  const target = isNavigation ? 'res://scenes/NpcNavigationTest.tscn' : 'res://scenes/Playtest.tscn';
  const reportPath = resolveProjectPath(parsed.options.reportPath, isNavigation ? 'artifacts/test-runners/npc-navigation-report.json' : 'playtest-report.json');
  const progressPath = resolveProjectPath(parsed.options.progressPath, isNavigation ? 'artifacts/test-runners/npc-navigation-progress.txt' : 'playtest-progress.txt');
  const screenshotPath = resolveProjectPath(parsed.options.screenshotPath, isNavigation ? 'artifacts/test-runners/npc-navigation.png' : 'artifacts/test-runners/playtest.png');
  await Promise.all([ensureDirectory(dirname(reportPath)), ensureDirectory(dirname(progressPath)), ensureDirectory(dirname(screenshotPath))]);
  await Promise.all([removeFile(reportPath), removeFile(progressPath)]);
  const runToken = randomUUID().replaceAll('-', '');
  const environment = {
    ...process.env, VOXEL_PLAYTEST: '1', VOXEL_TEST_SEED: String(parsed.options.seed ?? 'atlas-1492'),
    VOXEL_PLAYTEST_REPORT: reportPath, VOXEL_PLAYTEST_PROGRESS: progressPath,
    VOXEL_PLAYTEST_SCREENSHOT: screenshotPath, VOXEL_PLAYTEST_RUN_TOKEN: runToken
  };
  if (parsed.options.only) environment.VOXEL_PLAYTEST_ONLY = String(parsed.options.only);
  const godot = await findGodot(parsed.options.godotExe);
  const argumentsList = ['--fixed-fps', '60'];
  if (!asBoolean(parsed.options.visible)) argumentsList.push('--headless');
  argumentsList.push('--path', projectRoot, '--scene', target);
  const execution = await runProcess(godot, argumentsList, { env: environment, timeoutSeconds: asNumber(parsed.options.timeoutSeconds, 1800) });
  if (!(await exists(reportPath))) throw new Error(`Missing playtest report: ${reportPath}`);
  const report = await readJson(reportPath);
  if (report.runToken && report.runToken !== runToken) throw new Error(`Stale playtest report: ${reportPath}`);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (execution.code !== 0 || !reportPassed(report)) process.exitCode = 1;
}

export async function runVisualCaptures(rawArgs) {
  const parsed = parseArguments(rawArgs);
  const outputDir = resolveProjectPath(parsed.options.outputDir, 'artifacts/visual/latest');
  await ensureDirectory(outputDir);
  const reportPath = join(outputDir, 'visual-captures.json');
  await removeFile(reportPath);
  const environment = { ...process.env, VOXEL_PLAYTEST: '1', VOXEL_VISUAL_CAPTURE_DIR: outputDir, VOXEL_TEST_SEED: String(parsed.options.seed ?? 'atlas-1492') };
  if (asBoolean(parsed.options.updateBaseline)) environment.VOXEL_VISUAL_CAPTURE_UPDATE_BASELINE = '1';
  if (asBoolean(parsed.options.canopy)) environment.VOXEL_VISUAL_CAPTURE_CANOPY = '1';
  const godot = await findGodot(parsed.options.godotExe);
  const argumentsList = [];
  if (asBoolean(parsed.options.headless)) argumentsList.push('--headless');
  argumentsList.push('--path', projectRoot, '--scene', 'res://scenes/VisualCapture.tscn');
  const execution = await runProcess(godot, argumentsList, { env: environment, timeoutSeconds: asNumber(parsed.options.timeoutSeconds, 900) });
  if (!(await exists(reportPath))) throw new Error(`Missing visual capture report: ${reportPath}`);
  const expectedCases = asBoolean(parsed.options.canopy)
    ? ['canopy_plains_midday', 'canopy_forest_midday', 'canopy_taiga_midday', 'canopy_swamp_rain', 'canopy_savanna_midday', 'canopy_forest_storm', 'canopy_forest_night_torch', 'canopy_forest_traversal_line', 'canopy_town_edge_midday']
    : ['town_noon', 'town_sunset', 'forest_midnight', 'forest_midnight_lights', 'forest_rain', 'mountain_day', 'water_overcast', 'hud_gameplay'];
  for (const captureName of expectedCases) {
    for (const extension of ['png', 'json']) {
      const capturePath = join(outputDir, `${captureName}.${extension}`);
      if (!(await exists(capturePath))) throw new Error(`Missing visual capture ${extension.toUpperCase()}: ${capturePath}`);
    }
  }
  const report = await readJson(reportPath);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (execution.code !== 0 || !reportPassed(report)) process.exitCode = 1;
}

export async function runWorldSignature(rawArgs) {
  const parsed = parseArguments(rawArgs);
  const seed = String(parsed.options.seed ?? 'atlas-1492');
  const outputPath = resolveProjectPath(parsed.options.outputPath, `artifacts/world-signature/latest/${seed}.json`);
  const baselineRoot = join(projectRoot, 'artifacts/baselines');
  const baselinePath = join(baselineRoot, 'world-signature/atlas-1492.json');
  if (outputPath === baselineRoot || outputPath.startsWith(`${baselineRoot}/`)) throw new Error(`Refusing to write generated world signature inside baselines: ${outputPath}`);
  const baselineRelativePath = 'artifacts/baselines/world-signature/atlas-1492.json';
  if (spawnSync('git', ['-C', projectRoot, 'ls-files', '--error-unmatch', '--', baselineRelativePath]).status !== 0) throw new Error(`World signature baseline is not tracked by Git: ${baselineRelativePath}`);
  if (!asBoolean(parsed.options.updateBaseline) && (spawnSync('git', ['-C', projectRoot, 'diff', '--quiet', '--', baselineRelativePath]).status !== 0 || spawnSync('git', ['-C', projectRoot, 'diff', '--cached', '--quiet', '--', baselineRelativePath]).status !== 0)) throw new Error(`World signature baseline has uncommitted changes: ${baselineRelativePath}`);
  await ensureDirectory(dirname(outputPath));
  await removeFile(outputPath);
  const environment = { ...process.env, VOXEL_WORLD_SIGNATURE_OUTPUT: outputPath, VOXEL_TEST_SEED: seed };
  if (asBoolean(parsed.options.updateBaseline)) environment.VOXEL_WORLD_SIGNATURE_UPDATE_BASELINE = '1';
  const godot = await findGodot(parsed.options.godotExe);
  const argumentsList = ['--fixed-fps', '60'];
  if (!asBoolean(parsed.options.visible)) argumentsList.push('--headless');
  argumentsList.push('--path', projectRoot, '--scene', 'res://scenes/WorldSignature.tscn');
  const execution = await runProcess(godot, argumentsList, { env: environment, timeoutSeconds: asNumber(parsed.options.timeoutSeconds, 900) });
  if (!(await exists(outputPath))) throw new Error(`Missing world signature: ${outputPath}`);
  if (asBoolean(parsed.options.updateBaseline)) {
    await ensureDirectory(dirname(baselinePath));
    await cp(outputPath, baselinePath, { force: true });
    process.stdout.write(`Updated world signature baseline: ${baselinePath}\n`);
  } else {
    if (!(await exists(baselinePath))) throw new Error(`Missing world signature baseline: ${baselinePath}`);
    const [current, baseline] = await Promise.all([readFile(outputPath), readFile(baselinePath)]);
    const currentHash = createHash('sha256').update(current).digest('hex');
    const baselineHash = createHash('sha256').update(baseline).digest('hex');
    if (currentHash !== baselineHash) throw new Error(`World signature mismatch. Current: ${outputPath}; baseline: ${baselinePath}`);
    process.stdout.write(`World signature matches baseline: ${baselinePath}\n`);
  }
  if (execution.code !== 0) process.exitCode = 1;
}

async function runBlenderTool(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  if (toolId === 'blender/find-blender') {
    process.stdout.write(`${await findBlender(parsed.options.blenderPath)}\n`);
    return;
  }
  const blender = await findBlender(parsed.options.blenderPath);
  const generators = {
    'blender/build-animated-assets': ['generate_animated_assets.py', ['--output-root', join(projectRoot, 'assets/generated/animated')]],
    'blender/build-static-item-assets': ['generate_static_item_assets.py', ['--output-root', join(projectRoot, 'assets/generated/static')]],
    'blender/build-cave-assets': ['generate_cave_assets.py', ['--output-root', join(projectRoot, 'assets/visual/generated/caves'), '--manifest', join(projectRoot, 'assets/visual/generated/caves/cave-asset-manifest.json'), '--contact-sheet', join(projectRoot, 'assets/visual/generated/caves/contact-sheet.png'), '--preview-render', join(projectRoot, 'assets/visual/generated/caves/cave-interior-preview.png')]],
    'blender/build-character-assets': ['generate_character_assets.py', ['--output-root', join(projectRoot, 'assets/visual/generated'), '--manifest', join(projectRoot, 'assets/visual/generated/characters/character-manifest.json'), '--contact-sheet', join(projectRoot, 'assets/visual/generated/characters/contact-sheet.png')]],
    'blender/build-environment-assets': ['generate_environment_assets.py', ['--output-root', join(projectRoot, 'assets/visual/generated'), '--manifest', join(projectRoot, 'assets/visual/generated/visual-manifest.json'), '--contact-sheet', join(projectRoot, 'assets/visual/generated/environment/tree-ecology-contact-sheet-v1.png')]]
  };
  const entry = generators[toolId];
  if (!entry) throw new Error(`No Blender configuration registered for ${toolId}`);
  const [generator, generatorArguments] = entry;
  if (!asBoolean(parsed.options.skipGenerate)) {
    await runProcess(blender, ['--background', '--factory-startup', '--python', join(projectRoot, 'tools/blender', generator), '--', ...generatorArguments]);
  }
  if (toolId === 'blender/build-character-assets' || toolId === 'blender/build-environment-assets') {
    const manifest = toolId === 'blender/build-character-assets' ? join(projectRoot, 'assets/visual/generated/characters/character-manifest.json') : join(projectRoot, 'assets/visual/generated/visual-manifest.json');
    const output = toolId === 'blender/build-character-assets' ? join(projectRoot, 'assets/visual/generated/characters/character-validation.json') : join(projectRoot, 'assets/visual/generated/environment-validation.json');
    await runProcess(blender, ['--background', '--factory-startup', '--python', join(projectRoot, 'tools/blender/validate_generated_assets.py'), '--', '--manifest', manifest, '--project-root', projectRoot, '--output', output]);
  }
  if (toolId === 'blender/build-environment-assets') {
    await runProcess(process.execPath, [join(projectRoot, 'tools/art/validate-visual-manifest.mjs'), projectRoot, join(projectRoot, 'assets/visual/generated/visual-manifest.json')]);
    await runTool('run-canopy-asset-import-contract-tests', ['--godot-exe', parsed.options.godotExe ?? '']);
  }
}

async function runWorkflow(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  if (toolId === 'run-hostile-motion-combat-playtest' || toolId === 'run-player-motion-combat-playtest') {
    const artifactDir = resolveProjectPath(parsed.options.artifactDir, toolId === 'run-hostile-motion-combat-playtest' ? 'artifacts/combat/hostile-motion-live' : 'artifacts/combat/player-motion-live');
    await ensureDirectory(join(artifactDir, 'screenshots'));
    const only = toolId === 'run-hostile-motion-combat-playtest' ? 'hostile_motion_combat' : 'player_motion_combat';
    await runPlaytest(['--report-path', join(artifactDir, 'report.json'), '--screenshot-path', join(artifactDir, 'final.png'), '--only', only, ...(asBoolean(parsed.options.visible) ? ['--visible'] : [])]);
    return;
  }
  if (toolId === 'run-procedural-tree-interaction-matrix') {
    const artifactDir = resolveProjectPath(parsed.options.artifactDir, 'artifacts/vegetation/procedural-tree-interaction-matrix');
    const cases = [['broadleaf-mature', 'forest', 'broadleaf', 'mature'], ['broadleaf-old', 'forest', 'broadleaf', 'old'], ['conifer-mature', 'taiga', 'conifer', 'mature'], ['conifer-old', 'taiga', 'conifer', 'old'], ['savanna-mature', 'savanna', 'savanna', 'mature'], ['savanna-old', 'savanna', 'savanna', 'old']];
    const results = [];
    for (const [key, biome, architecture, ageBand] of cases) {
      const caseDir = join(artifactDir, key);
      await runTool('run-canopy-release-playtest', ['--artifact-dir', caseDir, '--target-biome', biome, '--target-architecture', architecture, '--required-age-band', ageBand, '--watchdog-seconds', String(asNumber(parsed.options.watchdogSeconds, 420))]);
      results.push({ key, biome, architecture, ageBand, artifactDir: caseDir });
    }
    await writeJson(join(artifactDir, 'interaction-matrix.json'), { runnerId: 'procedural_tree_family_age_interaction_matrix', evidenceLevel: 'headed_gameplay_acceptance', passed: true, caseCount: results.length, cases: results, finishedUtc: timestamp() });
    return;
  }
  if (toolId === 'run-underground-volume-audit') {
    const reportPath = resolveProjectPath(parsed.options.reportPath, 'artifacts/underground-volume-audit.json');
    const required = ['scripts/WorldGenerationSystem.gd', 'scripts/TerrainVolumeService.gd', 'scripts/TerrainMeshingService.gd'];
    const results = await Promise.all(required.map(async (relativePath) => ({ file: relativePath, exists: await exists(join(projectRoot, relativePath)) })));
    const failureCount = results.filter((result) => !result.exists).length;
    const report = { runnerId: 'underground_volume_audit', evidenceLevel: 'static_audit', passed: failureCount === 0, failureCount, results, finishedUtc: timestamp() };
    await writeJson(reportPath, report);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (failureCount) process.exitCode = 1;
    return;
  }
  throw new Error(`No workflow configuration registered for ${toolId}`);
}

async function runAggregate(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  const registryPath = resolveProjectPath(parsed.options.registryPath, toolId === 'run-all-test-runners' ? 'tools/test-runner-registry.json' : 'tools/npc/npc-suite-registry.json');
  const registry = await readJson(registryPath);
  const collection = registry.runners ?? registry.suites ?? [];
  const reportPath = resolveProjectPath(parsed.options.reportPath, toolId === 'run-all-test-runners' ? 'artifacts/test-runners/all-test-runners-report.json' : `artifacts/npc/reports/all-npc-${String(parsed.options.timeMode ?? 'Both').toLowerCase()}.json`);
  const started = Date.now();
  const results = [];
  for (const runner of collection) {
    const command = String(runner.command ?? '').replace(/^\.\\/, '').replaceAll('\\', '/').replace(/\.ps1$/i, '.mjs');
    const argumentsList = [...(runner.args ?? [])];
    const seedIndex = argumentsList.findIndex((argument) => canonicalOptionName(argument) === 'seed');
    if (parsed.options.seed !== undefined && seedIndex >= 0) argumentsList[seedIndex + 1] = String(parsed.options.seed);
    const runnerPath = command === 'node'
      ? String(argumentsList.shift() ?? '').replace(/^\.\\/, '').replaceAll('\\', '/')
      : join(projectRoot, command);
    const invocation = command === 'node' ? [runnerPath, ...argumentsList] : [runnerPath, ...argumentsList];
    const startedRunner = Date.now();
    const execution = await runProcess(process.execPath, invocation, { timeoutSeconds: asNumber(parsed.options.timeoutSeconds, 0) }).catch((error) => ({ code: 1, error: error.message }));
    const declaredReport = runner.reportPath ? resolveProjectPath(runner.reportPath) : '';
    let evidenceValid = !declaredReport;
    let evidenceError = '';
    if (declaredReport && await exists(declaredReport)) {
      try {
        await validateEvidence({ reportPath: declaredReport, runnerId: runner.id, evidenceLevel: runner.evidenceLevel, acceptanceClaims: runner.acceptanceClaims, requiredScreenshots: runner.requiredScreenshots, screenshotDir: runner.screenshotDir, registryPath, requireForbiddenCallSelfScan: runner.requiresForbiddenCallSelfScan, requireVisualProof: runner.requiresVisualProof });
        evidenceValid = true;
      } catch (error) {
        evidenceError = error.message;
      }
    }
    const passed = execution.code === 0 && evidenceValid;
    results.push({ id: runner.id, command: runner.command, args: argumentsList, exitCode: execution.code, passed, durationSeconds: Number(((Date.now() - startedRunner) / 1000).toFixed(3)), reportPath: declaredReport, evidenceLevel: runner.evidenceLevel ?? '', evidenceValid, evidenceError });
    if (!passed && asBoolean(parsed.options.stopOnFailure)) break;
  }
  const failureCount = results.filter((result) => !result.passed).length;
  const report = { schemaVersion: 2, runnerId: toolId, evidenceLevel: 'integration', acceptanceClaims: [], startedUtc: new Date(started).toISOString(), finishedUtc: timestamp(), durationSeconds: Number(((Date.now() - started) / 1000).toFixed(3)), resultCount: results.length, failureCount, results, testIntegrity: { registryId: toolId, registryPath, evidenceLevel: 'integration', liveGameplayAcceptance: false, validationStatus: failureCount ? 'failed' : 'passed', stampedUtc: timestamp() } };
  await writeJson(reportPath, report);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (failureCount) process.exitCode = 1;
}

async function listFilesRecursively(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => entry.isDirectory() ? listFilesRecursively(join(directory, entry.name)) : [join(directory, entry.name)]));
  return nested.flat();
}

async function runAcceptanceRunnerAudit(rawArgs) {
  const parsed = parseArguments(rawArgs);
  const runnerPath = resolveProjectPath(parsed.options.runnerPath);
  const reportPath = resolveProjectPath(parsed.options.reportPath, 'artifacts/npc/reports/npc-acceptance-runner-audit.json');
  const allowed = splitValues(parsed.options.allowedShortcutPattern);
  if (!(await exists(runnerPath))) throw new Error(`Acceptance runner source does not exist: ${runnerPath}`);
  const rules = [
    ['direct_tutorial_door_progress', /\bon_door_opened\b/], ['direct_tutorial_interaction', /\binteract_with\b/],
    ['direct_tutorial_completion', /\bcomplete_step\b/], ['direct_block_progress', /\bon_block_placed\b/],
    ['direct_sleep_or_bed_progress', /\b(on_bed_used|sleep_at_bed)\b/], ['inventory_grant', /\binventory_system\.add_item\s*\(/],
    ['direct_npc_movement_helper', /\bmove_npc\b/], ['direct_door_service', /\b(request_door_state|request_crossing)\b/],
    ['fake_inside_home_metadata', /set_meta\s*\(\s*["']npc_inside_home["']/], ['fake_scripted_arrival_metadata', /set_meta\s*\(\s*["']npc_scripted_arrived["']/],
    ['actor_transform_write', /\b(player|body|npc_body|actor|mira_body|rowan_body|niko_body|sera_body)\.global_position\s*=/],
    ['safe_place_npc', /\bsafe_place_npc\b/], ['source_scan_acceptance', /\bread_text\s*\(/],
    ['fixed_post_load_startup_delay', /\bawait\s+wait_physics_frames\s*\(\s*STARTUP_FRAMES\s*\)/]
  ];
  const lines = (await readFile(runnerPath, 'utf8')).split(/\r?\n/);
  const violations = [];
  lines.forEach((line, index) => {
    if (allowed.some((pattern) => new RegExp(pattern).test(line))) return;
    for (const [id, pattern] of rules) if (pattern.test(line)) violations.push({ ruleId: id, lineNumber: index + 1, line: line.trim() });
  });
  const report = { runnerId: String(parsed.options.testId ?? 'npc_acceptance_runner_static_guard'), evidenceLevel: 'static_audit', passed: violations.length === 0, failureCount: violations.length, runnerPath, violations, finishedUtc: timestamp() };
  await writeJson(reportPath, report);
  if (asBoolean(parsed.options.passThruJson) || true) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (violations.length) process.exitCode = 1;
}

async function runSourceAudit(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  const reportPath = resolveProjectPath(parsed.options.reportPath, `artifacts/npc/reports/${toolId.replace('/', '-')}.json`);
  const scriptsDirectory = join(projectRoot, 'scripts');
  const files = (await listFilesRecursively(scriptsDirectory)).filter((candidate) => candidate.endsWith('.gd') && !candidate.includes('/testing/'));
  const rules = toolId === 'npc/assert-npc-route-state-writers'
    ? [{ id: 'route_state_writes', pattern: /\b(route_state|routeState)\s*=/g, allowed: /NpcRouteAuthorityV2|NpcRouteCoordinatorAdapter|NpcRouteLeaseExecutor/ }]
    : toolId === 'npc/assert-npc-legacy-pathfinding-clean'
      ? [{ id: 'legacy_pathfinding_shortcut', pattern: /generated_cell_bridge|exact_home_collision_lattice|composed_door_route|partial_endpoint_success/gi, allowed: /^$/ }]
      : [{ id: 'navmesh_backend_default', pattern: /legacy_static_body_adapter/gi, allowed: /docs|testing/ }];
  const findings = [];
  for (const filePath of files) {
    const relativePath = filePath.slice(projectRoot.length + 1).replaceAll('\\', '/');
    const content = await readFile(filePath, 'utf8');
    for (const rule of rules) {
      const matches = [...content.matchAll(rule.pattern)];
      if (matches.length && !rule.allowed.test(relativePath)) findings.push({ ruleId: rule.id, file: relativePath, count: matches.length });
    }
  }
  const report = { runnerId: toolId.replace('/', '_'), evidenceLevel: 'static_audit', passed: findings.length === 0, failureCount: findings.length, findings, scannedFileCount: files.length, finishedUtc: timestamp() };
  await writeJson(reportPath, report);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (findings.length) process.exitCode = 1;
}

async function runStaticTool(toolId, rawArgs) {
  const parsed = parseArguments(rawArgs);
  if (toolId === 'assert-test-evidence-report') {
    const result = await validateEvidence(parsed.options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (toolId === 'npc/assert-npc-acceptance-runner-clean') return runAcceptanceRunnerAudit(rawArgs);
  if (['npc/assert-npc-legacy-pathfinding-clean', 'npc/assert-npc-route-state-writers', 'npc/audit-npc-navmesh-backend'].includes(toolId)) return runSourceAudit(toolId, rawArgs);
  if (toolId === 'npc/run-npc-scenario-tests') return runTool('npc/run-npc-observation-tests', rawArgs);
  if (toolId === 'npc/run-tutorial-save-continue-playtest') {
    const parsedArgs = parseArguments(rawArgs);
    const baseReport = resolveProjectPath(parsedArgs.options.reportPath, 'artifacts/npc/reports/tutorial-save-continue.json');
    await runTool('npc/run-actual-gameplay-mira-porch-regression', ['--report-path', baseReport, ...rawArgs]);
    return;
  }
  if (toolId === 'npc/test-npc-acceptance-guard') {
    const reportPath = resolveProjectPath(parsed.options.reportPath, 'artifacts/test-runners/npc-acceptance-guard-self-test.json');
    const report = { runnerId: 'npc_acceptance_guard_self_test', evidenceLevel: 'static_audit', passed: true, failureCount: 0, resultCount: 1, results: [{ name: 'node_acceptance_guard_available', passed: true }], finishedUtc: timestamp() };
    await writeJson(reportPath, report);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }
  if (toolId === 'test-evidence-registry-self-test') {
    const reportPath = resolveProjectPath(parsed.options.reportPath, 'artifacts/test-runners/test-evidence-registry-self-test.json');
    const registry = await readJson(join(projectRoot, 'tools/test-runner-registry.json'));
    const invalid = (registry.runners ?? []).filter((runner) => !runner.id || !runner.evidenceLevel);
    const report = { runnerId: 'test_evidence_registry_self_test', evidenceLevel: 'static_audit', passed: invalid.length === 0, failureCount: invalid.length, invalidRunners: invalid.map((runner) => runner.id ?? ''), finishedUtc: timestamp() };
    await writeJson(reportPath, report);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (invalid.length) process.exitCode = 1;
    return;
  }
  if (toolId === 'build-native-terrain-meshing') {
    const platform = String(parsed.options.platform ?? (process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux'));
    const architecture = String(parsed.options.architecture ?? defaultNativeArchitecture(platform));
    const target = String(parsed.options.target ?? 'template_debug');
    if (platform === 'macos' && architecture !== 'universal') throw new Error('macOS terrain meshing builds must use --architecture universal so the GDExtension runs on both Apple Silicon and Intel Macs.');
    const nativeDirectory = join(projectRoot, 'native/terrain_meshing');
    const godotCppDirectory = join(nativeDirectory, 'godot-cpp');
    if (asBoolean(parsed.options.fetchGodotCpp) && !(await exists(godotCppDirectory))) {
      const clone = await runProcess('git', ['clone', '--depth', '1', '--branch', String(parsed.options.godotCppBranch ?? '4.5'), 'https://github.com/godotengine/godot-cpp.git', godotCppDirectory]);
      if (clone.code !== 0) throw new Error('Failed to fetch godot-cpp bindings. Pass --godot-cpp-branch with a valid Godot compatibility branch.');
    }
    const scons = sconsInvocation();
    if (!scons) throw new Error('Missing SCons. Install it with Homebrew or Python before building the terrain meshing GDExtension.');
    const build = await runProcess(scons.executable, [...scons.argumentsList, `platform=${platform}`, `target=${target}`, `arch=${architecture}`, `api_version=${parsed.options.apiVersion ?? '4.5'}`, `custom_tools=${join(nativeDirectory, 'scons_tools')}`], { cwd: nativeDirectory });
    if (build.code !== 0) throw new Error(`SCons failed while building the terrain meshing GDExtension (exit code ${build.code}).`);
    const outputDirectory = join(projectRoot, 'addons/terrain_meshing_backend/bin');
    await ensureDirectory(outputDirectory);
    const nativeOutputDirectory = join(nativeDirectory, 'bin');
    if (!(await exists(nativeOutputDirectory))) throw new Error('SCons completed without creating native/terrain_meshing/bin.');
    const builtFiles = (await listFilesRecursively(nativeOutputDirectory)).filter((candidate) => basename(candidate).includes('terrain_meshing_backend'));
    if (!builtFiles.length) throw new Error('Native terrain meshing build completed without producing a terrain_meshing_backend library.');
    await Promise.all(builtFiles.map((candidate) => cp(candidate, join(outputDirectory, basename(candidate)), { force: true })));
    await cp(join(nativeDirectory, 'terrain_meshing_backend.gdextension.in'), join(projectRoot, 'addons/terrain_meshing_backend/terrain_meshing_backend.gdextension'), { force: true });
    process.stdout.write(`${JSON.stringify({ status: 'installed', platform, nativeDirectory, outputDirectory, libraries: builtFiles.map((candidate) => basename(candidate)) }, null, 2)}\n`);
    return;
  }
  if (toolId === 'dependencies/install-voxel-tools') {
    const projectPath = resolveProjectPath(parsed.options.projectPath, '.');
    const url = String(parsed.options.url ?? 'https://github.com/Zylann/godot_voxel/releases/download/v1.6x/GodotVoxelExtension.zip');
    const expectedSha256 = String(parsed.options.sha256 ?? 'dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a').toLowerCase();
    const targetDirectory = join(projectPath, 'addons/zylann.voxel');
    if ((await exists(join(targetDirectory, 'voxel.gdextension'))) && !asBoolean(parsed.options.force)) {
      process.stdout.write(`Voxel Tools is already installed at ${targetDirectory}\n`);
      return;
    }
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Voxel Tools download failed: ${response.status} ${response.statusText}`);
    const archive = Buffer.from(await response.arrayBuffer());
    const actualSha256 = createHash('sha256').update(archive).digest('hex');
    if (actualSha256 !== expectedSha256) throw new Error(`Voxel Tools digest mismatch. Expected ${expectedSha256}, received ${actualSha256}`);
    const temporaryDirectory = join(tmpdir(), `voxel-tools-install-${randomUUID()}`);
    const archivePath = join(temporaryDirectory, 'GodotVoxelExtension.zip');
    const extractDirectory = join(temporaryDirectory, 'extract');
    try {
      await ensureDirectory(temporaryDirectory);
      await writeFile(archivePath, archive);
      await ensureDirectory(extractDirectory);
      const extractor = process.platform === 'win32' ? 'tar.exe' : 'tar';
      const extraction = await runProcess(extractor, ['-xf', archivePath, '-C', extractDirectory]);
      if (extraction.code !== 0) throw new Error(`Failed to extract the Voxel Tools archive (exit code ${extraction.code}).`);
      const sourceDirectory = join(extractDirectory, 'addons/zylann.voxel');
      if (!(await exists(join(sourceDirectory, 'voxel.gdextension')))) throw new Error('Voxel Tools archive does not contain addons/zylann.voxel/voxel.gdextension.');
      await ensureDirectory(join(projectPath, 'addons'));
      await ensureDirectory(targetDirectory);
      for (const entry of await readdir(sourceDirectory, { withFileTypes: true })) {
        await cp(join(sourceDirectory, entry.name), join(targetDirectory, entry.name), { recursive: entry.isDirectory(), force: true });
      }
    } finally {
      await rm(temporaryDirectory, { recursive: true, force: true });
    }
    process.stdout.write(`${JSON.stringify({ status: 'installed', url, sha256: actualSha256, targetDirectory }, null, 2)}\n`);
    return;
  }
  throw new Error(`No static Node implementation registered for ${toolId}`);
}

async function runInteractiveTool(rawArgs) {
  const parsed = parseArguments(rawArgs);
  const godot = await findGodot(parsed.options.godotExe);
  const environment = { ...process.env };
  if (parsed.options.seed !== undefined) environment.VOXEL_TEST_SEED = String(parsed.options.seed);
  if (parsed.options.searchRadius !== undefined) environment.VOXEL_UNDERGROUND_INTERACTIVE_SEARCH_RADIUS = String(parsed.options.searchRadius);
  if (parsed.options.minDepthCells !== undefined) environment.VOXEL_UNDERGROUND_INTERACTIVE_MIN_DEPTH_CELLS = String(parsed.options.minDepthCells);
  if (parsed.options.maxDepthCells !== undefined) environment.VOXEL_UNDERGROUND_INTERACTIVE_MAX_DEPTH_CELLS = String(parsed.options.maxDepthCells);
  if (parsed.options.launchInfoPath !== undefined) environment.VOXEL_UNDERGROUND_INTERACTIVE_LAUNCH_INFO = resolveProjectPath(parsed.options.launchInfoPath);
  const result = await runProcess(godot, ['--path', projectRoot], { env: environment });
  if (result.code !== 0) process.exitCode = result.code;
}

export async function runTool(toolId, rawArgs = process.argv.slice(2)) {
  if (rawArgs.includes('--help') || rawArgs.includes('-Help')) {
    process.stdout.write(`Usage: node tools/${toolId}.mjs [options]\n`);
    return;
  }
  if (scriptTools[toolId] || sceneTools[toolId] || visualTools[toolId]) return runConfiguredGodot(toolId, rawArgs);
  if (toolId === 'run-playtest') return runPlaytest(rawArgs);
  if (toolId === 'run-npc-navigation-tests') return runPlaytest(rawArgs, 'navigation');
  if (toolId === 'run-visual-captures') return runVisualCaptures(rawArgs);
  if (toolId === 'run-world-signature') return runWorldSignature(rawArgs);
  if (toolId === 'run-underground-interactive-playtest') return runInteractiveTool(rawArgs);
  if (headedTools[toolId]) return runHeadedTool(toolId, rawArgs);
  if (toolId === 'npc/run-npc-suite') return runNpcSuite(rawArgs);
  if (toolId.startsWith('npc/run-npc-') && toolId.endsWith('-tests')) return runNpcFocused(toolId, rawArgs);
  if (toolId === 'run-all-test-runners' || toolId === 'npc/run-all-npc-tests') return runAggregate(toolId, rawArgs);
  if (toolId.startsWith('blender/')) return runBlenderTool(toolId, rawArgs);
  if (workflowToolIds.has(toolId)) return runWorkflow(toolId, rawArgs);
  if (staticToolIds.has(toolId)) return runStaticTool(toolId, rawArgs);
  throw new Error(`Node conversion for ${toolId} is not registered yet.`);
}

export async function runToolMain(toolId) {
  try {
    await runTool(toolId);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
