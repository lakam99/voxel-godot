import { readFile, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { projectRoot } from './lib/voxel-tool-runtime.mjs';

// Focused verdict over a completed N4 direct-source probe. This does not
// suppress or replace the broader differential's publication assertions.
const [probePath, broadReportPath] = process.argv.slice(2);
if (!probePath || !broadReportPath) {
  console.error('Usage: node tools/check-n4-surface-prop-decision-parity.mjs <probe.json> <broad-report.json>');
  process.exit(2);
}
const probe = JSON.parse(await readFile(probePath, 'utf8'));
const broad = JSON.parse(await readFile(broadReportPath, 'utf8'));
const failures = [];
let decisionParityCompared = 0;
let rngStatesCompared = 0;
let featuresCompared = 0;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const unsigned = value => BigInt.asUintN(64, BigInt(value)).toString();
const check = (condition, label) => { if (!condition) failures.push(label); };
const fields = (direct, native, names, label) => {
  for (const name of names) check(same(direct?.[name], native?.[name]), `${label} ${name}`);
};

check(probe.scope === 'direct_production_method_and_native_shadow_contract_not_live_gameplay', 'probe scope');
check(probe.seed === 'atlas-1492', 'pinned seed');
check(probe.cases?.length === 6, 'six source cases');
check(resolve(broad.probePath) === resolve(probePath), 'broad report/probe identity');
for (const [caseIndex, sample] of (probe.cases ?? []).entries()) {
  const label = `case ${caseIndex} chunk ${same(sample.chunk, [0, 0]) ? '0,0' : sample.chunk}`;
  check(sample.orderedStatus === 'ready' && sample.bundleReady, `${label} source admission`);
  check(sample.direct?.length === 28 && sample.native?.length === 28, `${label} 28 attempts`);
  for (let i = 0; i < Math.min(sample.direct?.length ?? 0, sample.native?.length ?? 0); i++) {
    const direct = sample.direct[i], native = sample.native[i], at = `${label} attempt ${i}`;
    check(direct.ordinal === i && native.ordinal === i, `${at} ordinal`);
    check(direct.durableId === native.durableId && same(direct.cell, native.cell), `${at} identity/coordinates`);
    check(direct.decisionOutcome === native.outcome, `${at} decision ${direct.decisionOutcome}/${native.outcome}`);
    decisionParityCompared++;
    check(unsigned(direct.stateBeforeCoordinates) === unsigned(native.stateBeforeCoordinates), `${at} RNG before coordinates`);
    check(unsigned(direct.stateAfterRecipe) === unsigned(native.stateAfterRecipe), `${at} RNG after recipe`);
    rngStatesCompared += 2;
    if (direct.sourceSampleApplicable) {
      check(direct.sourceBiome === native.sourceBiome, `${at} source biome`);
      check(Math.abs(direct.sourceHeightMeters - native.sourceHeightMeters) <= 1e-5, `${at} source height`);
    } else {
      check(native.sourceBiome === '' && native.sourceHeightMeters === 0, `${at} tombstone source`);
    }
    const feature = native.feature ?? {};
    if (native.outcome === 1 || native.outcome === 2) {
      check(Object.keys(feature).length === 0 && direct.childCountDelta === 0, `${at} absent feature`);
      continue;
    }
    if (native.outcome === 3) {
      check(feature.kind === 'rock' && !!direct.rock && !direct.rock.captureError, `${at} rock body`);
      fields(direct.rock, feature, ['durableId', 'visualBiome', 'rotationYBits',
        'colliderRadiusBits', 'colliderCenterYBits', 'assetId'], at);
      check(same(direct.rock?.visualScaleBits, feature.expectedRenderedScaleBits), `${at} rock scale`);
    } else if (native.outcome === 4 || native.outcome === 5) {
      check(feature.kind === 'treeDefinition' && feature.haloRequired === true, `${at} tree definition`);
      check(same(direct.treeRequest, feature.treeRequest), `${at} tree request`);
      const presence = sample.treePresenceDecisions?.find(row => row.ordinal === i);
      check(presence?.durableId === direct.durableId
        && presence?.presence === (direct.tree ? 1 : 2), `${at} tree presence`);
      if (direct.tree) {
        fields(direct.tree, feature, ['durableId', 'biome', 'family', 'growthClass',
          'rotationYBits', 'visualHeightBits', 'trunkRadiusBits', 'canopyRadiusBits',
          'collisionHeightBits', 'colliderRadiusBits', 'colliderHeightBits', 'colliderCenterYBits'], at);
      }
    } else if (native.outcome === 6 || native.outcome === 7) {
      check(feature.kind === 'oreCluster' && feature.children?.length === 2, `${at} ore definition`);
      const present = (feature.children ?? []).filter(child => child.present);
      check(direct.oreChildren?.length === present.length, `${at} ore child count`);
      for (const child of present) {
        const body = direct.oreChildren?.find(row => row.durableId === child.durableId);
        check(!!body && !body.captureError, `${at} ore child ${child.durableId}`);
        fields(body, child, ['dropCount', 'rotationYBits', 'localPositionBits',
          'meshRadiusBits', 'meshHeightBits', 'meshScaleBits', 'meshCenterYBits',
          'colliderRadiusBits', 'colliderCenterYBits', 'seamCount', 'glintCount',
          'seams', 'glints'], at);
      }
    } else if (native.outcome === 8) {
      check(feature.kind === 'forage' && !!direct.forage, `${at} forage body`);
      fields(direct.forage, feature, ['materialId', 'dropId', 'dropCount', 'rotationYBits'], at);
      check(direct.forage?.collider?.radiusBits === feature.colliderRadiusBits
        && direct.forage?.collider?.centerYBits === feature.colliderCenterYBits, `${at} forage collider`);
      check(direct.forage?.meshes?.length === feature.meshes?.length, `${at} forage mesh count`);
      for (let j = 0; j < Math.min(direct.forage?.meshes?.length ?? 0, feature.meshes?.length ?? 0); j++) {
        const actual = direct.forage.meshes[j], expected = feature.meshes[j];
        fields(actual, expected, ['kind', 'materialId', 'radialSegments', 'positionBits',
          'rotationBits', 'scaleBits'], `${at} forage mesh ${j}`);
        for (const name of ['radiusBits', 'heightBits', 'topRadiusBits', 'bottomRadiusBits', 'rings'])
          if (name in actual) check(actual[name] === expected[name], `${at} forage mesh ${j} ${name}`);
      }
    } else if (native.outcome === 9) {
      check(feature.kind === 'wildlife' && !!direct.wildlife && !direct.wildlife.captureError, `${at} wildlife body`);
      check(direct.wildlife?.variant === { 1: 'boar', 2: 'deer', 3: 'hare' }[feature.variant], `${at} wildlife variant`);
      fields(direct.wildlife, feature, ['primaryDropId', 'primaryDropCount',
        'extraDropId', 'extraDropCount', 'bodyYawBits', 'colliderSizeBits',
        'colliderCenterBits', 'collisionLayer', 'collisionMask', 'presentationPath',
        'visualScaleBits', 'visualRotationBits', 'animationSpeedBits',
        'movementHomeBits', 'movementDirectionBits', 'movementTimerBits',
        'movementSpeedBits', 'movementLastMoveBits'], at);
    } else {
      failures.push(`${at} unknown outcome ${native.outcome}`);
    }
    featuresCompared++;
  }
  check(unsigned(sample.directFinalRngState) === unsigned(sample.nativeFinalRngState), `${label} final RNG state`);
  rngStatesCompared++;
}
check(decisionParityCompared === 168, '168 decisions compared');
check(featuresCompared > 0, 'feature comparison coverage');
const report = {
  schema: 'n4-surface-prop-decision-parity/v1',
  status: failures.length ? 'failed' : 'passed',
  evidenceLevel: 'direct production-method/native shadow contract; not headed gameplay',
  seed: probe.seed, decisionParityCompared, rngStatesCompared, featuresCompared,
  failures: failures.slice(0, 80), probePath,
  broadDifferentialStatus: broad.status,
  broadDifferentialFailures: broad.failures,
  broadReportPath,
};
const reportPath = join(projectRoot, 'artifacts', 'native-world-backend',
  'n4-direct-source-order-differential', `decision-parity-${basename(probePath)}`);
await writeFile(reportPath, JSON.stringify(report, null, 2));
console.log(`${report.status}: ${reportPath}`);
if (failures.length) { console.error(failures.slice(0, 10).join('\n')); process.exitCode = 1; }
