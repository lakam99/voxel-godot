import { mkdir, mkdtemp, stat, rm, readdir } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { parseArguments, asBoolean, projectRoot, resolveProjectPath, findGodot, readJson, writeJson, gitValue, runTool } from './voxel-tool-runtime.mjs';
import { runGodotProcess } from './godot-process.mjs';

export const scenarios = ['CrowdedDoorTraffic', 'MarketWorkday', 'NightShelter', 'TerrainEdit', 'PropRemoval', 'TutorialAutomation'];
export const gameplayFlags = ['VOXEL_PLAYTEST','VOXEL_TEST_SEED','VOXEL_REAL_TUTORIAL_GOD_MODE','VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY','VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY','VOXEL_REAL_TUTORIAL_DAY_ONE','VOXEL_REAL_TUTORIAL_FINAL_RESCUE','VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT'];
const bootSelectors = ['VOXEL_REAL_TUTORIAL_REAL_BOOT','VOXEL_TUTORIAL_SAVE_CONTINUE_REAL_BOOT','VOXEL_ACTUAL_GAMEPLAY_MIRA_REAL_BOOT','VOXEL_VOX43_KNOWN_SAVE_REAL_BOOT','VOXEL_VOX43_FRESH_WORLD_REAL_BOOT','VOXEL_VOX55_TERRAIN_SURVEY_REAL_BOOT'];
export function productionEnvironment(inherited = process.env) {
  const env = { ...inherited };
  for (const key of Object.keys(env)) if ([...gameplayFlags,...bootSelectors].includes(key.toUpperCase())) delete env[key];
  return env;
}
export function failedWorkflowReport(report, message, saveContinue) {
  return {...report,schemaVersion:report.schemaVersion??1,testId:report.testId??(saveContinue?'npc_tutorial_save_continue_playtest':'npc_real_tutorial_no_flags'),finished:true,passed:false,failureCount:Number(report.failureCount??0)+1,processStopReason:'wrapper_failed',wrapperFailure:message,results:[...(Array.isArray(report.results)?report.results:[]),{name:'production_tutorial_wrapper',passed:false,details:message}]};
}
function positive(value, fallback) {
  const number = Number(value ?? fallback);
  if (!Number.isFinite(number) || number <= 0) throw new Error('Timeout must be positive.');
  return number;
}
export async function runScenarios(argv) {
  const { options } = parseArguments(argv);
  const scenario = options.scenario ?? 'All';
  if (scenario !== 'All' && !scenarios.includes(scenario)) throw new Error('Invalid scenario.');
  const names = scenario === 'All' ? scenarios : [scenario];
  const timeMode = String(options.timeMode ?? 'Both');
  if (!['day','night','both','transition'].includes(timeMode.toLowerCase())) throw new Error('Invalid time mode.');
  const reportPath = resolveProjectPath(options.reportPath, `artifacts/npc/reports/scenario-${scenario}-${timeMode.toLowerCase()}.json`);
  const started = Date.now();
  const results = [];
  const priorExit = process.exitCode;
  for (const name of names) {
    const childReport = names.length === 1 ? reportPath : join(dirname(reportPath), `${name}-${timeMode.toLowerCase()}.json`);
    process.exitCode = 0;
    let error;
    try {
      await runTool('npc/run-npc-observation-tests', ['--scenario',name,'--time-mode',timeMode,'--seed',String(options.seed ?? 'atlas-1492'),'--report-path',childReport,'--watchdog-seconds',String(positive(options.watchdogSeconds,45)),...(asBoolean(options.visible) ? ['--visible'] : [])]);
    } catch (failure) { error = failure.message; process.exitCode = 1; }
    const exitCode = process.exitCode || 0;
    results.push({scenario:name,reportPath:childReport,exitCode,passed:exitCode===0,...(error?{error}:{})});
    if (exitCode) break;
  }
  const failed = results.some(row => !row.passed);
  process.exitCode = failed ? 1 : priorExit;
  if (names.length > 1) await writeJson(reportPath, {schemaVersion:1,suite:'npc_phase5_scenarios',scenario,timeMode,seed:options.seed??'atlas-1492',startedUtc:new Date(started).toISOString(),finishedUtc:new Date().toISOString(),durationSeconds:(Date.now()-started)/1000,resultCount:results.length,failureCount:results.filter(row=>!row.passed).length,results});
  return {reportPath,passed:!failed,results};
}

