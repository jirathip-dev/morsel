// Serial, dependency-free CDP evidence. Own tab only; leaves shared browser intact.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url)),out=path.join(root,'evidence');
fs.mkdirSync(out,{recursive:true});
const comparisonOnly=process.argv.includes('--comparison-only');
const base=process.env.CDP_URL||'http://127.0.0.1:9333';
const target=await fetch(base+'/json/new?about:blank',{method:'PUT'}).then(r=>r.json());
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
let seq=0;const pending=new Map(),errors=[],network=[];
ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);if(p){pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}}else{if(m.method==='Runtime.exceptionThrown')errors.push(m.params);if(m.method==='Runtime.consoleAPICalled'&&['error','assert'].includes(m.params.type))errors.push(m.params);if(m.method==='Network.requestWillBeSent'&&/^https?:/.test(m.params.request.url))network.push(m.params.request.url)}};
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{pending.delete(id);reject(Error('Timeout '+method))},10000);pending.set(id,{resolve:r=>{clearTimeout(timer);resolve(r)},reject:e=>{clearTimeout(timer);reject(e)}});ws.send(JSON.stringify({id,method,params}))})}
async function js(expression){const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),checks=[];
function check(name,ok,data){checks.push({name,pass:!!ok,data});if(!ok)throw Error('FAIL '+name+' '+JSON.stringify(data))}
async function until(expr){for(let i=0;i<60;i++){if(await js(expr))return;await sleep(50)}throw Error('Wait failed: '+expr)}
async function go(file,query=''){await cdp('Page.navigate',{url:pathToFileURL(path.join(root,file)).href+(query?'?'+query:'')});await until("document.readyState==='complete'");await js('document.fonts.ready.then(()=>true)');await sleep(80)}
async function metrics(width=390,height=844){await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true})}
async function click(selector){await js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'nearest',behavior:'instant'})`);const p=await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',clickCount:1});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',...p,button:'left',clickCount:1})}
async function shot(name){await js('document.fonts.ready.then(()=>true)');const r=await cdp('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});fs.writeFileSync(path.join(out,name+'.png'),Buffer.from(r.data,'base64'))}
async function geometry(label){const data=await js(`(()=>{const visible=[...document.querySelectorAll('button,input')].filter(e=>e.getBoundingClientRect().width);return {width:innerWidth,scroll:document.documentElement.scrollWidth,targets:visible.map(e=>{const r=e.getBoundingClientRect();return [r.width,r.height]}),images:[...document.images].map(i=>({ok:i.complete&&i.naturalWidth>0,src:i.getAttribute('src')})),rows:[...document.querySelectorAll('.row')].map(e=>({width:e.clientWidth,scroll:e.scrollWidth,text:e.innerText}))}})()`);check(label+' geometry',data.scroll<=data.width&&data.targets.every(([w,h])=>w>=44&&h>=44)&&data.images.every(i=>i.ok)&&data.rows.every(r=>r.scroll<=r.width),data)}
try{
 await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');
 for(const v of (comparisonOnly?[]:['a','b']))for(const theme of ['paper','night']){
  const key=v+'-'+theme,q='theme='+theme;await metrics();await cdp('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});await go(v+'.html',q);
  check(key+' initial total',await js("document.querySelector('#total').textContent==='715' && document.querySelector('#remaining').textContent==='1285'"));
  check(key+' row policy',await js("document.querySelectorAll('.row').length===5&&[...document.querySelectorAll('.row')].every(r=>!/(confidence|manual|verify|source)/i.test(r.innerText)&&r.querySelector('img').src.endsWith('.svg'))"));
  await geometry(key);await shot(key);
  for(const id of ['focaccia','mortadella','stracciatella','vegetables','unknown']){
   await click(`[data-id="${id}"]`);check(key+' '+id+' opening pending',await js("document.querySelector('dialog').open&&document.querySelector('.state').dataset.status==='pending'"));
   await until("!!document.querySelector('#calories')");
   check(key+' '+id+' detail metadata',await js("!!document.querySelector('.evidence')&&document.querySelector('.evidence').textContent.includes('Confidence:')"));
   check(key+' '+id+' photo boundary',await js(`document.querySelectorAll('.photo img').length===${id==='unknown'?0:1}`));
   if(id==='vegetables')check(key+' missing notes',await js("document.querySelector('.evidence').textContent.includes('No estimation notes')"));
   if(id==='unknown'){await geometry(key+' unknown');await shot(key+'-unknown');}
   if(id==='focaccia'){await geometry(key+' detail');await shot(key+'-detail');}
   await click('#close');await until("!document.querySelector('dialog').open");
   check(key+' '+id+' focus return',await js(`document.activeElement.dataset.id==='${id}'`));
  }
  await click('[data-id="focaccia"]');await until("!!document.querySelector('#calories')");await click('#calories');await js("document.querySelector('#calories').select()");await cdp('Input.insertText',{text:'320'});await click('.save');
  check(key+' save pending unchanged',await js("document.querySelector('#save-state').dataset.status==='pending'&&document.querySelector('#total').textContent==='715'&&document.querySelector('.save').disabled"));await shot(key+'-save-pending');
  await until("!document.querySelector('dialog').open");
  check(key+' saved local only',await js("document.querySelector('[data-id=focaccia] .kcal').textContent==='320'&&document.querySelector('#total').textContent==='735'&&document.querySelector('#remaining').textContent==='1265'&&document.querySelector('#confirmation').textContent.includes('not saved to server')&&document.activeElement.dataset.id==='focaccia'"));await shot(key+'-updated');
  await go(v+'.html',q+'&scenario=save-fail');await click('[data-id="focaccia"]');await until("!!document.querySelector('#calories')");await click('#calories');await js("document.querySelector('#calories').select()");await cdp('Input.insertText',{text:'320'});await click('.save');await until("document.querySelector('#save-state')?.dataset.status==='failure'");
  check(key+' failure preserves draft and row',await js("document.querySelector('#calories').value==='320'&&document.querySelector('#total').textContent==='715'&&!document.querySelector('.save').disabled&&document.querySelector('dialog').open"));await shot(key+'-save-failure');await click('#close');
  await go(v+'.html',q+'&scenario=open-fail');await click('[data-id="unknown"]');await until("document.querySelector('.state')?.dataset.status==='failure'");check(key+' open failure unchanged',await js("!document.querySelector('#calories')&&document.querySelector('#total').textContent==='715'"));await shot(key+'-open-failure');
  await cdp('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});await go(v+'.html',q);await click('[data-id="focaccia"]');
  check(key+' reduced motion',await js("matchMedia('(prefers-reduced-motion:reduce)').matches&&document.getAnimations().every(a=>a.playState!=='running')&&getComputedStyle(document.querySelector('dialog')).animationName==='none'"));await until("!!document.querySelector('#calories')");await shot(key+'-reduce-motion');
  await click('#calories');await js("document.querySelector('#calories').select()");await cdp('Input.insertText',{text:'320'});await click('.save');await until("!document.querySelector('dialog').open");check(key+' reduced save',await js("document.querySelector('#total').textContent==='735'&&document.getAnimations().every(a=>a.playState!=='running')"));
  await metrics(320,700);await go(v+'.html',q);await geometry(key+' narrow');
 }
 for(const theme of ['paper','night']){await metrics(860,1270);await go('index.html','theme='+theme);await until("[...document.querySelectorAll('iframe')].every(f=>f.dataset.loaded==='true')");await sleep(150);await metrics(860,await js("Math.ceil(document.querySelector('.pair').getBoundingClientRect().bottom+24)"));await shot('comparison-'+theme)}
 check('No runtime errors',errors.length===0,errors);check('No HTTP requests during prototype exercise',network.length===0,network);
 fs.writeFileSync(path.join(out,comparisonOnly?'comparison-verification.json':'verification.json'),JSON.stringify({status:'PASS',checks,errors,network,note:'Serial CDP mouse/input probes, owned tab, existing browser. No native/device proof.'},null,2)+'\n');console.log(`PASS ${checks.length} checks; serial captures in ${out}`);
}catch(e){fs.writeFileSync(path.join(out,comparisonOnly?'comparison-verification.json':'verification.json'),JSON.stringify({status:'FAIL',checks,error:String(e),errors,network},null,2));console.error(e);process.exitCode=1}
finally{ws.close();await fetch(base+'/json/close/'+target.id)}
