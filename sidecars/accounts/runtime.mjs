import {existsSync,readFileSync,readdirSync} from 'node:fs';
import {join,isAbsolute,basename} from 'node:path';
import {homedir} from 'node:os';

function optionalSettings(dataRoot){
  const path=join(dataRoot,'settings.json');
  if(!existsSync(path))return {};
  let value;
  try{value=JSON.parse(readFileSync(path,'utf8').replace(/^\uFEFF/,''));}catch{throw new Error('Invalid settings.json. Use the documented JSON format.');}
  if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Invalid settings.json. Use the documented JSON format.');
  return value;
}
function executable(value,name){return typeof value==='string'&&isAbsolute(value)&&basename(value).toLowerCase()===name.toLowerCase()&&existsSync(value);}
function toolHosts(){
  // Discover only the PowerShell global-tool subtree; do not scan user files.
  const store=join(homedir(),'.dotnet/tools/.store/powershell');
  if(!existsSync(store))return [];
  const versions=readdirSync(store,{withFileTypes:true}).filter(e=>e.isDirectory()).map(e=>e.name).sort((a,b)=>b.localeCompare(a,undefined,{numeric:true}));
  const hosts=[];
  for(const version of versions){
    const tools=join(store,version,'powershell',version,'tools');
    if(!existsSync(tools))continue;
    for(const framework of readdirSync(tools,{withFileTypes:true}).filter(e=>e.isDirectory()&&/^net\d/.test(e.name))){
      hosts.push(join(tools,framework.name,'any/win/pwsh.exe'));
    }
  }
  return hosts;
}
export function resolveRuntime(dataRoot){
  if(process.platform!=='win32')throw new Error('Account Switcher currently supports Windows only.');
  const settings=optionalSettings(dataRoot);
  const appCandidates=[
    process.env.LOCALAPPDATA&&join(process.env.LOCALAPPDATA,'Programs/Antigravity/Antigravity.exe'),
    process.env.ProgramFiles&&join(process.env.ProgramFiles,'Antigravity/Antigravity.exe')
  ].filter(Boolean);
  const shellCandidates=[
    process.env.ProgramFiles&&join(process.env.ProgramFiles,'PowerShell/7/pwsh.exe'),
    process.env.LOCALAPPDATA&&join(process.env.LOCALAPPDATA,'Programs/PowerShell/7/pwsh.exe'),
    ...toolHosts(),
    ...(process.env.PATH||'').split(';').filter(Boolean).map(p=>join(p,'pwsh.exe'))
  ].filter(Boolean);
  const appExe=settings.appExe||appCandidates.find(path=>executable(path,'Antigravity.exe'));
  const pwsh=settings.pwsh||shellCandidates.find(path=>executable(path,'pwsh.exe'));
  if(!executable(appExe,'Antigravity.exe'))throw new Error('Antigravity App was not found. Set appExe in the sidecar data settings.json.');
  if(!executable(pwsh,'pwsh.exe'))throw new Error('PowerShell 7 was not found. Install it or set pwsh in the sidecar data settings.json.');
  return {appExe,pwsh};
}