async function guard(runner, output, allow = '') {
  const path = join(output, 'acceptance-guard.json');
  const oldExit = process.exitCode;
  process.exitCode = 0;
  const report = await runTool('npc/assert-npc-acceptance-runner-clean',['--runner-path',join(projectRoot,'scripts/testing/npc',runner),'--report-path',path,...(allow ? ['--allowed-shortcut-pattern',allow] : [])]);
  const failed = process.exitCode;
  process.exitCode = oldExit;
  await writeJson(path,report);
  if (failed || report.status !== 'passed') throw new Error('Acceptance runner guard failed.');
  return report;
}
export async function runProductionTutorial(argv, saveContinue = false) {
  const { options } = parseArguments(argv);
  if (!asBoolean(options.visible)) throw new Error('Live tutorial acceptance requires --visible.');
  const timeout = positive(options.timeoutSeconds, saveContinue ? 360 : 720);
  const stale = positive(options.staleProgressSeconds, saveContinue ? 60 : 75);
  const root = join(projectRoot,'artifacts/npc/node-production-runs');
  await mkdir(root,{recursive:true});
  const output = await mkdtemp(join(root,saveContinue?'save-continue-':'no-flags-'));
  const reportPath = resolveProjectPath(options.reportPath,join(output,'report.json'));
  const proofPath = resolveProjectPath(options.noFlagsProofPath,join(dirname(reportPath),`${basename(reportPath,'.json')}-proof.json`));
  const savePath = resolveProjectPath(options.savePathOverride ?? options.SavePathOverride,join(output,'save.json'));
  // Never destroy a supplied save. A clean two-process fixture needs a fresh namespace.
  if (saveContinue && await stat(savePath).then(()=>true,error=>{if(error.code==='ENOENT')return false;throw error;})) throw new Error('SavePathOverride must be fresh.');
  if (saveContinue) {
    const stem = basename(savePath).replace(/\.[^.]*$/,'').toLowerCase();
    const files = await readdir(dirname(savePath)).catch(error=>{if(error.code==='ENOENT')return [];throw error;});
    if(files.some(name=>name.toLowerCase().startsWith(stem+'_slot_') || name.toLowerCase()===stem+'_active_seed.txt')) throw new Error('SavePathOverride slot namespace must be fresh.');
    await mkdir(dirname(savePath),{recursive:true});
  }
  const scan = await guard(saveContinue?'NpcTutorialSaveContinueRunner.gd':'NpcRealTutorialPlaythroughRunner.gd',output,saveContinue?'':'final_rescue_fixture_setup_allowance');
  const executable = await findGodot(options.godotExe);
  const stages = [];
  const stageReports = [];
  const shots = [];
  let failure;
  try {
    for (const stage of saveContinue ? ['save_post_ack','continue_observe'] : ['tutorial']) {
      const stageReport = saveContinue ? join(output,`${stage}-report.json`) : reportPath;
      const progress = saveContinue ? join(output,`${stage}-progress.txt`) : resolveProjectPath(options.progressPath,join(output,'progress.txt'));
      const captures = saveContinue ? join(output,`${stage}-screenshots`) : resolveProjectPath(options.screenshotDir,join(output,'screenshots'));
      await mkdir(captures,{recursive:true});
      const oldCaptures = await readdir(captures,{withFileTypes:true});
      await Promise.all(oldCaptures.filter(file=>file.isFile() && file.name.toLowerCase().endsWith('.png')).map(file=>rm(join(captures,file.name))));
      await Promise.all([stageReport,progress].map(path=>rm(path,{force:true})));
      const env = productionEnvironment();
      for (const key of Object.keys(env)) if (key.toUpperCase() === 'VOXEL_SAVE_PATH_OVERRIDE') delete env[key];
      const token = randomUUID().replaceAll('-','');
      const prefix = saveContinue ? 'VOXEL_ACTUAL_GAMEPLAY_MIRA' : 'VOXEL_REAL_TUTORIAL';
      Object.assign(env,{[`${prefix}_REPORT`]:stageReport,[`${prefix}_PROGRESS`]:progress,[`${prefix}_SCREENSHOT_DIR`]:captures,[`${prefix}_RUN_TOKEN`]:token,[`${prefix}_WATCHDOG_SECONDS`]:String(timeout),VOXEL_GIT_BRANCH:gitValue(['branch','--show-current']),VOXEL_GIT_COMMIT:gitValue(['rev-parse','HEAD'])});
      if (saveContinue) Object.assign(env,{VOXEL_SAVE_PATH_OVERRIDE:savePath,VOXEL_TUTORIAL_SAVE_CONTINUE_REAL_BOOT:'1',VOXEL_TUTORIAL_SAVE_CONTINUE_STAGE:stage});
      else Object.assign(env,{VOXEL_REAL_TUTORIAL_REAL_BOOT:'1',VOXEL_REAL_TUTORIAL_PHASE7_LIVE_ACCEPTANCE:'1',VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED:'1'});
      const args = ['--resolution','1280x720','--path',projectRoot];
      stages.push({stage,launchArguments:args,fixedFramePacingOverride:false,requiredUnsetBeforeLaunch:Object.fromEntries(gameplayFlags.map(key=>[key,{value:env[key]??null,unset:!env[key]}]))});
      const execution = await runGodotProcess(executable,args,{env,timeoutSeconds:timeout+90,reportPath:stageReport,expectedRunToken:token,progressPath:progress,staleProgressSeconds:stale,workTimeoutSeconds:timeout});
      const report = await readJson(stageReport);
      Object.assign(report,{forbiddenCallSelfScan:scan,processExitCode:execution.code,processStopReason:execution.code?'failed':'report_finished',wrapperNoFlagsProofPath:proofPath,wrapperNoGameplayAffectingFlags:true,wrapperRealBoot:true,fixedFramePacingOverride:false,scriptErrorScan:{status:execution.code?'failed':'passed'},ownedProcessEvidence:execution.summaryPath});
      await writeJson(stageReport,report);
      if (execution.code || report.finished !== true || report.passed !== true || report.runToken !== token) throw new Error(`${stage} did not pass with matching live evidence.`);
      stageReports.push({path:stageReport,report}); shots.push(captures);
    }
    if (!saveContinue) {
      const required = ['phase7_menu_before_new_game.png','phase7_loading_gameplay_prerequisites.png','player_pov_dialogue_acknowledged.png','mira_go_home_start.png','mira_route_departure.png','mira_at_home_door.png','mira_home_door_open.png','mira_inside_home_closed_door.png','player_pov_after_mira_home.png'];
      for (const file of required) if ((await stat(join(shots[0],file))).size === 0) throw new Error(`Empty screenshot: ${file}`);
      await runTool('assert-test-evidence-report',['--report-path',reportPath,'--runner-id','npc_real_tutorial_no_flags','--evidence-level','acceptance_visual','--registry-path',join(projectRoot,'tools/test-runner-registry.json'),'--acceptance-claims','tutorial_no_flags_main_menu_new_game_full_playthrough','--require-forbidden-call-self-scan','--require-visual-proof','--required-screenshots',required.join(';'),'--screenshot-dir',shots[0]]);
      if (process.exitCode) throw new Error('Visual evidence validation failed.');
    } else {
      await writeJson(reportPath,{schemaVersion:1,testId:'npc_tutorial_save_continue_playtest',finished:true,passed:true,failureCount:0,resultCount:2,evidenceLevel:'integration',scope:'Two headed production MainMenu processes: New Game, live knock acknowledgement, isolated SaveSystem persistence, Continue and live NPC observation.',actualGameplayDerived:true,fixedFramePacingOverride:false,wrapperNoFlagsProofPath:proofPath,wrapperNoGameplayAffectingFlags:true,wrapperRealBoot:true,forbiddenCallSelfScan:scan,gameplayFlags:{voxelPlaytest:false,voxelTestSeed:'',savePathOverride:savePath,savePathOverridePurpose:'isolated real SaveSystem fixture'},stageReports:{newGameSave:stageReports[0].path,continueObserve:stageReports[1].path},screenshotDirs:shots,results:[{name:'live_new_game_post_ack_save',passed:true,details:stageReports[0].report.postAckSave},{name:'live_continue_generic_home_restore',passed:true,details:{restoredOrder:stageReports[1].report.continuedRestoredOrder,porchClearanceDelay:stageReports[1].report.continuePorchClearanceDelayAfterObservation,strictHome:stageReports[1].report.miraReachedStrictHome}}]});
    }
  } catch (error) {
    failure = error;
    const prior = await readJson(reportPath).catch(()=>({evidenceLevel:'integration',forbiddenCallSelfScan:scan}));
    await writeJson(reportPath,failedWorkflowReport(prior,error.message,saveContinue));
  } finally {
    await writeJson(proofPath,{schemaVersion:1,projectPath:projectRoot,visible:true,realBoot:true,fixedFramePacingOverride:false,noGameplayAffectingFlags:true,staticAcceptanceRunnerScan:scan,saveIsolation:saveContinue?{path:savePath,purpose:'isolated real SaveSystem data only'}:null,stages,passed:!failure,processStopReason:failure?failure.message:'report_finished'});
  }
  if(failure) throw failure;
  return {passed:true,reportPath,proofPath};
}
