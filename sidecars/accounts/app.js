const $ = id => document.getElementById(id);
const token = new URLSearchParams(location.search).get('token');
let pendingId;
let locked = false;
let pollTimer;

window.addEventListener('message',event => {
  if (event.source !== window.parent || event.data?.type !== 'theme-change') return;
  for (const [key,value] of Object.entries(event.data.payload?.cssVariables || {})) {
    if (key.startsWith('--') && typeof value === 'string') document.documentElement.style.setProperty(key,value);
  }
});
async function api(path,data = {}) {
  const response = await fetch('/api/'+path,{
    method:'POST',headers:{'Content-Type':'application/json','X-Sidecar-Token':token || ''},body:JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok || result.error) throw new Error(result.error || 'Could not connect to the panel.');
  return result;
}
function notice(text,error = false) {
  $('notice').textContent = text || '';
  $('notice').hidden = !text;
  $('notice').classList.toggle('error',error);
}
function setLocked(value) {
  locked = value;
  for (const el of document.querySelectorAll('#refresh,#save,.switch-button')) {
    el.disabled = value || el.dataset.active === 'true';
  }
}
function node(tag,className,text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function render(data) {
  $('currentEmail').textContent = data.current?.email || 'Sign-in unavailable';
  $('count').textContent = data.profiles.length ? String(data.profiles.length) : '';
  $('empty').hidden = data.profiles.length > 0;
  $('profiles').hidden = data.profiles.length === 0;
  $('profiles').replaceChildren();

  for (const profile of data.profiles) {
    const title = profile.label || profile.name || profile.email.split('@')[0];
    const row = node('li','profile-row' + (profile.active ? ' active' : ''));
    const avatar = node('span','avatar',Array.from(title)[0]?.toLocaleUpperCase('ru') || '?');
    avatar.setAttribute('aria-hidden','true');
    const identity = node('div','identity');
    identity.append(node('h3','',title),node('p','email',profile.email));
    if (profile.name && profile.name !== title && profile.name !== profile.email) {
      identity.append(node('p','email',profile.name));
    }
    row.append(avatar, identity);

    if (profile.active) {
      row.append(node('span','badge','Active'));
    } else {
      const button = node('button','secondary switch-button','Switch account');
      button.type = 'button';
      button.setAttribute('aria-label','Switch to ' + profile.email);
      button.addEventListener('click',() => {
        if (locked) return;
        pendingId = profile.id;
        $('targetEmail').textContent = profile.email;
        $('confirm').returnValue = '';
        $('confirm').showModal();
      });
      row.append(button);
    }
    $('profiles').append(row);
  }

  setLocked(!!data.busy);
  if (data.status?.state === 'failed') notice(data.status.message,true);
  else if (data.currentError) notice(data.currentError,true);
  else if (data.status) notice(data.status.message);
  else notice('');
  if (data.busy) startPolling();
}

async function load(refresh = false) {
  setLocked(true);
  try { render(await api('state',{refresh})); }
  catch (error) {notice(error.message,true);setLocked(false);}
}
$('refresh').addEventListener('click',() => load(true));
$('save').addEventListener('click',async () => {
  if (locked) return;
  setLocked(true);notice('Saving encrypted sign-in…');
  try {render(await api('save',{label:$('label').value.trim()}));$('label').value='';notice('Account saved. You can return to it from this panel.');}
  catch (error) {notice(error.message,true);}
  finally {setLocked(false);}
});
$('confirm').addEventListener('close',async () => {
  const id = pendingId;
  pendingId = undefined;
  if ($('confirm').returnValue !== 'switch' || !id || locked) return;
  setLocked(true);
  try {
    const result = await api('switch',{id});
    notice(result.message || 'Switching account. Antigravity will restart shortly…');
    if (result.same) setLocked(false); else startPolling();
  } catch (error) {notice(error.message,true);setLocked(false);}
});
function startPolling() {
  if (pollTimer) return;
  let attempts = 0;
  const poll = async () => {
    pollTimer = undefined;
    if (document.hidden) return;
    try {
      const result = await api('status');
      if (result.status) notice(result.status.message,result.status.state === 'failed');
      if (!result.status || ['done','failed'].includes(result.status.state)) {await load(true);return;}
    } catch { /* The app may be restarting. The new panel starts normally. */ }
    if (++attempts < 45) pollTimer = setTimeout(poll,2000);
    else {notice('Reopen the panel after restart and check the active account.');setLocked(false);}
  };
  pollTimer = setTimeout(poll,1200);
}
document.addEventListener('visibilitychange',() => {
  if (document.hidden) {clearTimeout(pollTimer);pollTimer=undefined;}
  else load();
});
load();

/* AG_PROFILE_SIDEBAR_ACCOUNT_INTENT */
if (new URLSearchParams(location.search).get('accountAction') === 'add') {
  $('addHelp').open = true;
  requestAnimationFrame(() => $('addHelp').scrollIntoView({block:'nearest'}));
}
