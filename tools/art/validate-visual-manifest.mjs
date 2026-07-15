import fs from "node:fs";
import path from "node:path";

const projectRoot = path.resolve(process.argv[2] ?? ".");
const manifestPath = path.resolve(
  process.argv[3] ?? path.join(projectRoot, "assets", "visual", "generated", "visual-manifest.json"),
);

const REQUIRED_FAMILIES = {
  broadleaf_tree: 6,
  conifer_tree: 4,
  savanna_tree: 3,
  mature_broadleaf_tree: 4,
  old_growth_broadleaf_tree: 2,
  mature_conifer_tree: 4,
  mature_savanna_tree: 3,
  rock: 6,
  bush: 4,
  stump_log: 3,
};

const TREE_FAMILIES = new Set([
  "broadleaf_tree",
  "conifer_tree",
  "savanna_tree",
  "mature_broadleaf_tree",
  "old_growth_broadleaf_tree",
  "mature_conifer_tree",
  "mature_savanna_tree",
]);

const HEIGHT_BANDS = {
  mature_broadleaf_tree: [10, 16],
  old_growth_broadleaf_tree: [16, 22],
  mature_conifer_tree: [11, 18],
  mature_savanna_tree: [8, 13],
};

const ALLOWED_MATERIALS = new Set([
  "trunk",
  "bark_dark",
  "cut_wood",
  "leaf_primary",
  "leaf_secondary",
  "leaf_warm",
  "needle_primary",
  "needle_secondary",
  "savanna_leaf",
  "rock_primary",
  "rock_accent",
  "moss",
]);

function fail(errors, message) {
  errors.push(message);
}

function isNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function readManifest(errors) {
  if (!fs.existsSync(manifestPath)) {
    fail(errors, `Missing manifest: ${manifestPath}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    fail(errors, `Invalid JSON: ${error.message}`);
    return null;
  }
}

function validateBoundingBox(errors, asset) {
  const box = asset.boundingBox;
  if (!box || !Array.isArray(box.min) || !Array.isArray(box.max) || !Array.isArray(box.size)) {
    fail(errors, `${asset.id}: missing boundingBox min/max/size`);
    return;
  }
  for (const key of ["min", "max", "size"]) {
    if (box[key].length !== 3 || !box[key].every(isNumber)) {
      fail(errors, `${asset.id}: boundingBox.${key} must be three finite numbers`);
    }
  }
  if (box.size?.some((value) => value <= 0)) {
    fail(errors, `${asset.id}: non-positive bounding size ${JSON.stringify(box.size)}`);
  }
  const canopyFamily = asset.family in HEIGHT_BANDS;
  const maxHeight = canopyFamily ? 22.5 : 7.5;
  const maxWidth = canopyFamily ? 16.0 : 4.5;
  if (box.size?.[2] > maxHeight || box.size?.[0] > maxWidth || box.size?.[1] > maxWidth) {
    fail(errors, `${asset.id}: bounding box unexpectedly large ${JSON.stringify(box.size)}`);
  }
}

function validateTreeContract(errors, asset) {
  if (!TREE_FAMILIES.has(asset.family)) return;
  const roles = asset.materialRoles;
  if (!roles || !Array.isArray(roles.trunkBranch) || roles.trunkBranch.length === 0 || !Array.isArray(roles.foliage) || roles.foliage.length === 0) {
    fail(errors, `${asset.id}: missing trunk/branch/foliage material roles`);
  }
  const metrics = asset.treeMetrics;
  for (const key of ["height", "trunkRadius", "canopyRadius", "canopyBase", "canopyTop"]) {
    if (!isNumber(metrics?.[key])) fail(errors, `${asset.id}: missing numeric treeMetrics.${key}`);
  }
  const band = HEIGHT_BANDS[asset.family];
  if (band && (metrics.height < band[0] || metrics.height > band[1])) {
    fail(errors, `${asset.id}: height ${metrics.height} outside ${band[0]}-${band[1]} m band`);
  }
  if (band && metrics.trunkRadius < 0.32) fail(errors, `${asset.id}: mature trunk radius ${metrics.trunkRadius} is too thin`);
  if (asset.family === "mature_broadleaf_tree" && metrics.canopyBase < 3.0) fail(errors, `${asset.id}: crown base ${metrics.canopyBase} is not walk-under`);
  const wind = asset.windData;
  if (wind?.attribute !== "COLOR_0" || wind?.sourceAttribute !== "wind" || wind?.domain !== "POINT") {
    fail(errors, `${asset.id}: missing COLOR_0 POINT wind encoding`);
  }
  if (!Number.isInteger(wind?.vertexCount) || wind.vertexCount <= 0 || !Number.isInteger(wind?.foliageVertexCount) || wind.foliageVertexCount <= 0) {
    fail(errors, `${asset.id}: invalid wind vertex counts`);
  }
  if (!isNumber(wind?.rootMaxBend) || wind.rootMaxBend > 0.03) fail(errors, `${asset.id}: root bend ${wind?.rootMaxBend} is not immobile`);
  if (!isNumber(wind?.crownMaxBend) || wind.crownMaxBend < 0.45) fail(errors, `${asset.id}: crown bend ${wind?.crownMaxBend} has no useful response`);
  if ((wind?.channels?.phaseG?.max ?? 0) - (wind?.channels?.phaseG?.min ?? 0) < 0.20) fail(errors, `${asset.id}: wind phase range is too narrow`);
  if ((wind?.channels?.flutterB?.max ?? 0) < 0.50) fail(errors, `${asset.id}: foliage flutter range is too weak`);
  const animation = asset.animationContract;
  if (animation?.skeletons !== 0 || animation?.shapeKeys !== 0 || animation?.animationClips !== 0) {
    fail(errors, `${asset.id}: animation contract must remain data-only`);
  }
}

function validatePivot(errors, asset) {
  const pivot = asset.pivotCheck;
  if (!pivot || !Array.isArray(pivot.origin) || pivot.origin.length !== 3) {
    fail(errors, `${asset.id}: missing pivotCheck.origin`);
    return;
  }
  if (!pivot.origin.every(isNumber)) {
    fail(errors, `${asset.id}: pivot origin must be numeric`);
  }
  if (!pivot.grounded || Math.abs(Number(pivot.minZ)) > 0.055) {
    fail(errors, `${asset.id}: pivot is not grounded`);
  }
  if (!pivot.originXYCentered) {
    fail(errors, `${asset.id}: pivot XY is not centered`);
  }
}

function validateAsset(errors, asset, seenIds, familyCounts, triangleLimit) {
  if (!asset || typeof asset !== "object") {
    fail(errors, "Asset row is not an object");
    return;
  }
  if (typeof asset.id !== "string" || asset.id.length === 0) {
    fail(errors, "Asset missing string id");
    return;
  }
  if (seenIds.has(asset.id)) {
    fail(errors, `Duplicate asset id: ${asset.id}`);
  }
  seenIds.add(asset.id);

  if (typeof asset.path !== "string" || !asset.path.startsWith("assets/visual/generated/environment/") || !asset.path.endsWith(".glb")) {
    fail(errors, `${asset.id}: invalid GLB path ${asset.path}`);
  } else {
    const glbPath = path.join(projectRoot, asset.path);
    if (!fs.existsSync(glbPath)) {
      fail(errors, `${asset.id}: missing GLB ${glbPath}`);
    } else if (fs.statSync(glbPath).size <= 1024) {
      fail(errors, `${asset.id}: GLB is too small`);
    }
  }

  if (typeof asset.family !== "string" || !(asset.family in REQUIRED_FAMILIES)) {
    fail(errors, `${asset.id}: invalid family ${asset.family}`);
  } else {
    familyCounts[asset.family] = (familyCounts[asset.family] ?? 0) + 1;
  }

  if (!Array.isArray(asset.biomeTags) || asset.biomeTags.length === 0 || !asset.biomeTags.every((tag) => typeof tag === "string")) {
    fail(errors, `${asset.id}: invalid biomeTags`);
  }

  if (!Number.isInteger(asset.triangleCount) || asset.triangleCount <= 0 || asset.triangleCount > triangleLimit) {
    fail(errors, `${asset.id}: invalid triangleCount ${asset.triangleCount}`);
  }

  if (!Array.isArray(asset.materialSlots) || asset.materialSlots.length === 0) {
    fail(errors, `${asset.id}: missing materialSlots`);
  } else {
    for (const material of asset.materialSlots) {
      if (!ALLOWED_MATERIALS.has(material)) {
        fail(errors, `${asset.id}: unexpected material ${material}`);
      }
    }
  }

  if (typeof asset.runtimeEnabled !== "boolean") {
    fail(errors, `${asset.id}: runtimeEnabled must be explicit`);
  }

  validateBoundingBox(errors, asset);
  validatePivot(errors, asset);
  validateTreeContract(errors, asset);
}

const errors = [];
const manifest = readManifest(errors);

if (manifest) {
  if (manifest.schemaVersion !== 2) {
    fail(errors, `Expected schemaVersion 2, got ${manifest.schemaVersion}`);
  }
  if (typeof manifest.generator !== "string" || manifest.generator.length === 0) {
    fail(errors, "Missing generator name");
  }
  if (!Number.isInteger(manifest.seed)) {
    fail(errors, "Missing integer seed");
  }
  const triangleLimit = Number.isInteger(manifest.triangleLimit) ? manifest.triangleLimit : 2200;
  if (!Array.isArray(manifest.materialVocabulary)) {
    fail(errors, "Missing materialVocabulary array");
  } else {
    for (const material of manifest.materialVocabulary) {
      if (!ALLOWED_MATERIALS.has(material)) {
        fail(errors, `Unexpected manifest material vocabulary entry ${material}`);
      }
    }
  }
  if (manifest.windEncoding?.attribute !== "COLOR_0") {
    fail(errors, "Missing COLOR_0 windEncoding contract");
  }

  const contactSheet = path.join(projectRoot, manifest.contactSheet ?? "");
  if (!manifest.contactSheet || !fs.existsSync(contactSheet)) {
    fail(errors, `Missing contact sheet ${manifest.contactSheet}`);
  }

  if (!Array.isArray(manifest.assets)) {
    fail(errors, "Missing assets array");
  } else {
    const seenIds = new Set();
    const familyCounts = {};
    for (const asset of manifest.assets) {
      validateAsset(errors, asset, seenIds, familyCounts, triangleLimit);
    }
    const expectedTotal = Object.values(REQUIRED_FAMILIES).reduce((sum, value) => sum + value, 0);
    if (manifest.assets.length !== expectedTotal) {
      fail(errors, `Expected ${expectedTotal} assets, got ${manifest.assets.length}`);
    }
    for (const [family, expected] of Object.entries(REQUIRED_FAMILIES)) {
      if ((familyCounts[family] ?? 0) !== expected) {
        fail(errors, `Family ${family} expected ${expected}, got ${familyCounts[family] ?? 0}`);
      }
      if (manifest.families?.[family] !== expected) {
        fail(errors, `Manifest family summary ${family} expected ${expected}, got ${manifest.families?.[family]}`);
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) {
    console.error(`[FAIL] ${error}`);
  }
  process.exit(1);
}

console.log(`Visual manifest valid: ${manifest.assets.length} assets in ${path.relative(projectRoot, manifestPath)}`);
