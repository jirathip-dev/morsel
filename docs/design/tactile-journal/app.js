'use strict';
const options=new URLSearchParams(location.search), variant=document.body.dataset.variant;
const theme=options.get('theme')==='night'?'night':'paper',scenario=options.get('scenario')||'local';
document.documentElement.classList.toggle('night',theme==='night');
document.documentElement.classList.toggle('rm',options.get('rm')==='1');
const fixture=structuredClone(window.FIXTURE),foods=fixture.foods;
const journal=document.querySelector('#journal'),dialog=document.querySelector('#detail'),sheet=document.querySelector('#sheet');
let selected=null,opening=null,saving=null,lastRow=null;
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function draw(message=''){
 const total=foods.reduce((s,f)=>s+f.kcal,0),remain=fixture.goal-total;
 const macros=['p','c','f'].map(k=>foods.reduce((s,f)=>s+f[k],0));
 journal.innerHTML=`<aside class="folio" aria-hidden="true">13 SEP / FOOD JOURNAL</aside><p class="study">${variant.toUpperCase()} · ${variant==='a'?'INK-WASH':'TACTILE'} / ${theme.toUpperCase()}<br>UNSHIPPED CONCEPT · FICTIONAL DATA</p><header><div><time>13 SEP · SUNDAY</time><h1>Today</h1></div><div class="chrome" aria-label="Add and Settings shown for context only; inactive"><span aria-hidden="true">＋</span><span aria-hidden="true">⚙</span></div></header><section class="readout" aria-label="Food calories"><svg class="ring" viewBox="0 0 90 90" aria-hidden="true"><circle cx="45" cy="45" r="34" fill="none" stroke="var(--inkline)" stroke-width="1"/><circle cx="45" cy="45" r="28" fill="none" stroke="var(--field)" stroke-width="10"/><circle cx="45" cy="45" r="28" fill="none" stroke="var(--accent)" stroke-width="10" pathLength="100" stroke-dasharray="${Math.min(100,total/fixture.goal*100)} 100" transform="rotate(-90 45 45)"/><circle cx="45" cy="45" r="21" fill="none" stroke="var(--inkline)" stroke-width=".7"/><path d="M45 7v14" stroke="var(--inkline)"/></svg><div><p class="eyebrow">Eaten · Goal</p><p class="totals"><output id="total">${total}</output> <span>/ ${fixture.goal} kcal</span></p><p class="remaining"><b id="remaining">${Math.abs(remain)}</b> kcal ${remain>=0?'left':'over'}</p><p class="source">Goal source: manual · fixture</p></div></section><section class="macros" aria-label="Protein, carbs and fat">${['Protein','Carbs','Fat'].map((label,i)=>`<div class="macro" style="--pigment:var(--${label.toLowerCase()})"><span>${label}</span><span class="rail" aria-hidden="true"><i style="width:${Math.min(100,macros[i]/fixture.macroGoals[i]*100)}%"></i></span><span class="mono">${macros[i]} / ${fixture.macroGoals[i]} g</span></div>`).join('')}</section><aside class="activity">Movement + exercise <span>Not available · separate from food goal</span></aside><div class="meal-title"><h2>Lunch</h2><span class="mono">12:30 · ${total} kcal</span></div><section aria-label="Lunch foods">${foods.map(f=>`<button class="row" data-id="${f.id}" aria-haspopup="dialog" aria-label="Edit ${esc(f.name)}, ${f.quantity} ${f.unit}, ${f.kcal} kilocalories"><img src="assets/${variant}-${theme}-${f.id}.svg" alt="" width="64" height="64"><span class="name">${esc(f.name)}<span class="portion">${f.quantity} ${f.unit}</span></span><span class="energy"><span class="kcal">${f.kcal}</span><small>kcal <span class="chevron" aria-hidden="true">›</span></small></span><span class="nutrition">P ${f.p}g · C ${f.c}g · F ${f.f}g</span>${message&&f.id===lastRow?`<span id="confirmation" role="status">${esc(message)}</span>`:""}</button>`).join('')}</section><p class="note">Illustrations represent foods, not exact portions.<br>Tap a row to inspect or edit.</p><nav aria-label="Primary navigation · context only"><span aria-current="page">Today</span><span aria-disabled="true">History</span><span aria-disabled="true">Goals</span></nav>`;
 journal.querySelectorAll('.row').forEach(row=>row.addEventListener('click',()=>openFood(row.dataset.id)));
}
function head(f){return `<div class="sheet-head"><div><p class="eyebrow">Food detail · concept</p><h2 id="detail-title">${esc(f.name)}</h2></div><button type="button" id="close" aria-label="Close food detail">×</button></div>`}
function wireClose(){sheet.querySelector('#close').onclick=()=>dialog.close()}
function openFood(id){
 selected=foods.find(f=>f.id===id);lastRow=id;
 sheet.innerHTML=head(selected)+'<p class="state" data-status="pending" role="status">Opening detail…<br><small>Prototype delay · not an error.</small></p>';
 wireClose();dialog.showModal();
 opening=setTimeout(()=>{
  if(!dialog.open)return;
  if(scenario==='open-fail'){
   sheet.innerHTML=head(selected)+'<p class="state" data-status="failure" role="alert">Couldn’t open detail.<br>The row is unchanged. Close and try again.<br><small>Simulated failure · no request was sent.</small></p>';wireClose();
  }else if(scenario!=='open-pending')editForm();
 },240);
}
function editForm(){
 const f=selected;
 sheet.innerHTML=head(f)+`<p class="muted">${f.quantity} ${f.unit} · P ${f.p}g · C ${f.c}g · F ${f.f}g</p><form id="edit"><label for="calories">Calories for this item (kcal)<input id="calories" name="calories" type="number" inputmode="decimal" min="0" max="10000" step="1" required value="${f.kcal}"></label><small>Correct the recorded calories; macros stay unchanged.</small><section class="evidence" aria-label="Source and uncertainty"><p>Source: ${esc(f.source)} · Confidence: <span class="mono">${Math.round(f.confidence*100)}%</span></p><p>${esc(f.notes||'No estimation notes were recorded.')}</p></section>${f.photo?'<figure class="photo"><img src="assets/fixture-photo.jpg" alt="Public example photo of focaccia bread on a board; not the owner’s lunch"><figcaption>Meal-level photo · stored-photo scenario only.<br>Public demo image, not the owner’s meal or item evidence.<br>Fred Benenson · CC BY-SA 4.0 (credits in README).</figcaption></figure>':'<p class="muted">No photo in this fixture. Neutral illustration; food identity unknown.</p>'}<p id="save-state" class="state" role="status"></p><button class="save" type="submit">Save edit · prototype only</button><p class="local-disclaimer">Changes stay in this page’s memory. No server save.</p></form>`;
 wireClose();sheet.querySelector('#edit').addEventListener('submit',saveEdit);
}
function saveEdit(event){
 event.preventDefault();if(saving)return;
 const input=sheet.querySelector('#calories'),next=Number(input.value);
 if(!input.checkValidity()||!Number.isFinite(next)){input.reportValidity();return;}
 const status=sheet.querySelector('#save-state'),save=sheet.querySelector('.save');
 status.dataset.status='pending';status.textContent='Saving edit… Prototype pending; row has not changed.';save.disabled=true;input.disabled=true;
 saving=setTimeout(()=>{
  saving=null;if(!dialog.open)return;
  if(scenario==='save-pending')return;
  if(scenario==='save-fail'){
   status.dataset.status='failure';status.setAttribute('role','alert');status.textContent='Couldn’t save. Your edit is still here; the row is unchanged. Simulated failure — no server request.';save.disabled=false;input.disabled=false;return;
  }
  selected.kcal=next;const id=selected.id;dialog.close();draw('Updated in this prototype only · not saved to server.');
  const row=journal.querySelector(`[data-id="${id}"]`);row.focus({preventScroll:true});row.scrollIntoView({block:'nearest',behavior:'instant'});
 },900);
}
dialog.addEventListener('close',()=>{clearTimeout(opening);clearTimeout(saving);saving=null;const row=journal.querySelector(`[data-id="${lastRow}"]`);if(row)row.focus({preventScroll:true});});
draw();
