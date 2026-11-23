import { readFileSync, existsSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const { SidecarApp, Response } = await import('sidecar_sdk').catch(() =>
  import(pathToFileURL(join(homedir(), '.gemini/antigravity/lib/node_modules/sidecar_sdk/index.mjs')).href)
);
import {resolveRuntime} from './runtime.mjs';
const dataRoot = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
if (!dataRoot) throw new Error('The Antigravity sidecar data directory is required.');
const script = join(here, 'vault.ps1');
const statusPath = join(dataRoot, 'switch-status.json');
let busy = false;
let activeChild;
let currentCache;
let currentAt = 0;

function readJson(path, fallback) {
  if (!existsSync(path)) return fallback;
  return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
}
function status() {
  const value = readJson(statusPath, null);
  if (value && ['queued','closing','restarting'].includes(value.state) && Date.now() - value.updatedAt > 90000) {
    return { state:'failed', message:'Switching was not confirmed. Check the account in app settings.', updatedAt:value.updatedAt };
  }
  return value && { state:value.state, message:value.message, updatedAt:value.updatedAt };
}
function pending() { return ['queued','closing','restarting'].includes(status()?.state); }
function assertIdle() {
  if (busy || pending()) throw new Error('Wait for the current operation to finish.');
}
function vaultArgs(runtime, action, extra = []) {
  return ['-NoProfile','-NonInteractive','-File',script,'-Action',action,'-DataRoot',dataRoot,'-AppExe',runtime.appExe,...extra];
}
async function vault(action, extra = []) {
  const runtime = resolveRuntime(dataRoot);
  return new Promise((resolve, reject) => {
    const childEnv = {...process.env};
    for (const key of Object.keys(childEnv)) if (/ANTIGRAVITY.*(?:TOKEN|CSRF)/i.test(key)) delete childEnv[key];
    const child = execFile(runtime.pwsh, vaultArgs(runtime, action, extra), {
      windowsHide:true, encoding:'utf8', timeout:20000, maxBuffer:65536, env:childEnv
    }, (error, stdout) => {
      activeChild = undefined;
      let result;
      try { result = JSON.parse(stdout.trim()); } catch { /* Never expose native stderr or credentials. */ }
      if (error || !result?.ok) reject(new Error(result?.error || 'The operation did not complete. Refresh the panel and try again.'));
      else resolve(result);
    });
    activeChild = child;
  });
}
async function readState(refresh = false) {
  let currentError;
  if (!busy && !pending() && (refresh || !currentCache || Date.now() - currentAt > 30000)) {
    busy = true;
    try { currentCache = (await vault('Current')).current; currentAt = Date.now(); }
    catch (error) { currentCache = null; currentError = error.message; }
    finally { busy = false; }
  }
  const index = readJson(join(dataRoot,'profiles.json'), {version:1,profiles:[]});
  if (index.version !== 1 || !Array.isArray(index.profiles)) throw new Error('Could not read saved profiles.');
  const profiles = index.profiles.map(p => ({
    id:p.id, email:p.email, name:p.name, label:p.label, updatedAt:p.updatedAt,
    active:!!currentCache && p.email === currentCache.email
  }));
  return {current:currentCache, currentError, profiles, status:status(), busy:busy || pending()};
}

const app = new SidecarApp();
const securityHeaders = {
  'Cache-Control':'no-store',
  'X-Content-Type-Options':'nosniff',
  'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'"
};
for (const [route,file,type] of [
  ['/','index.html','text/html; charset=utf-8'],
  ['/app.js','app.js','application/javascript; charset=utf-8'],
  ['/styles.css','styles.css','text/css; charset=utf-8']
]) app.page(route, () => new Response(readFileSync(join(here,file)), {contentType:type,headers:securityHeaders}));
app.api('/api/state', data => readState(data.refresh === true));
app.api('/api/status', () => ({status:status()}));
app.api('/api/save', async data => {
  assertIdle();
  if (data.label !== undefined && (typeof data.label !== 'string' || data.label.length > 80)) throw new Error('The label must contain at most 80 characters.');
  busy = true;
  try {
    const result = await vault('Save',['-Label',data.label || '']);
    currentCache = {email:result.profile.email,name:result.profile.name}; currentAt = Date.now();
  } finally { busy = false; }
  return readState();
});
app.api('/api/switch', async data => {
  assertIdle();
  if (typeof data.id !== 'string' || !/^[a-f0-9]{32}$/.test(data.id)) throw new Error('Invalid profile.');
  busy = true;
  try {
    const plan = await vault('Plan',['-ProfileId',data.id]);
    mkdirSync(dataRoot,{recursive:true});
    const temp = statusPath + '.' + randomUUID() + '.tmp';
    writeFileSync(temp,JSON.stringify({state:'queued',message:'Preparing to switch…',updatedAt:Date.now(),profileId:data.id}));
    renameSync(temp,statusPath);
    // Only the explicitly requested restart gets a one-shot detached worker.
    // It has bounded waits, no recurring task, and exits after relaunch or failure.
    const launched = await vault('Launch',[
      '-ProfileId',data.id,'-ExpectedProcessId',String(plan.pid),'-ExpectedStartTicks',plan.startTicks
    ]);
    return {queued:true,workerPid:launched.workerPid};
  } catch (error) {
    if (existsSync(statusPath) && status()?.state === 'queued') {
      const temp = statusPath + '.failure.tmp';
      writeFileSync(temp,JSON.stringify({state:'failed',message:'Could not start switching. The account was not changed.',updatedAt:Date.now()}));
      renameSync(temp,statusPath);
    }
    throw error;
  } finally { busy = false; }
});
let stopping = false;
for (const signal of ['SIGTERM','SIGINT']) process.on(signal,async () => {
  if (stopping) return;
  stopping = true;
  activeChild?.kill();
  await app.close();
  process.exit(0);
});
await app.run();
