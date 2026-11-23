const $ = id => document.getElementById(id);
const token = new URLSearchParams(location.search).get('token');
let snapshot;
let selectedId;
let pendingId;
let locked = false;
let pollTimer;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

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
  snapshot = data;
  $('currentEmail').textContent = data.current?.email || 'Sign-in unavailable';
  $('count').textContent = data.profiles.length ? String(data.profiles.length) : '';
  $('empty').hidden = data.profiles.length > 0;
  $('cards').hidden = data.profiles.length === 0;
  $('pagination').hidden = data.profiles.length < 2;
  $('cards').replaceChildren();
  for (const profile of data.profiles) {
    const card = node('article','card'+(profile.active ? ' active' : ''));
    card.dataset.id = profile.id;
    const top = node('div','card-top');
    top.append(node('div','avatar',(profile.label || profile.name || profile.email).slice(0,1).toUpperCase()));
    if (profile.active) top.append(node('span','badge','Active'));
    card.append(top,node('h3','',profile.label || profile.name || profile.email.split('@')[0]),node('p','email',profile.email));
    const button = node('button','primary switch-button',profile.active ? 'In use' : 'Switch account');
    button.dataset.active = String(profile.active);
    button.disabled = profile.active || !!data.busy;
    button.addEventListener('click',() => {
      if (locked) return;
      pendingId = profile.id;
      $('targetEmail').textContent = profile.email;
      $('confirm').showModal();
    });
    card.append(button);
    $('cards').append(card);
  }
  const index = Math.max(0,data.profiles.findIndex(p => p.id === selectedId));
  selectIndex(index,false);
  setLocked(!!data.busy);
  if (data.currentError) notice(data.currentError,true);
  else if (data.status) notice(data.status.message,data.status.state === 'failed');
  else notice('');
  if (data.busy) startPolling();
}
function selectIndex(index,smooth = true) {
  if (!snapshot?.profiles.length) return;
  index = Math.max(0,Math.min(snapshot.profiles.length - 1,index));
  selectedId = snapshot.profiles[index].id;
  const card = $('cards').children[index];
  $('cards').scrollTo({left:card.offsetLeft - $('cards').firstElementChild.offsetLeft,behavior:smooth && !reducedMotion.matches ? 'smooth' : 'instant'});
  updatePosition(index);
}
function updatePosition(index) {
  $('position').textContent = (index + 1)+' of '+snapshot.profiles.length;
  $('prev').disabled = index === 0;
  $('next').disabled = index === snapshot.profiles.length - 1;
  selectedId = snapshot.profiles[index]?.id;
}
function currentIndex() { return Math.max(0,snapshot?.profiles.findIndex(p => p.id === selectedId) ?? 0); }
$('prev').addEventListener('click',() => selectIndex(currentIndex() - 1));
$('next').addEventListener('click',() => selectIndex(currentIndex() + 1));
$('cards').addEventListener('keydown',event => {
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
    event.preventDefault();selectIndex(currentIndex() + (event.key === 'ArrowLeft' ? -1 : 1));
  }
});
let scrollFrame;
$('cards').addEventListener('scroll',() => {
  if (scrollFrame || !snapshot?.profiles.length) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = undefined;
    const width = $('cards').children[0]?.getBoundingClientRect().width + 12;
    updatePosition(Math.max(0,Math.min(snapshot.profiles.length - 1,Math.round($('cards').scrollLeft / width))));
  });
},{passive:true});
// Native touch scrolling provides momentum and interruption; mouse dragging
// follows the pointer directly and snaps on release. A swipe never signs in.
let drag;
$('cards').addEventListener('pointerdown',event => {
  if (event.pointerType !== 'mouse' || event.button !== 0 || event.target.closest('button')) return;
  drag = {id:event.pointerId,x:event.clientX,scroll:$('cards').scrollLeft,moved:false};
});
$('cards').addEventListener('pointermove',event => {
  if (!drag || drag.id !== event.pointerId) return;
  const dx = event.clientX - drag.x;
  if (!drag.moved && Math.abs(dx) < 8) return;
  drag.moved = true;
  $('cards').setPointerCapture(event.pointerId);
  $('cards').classList.add('dragging');
  $('cards').scrollLeft = drag.scroll - dx;
});
function endDrag(event) {
  if (!drag || drag.id !== event.pointerId) return;
  const moved = drag.moved;
  drag = undefined;
  $('cards').classList.remove('dragging');
  if ($('cards').hasPointerCapture(event.pointerId)) $('cards').releasePointerCapture(event.pointerId);
  if (moved) selectIndex(currentIndex());
}
$('cards').addEventListener('pointerup',endDrag);
$('cards').addEventListener('pointercancel',endDrag);
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
  if ($('confirm').returnValue !== 'switch' || !pendingId || locked) return;
  setLocked(true);
  try {
    const result = await api('switch',{id:pendingId});
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
  else if (!locked) load();
  else if (snapshot?.busy) startPolling();
});
load();

/* AG_PROFILE_SIDEBAR_ACCOUNT_INTENT */
if (new URLSearchParams(location.search).get('accountAction') === 'add') {
  $('addHelp').open = true;
  requestAnimationFrame(() => $('addHelp').scrollIntoView({block:'nearest'}));
}
