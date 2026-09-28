import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { projectRoot, parseArguments, isToolRegistered } from '../lib/voxel-tool-runtime.mjs';
import { productionEnvironment, failedWorkflowReport, scenarios, runProductionTutorial } from '../lib/npc-workflows.mjs';

test('all retired runners have actual Node entry points, and tools contains no PowerShell executables', async () => {
  const manifest = JSON.parse(await readFile(join(projectRoot,'tools/node-runner-migration-manifest.json'),'utf8'));
  assert.equal(manifest.runners.length,152);
  for (const runner of manifest.runners) {
    assert.ok((await stat(join(projectRoot,runner.node))).isFile(), runner.node);
    const source = await readFile(join(projectRoot,runner.node),'utf8');
    const dispatch = source.match(/runToolMain\('([^']+)'\)/);
    if (dispatch) assert.ok(isToolRegistered(dispatch[1]),dispatch[1]);
  }
  async function check(dir) {
    for (const entry of await readdir(dir,{withFileTypes:true})) {
      if(entry.isDirectory()) await check(join(dir,entry.name));
      else assert.ok(!entry.name.endsWith('.ps1'),join(dir,entry.name));
    }
  }
  await check(join(projectRoot,'tools'));
});
test('all Node runner and library files parse without executing game fixtures', async () => {
  async function check(dir) {
    for(const entry of await readdir(dir,{withFileTypes:true})) {
      const path = join(dir,entry.name);
      if(entry.isDirectory()) await check(path);
      else if(entry.name.endsWith('.mjs')) {
        const result = spawnSync(process.execPath,['--check',path],{encoding:'utf8',windowsHide:true});
        assert.equal(result.status,0,`${path}: ${result.stderr}`);
      }
    }
  }
  await check(join(projectRoot,'tools'));
});
test('every migrated entry point offers help without launching a game',async()=>{
  const manifest=JSON.parse(await readFile(join(projectRoot,'tools/node-runner-migration-manifest.json'),'utf8'));
  for(const runner of manifest.runners){
    const result=spawnSync(process.execPath,[join(projectRoot,runner.node),'--help'],{encoding:'utf8',windowsHide:true,timeout:5000});
    assert.equal(result.status,0,`${runner.node}: ${result.stderr}`);
    assert.match(result.stdout,/usage/i,runner.node);
  }
});
test('production environment removes gameplay overrides case-insensitively without mutating parent', () => {
  const inherited = {VOXEL_PLAYTEST:'1',voxel_test_seed:'fake',VOXEL_REAL_TUTORIAL_GOD_MODE:'1',PATH:'keep'};
  assert.deepEqual(productionEnvironment(inherited),{PATH:'keep'});
  assert.equal(inherited.VOXEL_PLAYTEST,'1');
  assert.equal(scenarios.length,6);
});
test('live tutorial and save/Continue reject headless invocation before creating a game', async () => {
  await assert.rejects(runProductionTutorial([],false),/requires --visible/);
  await assert.rejects(runProductionTutorial([],true),/requires --visible/);
});
test('production workflow strips competing TitleMenu boot selectors',()=>{
  assert.deepEqual(productionEnvironment({VOXEL_REAL_TUTORIAL_REAL_BOOT:'1',voxel_tutorial_save_continue_real_boot:'1',VOXEL_VOX43_FRESH_WORLD_REAL_BOOT:'1',PATH:'keep'}),{PATH:'keep'});
});
test('wrapper failure overrides a passed primary report while retaining gameplay evidence',()=>{
  const passed={passed:true,failureCount:0,results:[{name:'game-step',passed:true}],runToken:'current'};
  const failed=failedWorkflowReport(passed,'missing capture',false);
  assert.equal(failed.passed,false);assert.equal(failed.failureCount,1);assert.equal(failed.results.length,2);assert.equal(failed.runToken,'current');assert.equal(passed.passed,true);
});
test('shared argument parser preserves existing option spelling and negative values', () => {
  assert.deepEqual(parseArguments(['-TimeMode','Both','--timeout-seconds','12','--seed','-42']).options,{timeMode:'Both',timeoutSeconds:'12',seed:'-42'});
});
