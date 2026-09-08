import { join, isAbsolute } from 'node:path';
import { randomUUID } from 'node:crypto';
import { mkdir, rm } from 'node:fs/promises';
import { parseArguments, asBoolean, projectRoot, resolveProjectPath, readJson, writeJson, runProcess, validateEvidence } from './voxel-tool-runtime.mjs';

const key = name => name.replace(/^-+/,'').replaceAll('-','').toLowerCase();
function setArg(args,name,value) {
  const index = args.findIndex(item=>key(item)===key(name));
  if(index<0) args.push(name,String(value));
  else if(index+1<args.length && !/^--?[A-Za-z]/.test(args[index+1])) args[index+1]=String(value);
  else args.splice(index+1,0,String(value));
}
export function aggregateInvocation(runner, options, npc, root = projectRoot) {
  const command = String(runner.command??'').replace(/^\.\\/,'').replaceAll('\\','/');
  const args = [...(npc ? runner.defaultArgs??[] : runner.args??[])];
  const timeMode = String(options.timeMode??'Both');
  let reportPath = runner.reportPath ? resolve(root,runner.reportPath) : '';
  let screenshotDir = runner.screenshotDir ? resolve(root,runner.screenshotDir) : '';
  if(npc) {
    reportPath=join(root,'artifacts/npc/reports',`${runner.id}-${timeMode.toLowerCase()}.json`);
    if(runner.supportsTimeMode!==false) setArg(args,'-TimeMode',timeMode);
    if(runner.supportsSeed!==false) setArg(args,'-Seed',options.seed??'atlas-1492');
    if(runner.supportsReportPath!==false) setArg(args,'-ReportPath',reportPath);
    if(runner.supportsScreenshotDir) {
      screenshotDir=join(root,'artifacts/npc/screenshots',`${runner.id}-${timeMode.toLowerCase()}`);
      setArg(args,'-ScreenshotDir',screenshotDir);
    }
    if(options.godotExe) setArg(args,'-GodotExe',options.godotExe);
  } else if(args.some(item=>key(item)==='seed')) setArg(args,'-Seed',options.seed??'atlas-1492');
  const script = command==='node' ? args.shift() : command;
  if(!script?.endsWith('.mjs')) throw new Error(`Registry must name a Node runner: ${runner.id}`);
  return {args,script:resolve(root,script),reportPath,screenshotDir};
}
function resolve(root,p) { const clean=String(p).replaceAll('\\','/');return isAbsolute(clean)?clean:join(root,clean); }
export async function runAggregate(toolId,argv) {
  const {options}=parseArguments(argv);
  const npc=toolId==='npc/run-all-npc-tests';
  const registryPath=resolveProjectPath(options.registryPath,npc?'tools/npc/npc-suite-registry.json':'tools/test-runner-registry.json');
  const registry=await readJson(registryPath);
  const collection=npc?registry.suites:registry.runners;
  if(!Array.isArray(collection)||!collection.length) throw new Error('Empty or invalid runner registry.');
  const reportPath=resolveProjectPath(options.reportPath,npc?`artifacts/npc/reports/all-npc-${String(options.timeMode??'Both').toLowerCase()}.json`:'artifacts/test-runners/all-test-runners-report.json');
  const env={...process.env,VOXEL_TEST_SEED:String(options.seed??'atlas-1492')};
  if(npc) {
    const userdata=join(projectRoot,'artifacts/npc/runtime_userdata',`all-npc-${randomUUID()}`);
    await mkdir(userdata,{recursive:true}); env.APPDATA=userdata;env.LOCALAPPDATA=userdata;
  }
  const started=Date.now(), results=[];
  for(const runner of collection) {
    const plan=aggregateInvocation(runner,options,npc);
    if(plan.reportPath) await rm(plan.reportPath,{force:true});
    const start=Date.now();
    const execution=await runProcess(process.execPath,[plan.script,...plan.args],{env,stdio:['ignore','ignore','inherit'],timeoutSeconds:Number(options.timeoutSeconds??0)}).catch(error=>({code:1,error:error.message}));
    let evidenceValid=!plan.reportPath, evidenceError='';
    if(plan.reportPath) {
      try {
        if(!runner.evidenceLevel) throw new Error('Missing registry evidenceLevel.');
        await validateEvidence({reportPath:plan.reportPath,runnerId:runner.id,evidenceLevel:runner.evidenceLevel,registryPath,acceptanceClaims:runner.acceptanceClaims,requiredScreenshots:runner.requiredScreenshots,screenshotDir:plan.screenshotDir,requireForbiddenCallSelfScan:runner.requiresForbiddenCallSelfScan,requireVisualProof:runner.requiresVisualProof});
        evidenceValid=true;
      } catch(error) {evidenceError=error.message;}
    }
    const passed=execution.code===0&&evidenceValid;
    results.push({id:runner.id,command:runner.command,args:plan.args,exitCode:execution.code,passed,durationSeconds:(Date.now()-start)/1000,reportPath:plan.reportPath,evidenceLevel:runner.evidenceLevel??'',acceptanceClaims:runner.acceptanceClaims??[],evidenceValid,evidenceExitCode:evidenceValid?0:1,evidenceError,screenshotDir:plan.screenshotDir});
    if(!passed&&asBoolean(options.stopOnFailure)) break;
  }
  const failureCount=results.filter(row=>!row.passed).length;
  const report={schemaVersion:2,runnerId:toolId,suite:npc?'all-npc':'all-test-runners',evidenceLevel:'integration',acceptanceClaims:[],timeMode:options.timeMode??'Both',seed:options.seed??'atlas-1492',startedUtc:new Date(started).toISOString(),finishedUtc:new Date().toISOString(),durationSeconds:(Date.now()-started)/1000,resultCount:results.length,failureCount,results,registryPath,testIntegrity:{registryId:npc?'npc_focused':'all-test-runners',registryPath,evidenceLevel:'integration',liveGameplayAcceptance:false,validationStatus:failureCount?'failed':'passed',stampedUtc:new Date().toISOString()}};
  await writeJson(reportPath,report);
  console.log(`Aggregate complete: ${results.length} runners, ${failureCount} failures; ${reportPath}`);
  if(failureCount) process.exitCode=1;
  return report;
}
