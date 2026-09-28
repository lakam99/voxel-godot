import test from 'node:test';
import assert from 'node:assert/strict';
import { aggregateInvocation } from '../lib/aggregate-runner.mjs';
import { parseArguments, runTool } from '../lib/voxel-tool-runtime.mjs';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

test('PascalCase options used by real runner registries resolve to handler properties',()=>{
  assert.deepEqual(parseArguments(['-LaunchInfoPath','p','-GodMode','-RequiredAgeBand','old','-TargetArchitecture','oak']).options,{launchInfoPath:'p',godMode:true,requiredAgeBand:'old',targetArchitecture:'oak'});
});
test('NPC aggregate forwards defaults, overrides and derived evidence paths',()=>{
  const plan=aggregateInvocation({id:'route',command:'tools/npc/run-npc-route-tests.mjs',defaultArgs:['-TimeMode','Both','-Seed','-42','-Visible'],supportsScreenshotDir:true},{timeMode:'Night',seed:'fresh',godotExe:'godot.exe'},true);
  const parsed=parseArguments(plan.args).options;
  assert.equal(parsed.timeMode,'Night'); assert.equal(parsed.seed,'fresh');assert.equal(parsed.godotExe,'godot.exe'); assert.equal(parsed.visible,true);
  assert.match(plan.reportPath,/route-night\.json$/);assert.equal(parsed.reportPath,plan.reportPath);assert.equal(parsed.screenshotDir,plan.screenshotDir);
  assert.equal(plan.args.includes('-42'),false);
});
test('NPC aggregate honors unsupported options and preserves declared defaults',()=>{
  const plan=aggregateInvocation({id:'special',command:'tools/run-special.mjs',defaultArgs:['-Visible'],supportsTimeMode:false,supportsSeed:false,supportsReportPath:false},{},true);
  assert.deepEqual(plan.args,['-Visible']);assert.match(plan.reportPath,/special-both\.json$/);
});
test('general aggregate preserves node commands, registry paths and seed substitution',()=>{
  const plan=aggregateInvocation({id:'test',command:'node',args:['tools/test.mjs','-Seed','original'],reportPath:'artifacts/report.json'},{seed:'new'},false);
  assert.match(plan.script,/tools[\\/]test.mjs$/);assert.deepEqual(plan.args,['-Seed','new']);assert.match(plan.reportPath,/artifacts[\\/]report.json$/);
});
test('actual aggregate dispatch executes a harmless Node suite and rejects stale report reuse',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'aggregate-node-'));
  const script=join(dir,'fixture.mjs'),registry=join(dir,'registry.json'),output=join(dir,'aggregate.json');
  const id='migration-fixture-'+randomUUID();
  await writeFile(script,"import{mkdirSync,writeFileSync}from'node:fs';import{dirname}from'node:path';const a=process.argv.slice(2);const p=a[a.indexOf('-ReportPath')+1];mkdirSync(dirname(p),{recursive:true});writeFileSync(p,JSON.stringify({finished:true,passed:true,evidenceLevel:'contract',seenArgs:a}));");
  await writeFile(registry,JSON.stringify({suites:[{id,command:script,defaultArgs:['-Visible'],evidenceLevel:'contract'}]}));
  const previous=process.exitCode;
  let report;
  try{
    report=await runTool('npc/run-all-npc-tests',['--registry-path',registry,'--report-path',output,'-TimeMode','Night','-Seed','explicit']);
    assert.equal(report.failureCount,0);
    const child=JSON.parse(await readFile(report.results[0].reportPath,'utf8'));
    assert.equal(child.testIntegrity.validationStatus,'passed');assert.equal(child.seenArgs.includes('Night'),true);assert.equal(child.seenArgs.includes('explicit'),true);
    await writeFile(script,'process.exit(0)');
    const failed=await runTool('npc/run-all-npc-tests',['--registry-path',registry,'--report-path',output,'-TimeMode','Night']);
    assert.equal(failed.failureCount,1);assert.equal(failed.results[0].evidenceValid,false);
  }finally{process.exitCode=previous;if(report)await rm(report.results[0].reportPath,{force:true});await rm(dir,{recursive:true,force:true});}
});
