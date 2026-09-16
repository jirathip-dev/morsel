// Dependency-free, serial CDP render gate. No product build; owns one tab only.
import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {fileURLToPath,pathToFileURL} from 'node:url';import{spawnSync}from'node:child_process';
const R=path.dirname(path.dirname(fileURLToPath(import.meta.url))),O=path.join(R,'evidence');fs.mkdirSync(O,{recursive:true});
const compare=process.argv.includes('--check-captures'),smoke=process.argv.includes('--smoke');
const cov=JSON.parse(fs.readFileSync(path.join(R,'coverage.json'))),checks=[],captures=[],errors=[],network=[],align=[];
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const inputFiles=['style.css','specimen.js','gallery.js','scripts/verify.mjs','coverage.json',...fs.readdirSync(R).filter(x=>x.endsWith('.html'))].sort();const inputDigest=hash(inputFiles.map(f=>f+'\0'+hash(fs.readFileSync(path.join(R,f)))).join('\0'));
function admit(){const r=spawnSync('python3',[path.join(R,'scripts/admit.py')],{stdio:'inherit'});if(r.status!==0){process.exitCode=75;throw Error('DEFER: admission '+r.status)}}
try{admit()}catch(e){console.error(String(e));process.exit(75)}const endpoint=process.env.CDP_URL||'http://127.0.0.1:9333',target=await fetch(endpoint+'/json/new?about:blank',{method:'PUT'}).then(r=>r.json());const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
let seq=0;const pending=new Map();ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.id){const p=pending.get(m.id);if(p){pending.delete(m.id);m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result)}}else if(m.method==='Runtime.exceptionThrown'||m.method==='Log.entryAdded'&&m.params.entry.level==='error'||m.method==='Runtime.consoleAPICalled'&&['error','assert'].includes(m.params.type))errors.push(m.params);else if(m.method==='Network.requestWillBeSent'&&/^http/.test(m.params.request.url))network.push(m.params.request.url)};
function cdp(method,params={}){return new Promise((resolve,reject)=>{const id=++seq,t=setTimeout(()=>reject(Error('CDP timeout '+method)),15000);pending.set(id,{resolve:r=>{clearTimeout(t);resolve(r)},reject:e=>{clearTimeout(t);reject(e)}});ws.send(JSON.stringify({id,method,params}))})}
async function js(expression){const r=await cdp('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));async function until(expression){for(let i=0;i<100;i++){if(await js(expression))return;await sleep(30)}throw Error('Timeout '+expression)}
function check(name,pass,data){checks.push({name,pass:!!pass,...(data===undefined?{}:{data})});if(!pass)throw Error('FAIL '+name+' '+JSON.stringify(data))}
async function metrics(width=390,height=844){await cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<500})}
async function go(file,q=''){await js('window.ready=false');await cdp('Page.navigate',{url:pathToFileURL(path.join(R,file)).href+(q?'?'+q:'')});await until("window.ready&&document.readyState==='complete'");await js('document.fonts.ready.then(()=>true)');await until('[...document.images].filter(i=>i.loading!=="lazy").every(i=>i.complete&&i.naturalWidth>0)');await js('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))')}
async function shot(name,observed){await cdp('Input.dispatchMouseEvent',{type:'mouseMoved',x:0,y:0});await js('document.activeElement?.blur()');const bytes=Buffer.from((await cdp('Page.captureScreenshot',{format:'png',captureBeyondViewport:false})).data,'base64'),file=path.join(O,name+'.png');if(compare){check('Byte-identical '+name,fs.existsSync(file)&&fs.readFileSync(file).equals(bytes));}else fs.writeFileSync(file,bytes);captures.push({file:'evidence/'+name+'.png',sha256:hash(bytes),width:bytes.readUInt32BE(16),height:bytes.readUInt32BE(20),observed});return bytes}
async function geometry(){return js(`(()=>({overflow:document.documentElement.scrollWidth>innerWidth,controls:[...document.querySelectorAll('a,button,select,summary')].filter(e=>e.getBoundingClientRect().height>0).map(e=>{const r=e.getBoundingClientRect();return {text:e.textContent.trim(),width:r.width,height:r.height}})}))()`)}
async function fonts(selector){const doc=await cdp('DOM.getDocument'),node=await cdp('DOM.querySelector',{nodeId:doc.root.nodeId,selector});return (await cdp('CSS.getPlatformFontsForNode',{nodeId:node.nodeId})).fonts}
let renderer;
try{
await cdp('Page.enable');await cdp('Runtime.enable');await cdp('Network.enable');await cdp('Log.enable');await cdp('DOM.enable');await cdp('CSS.enable');await cdp('Emulation.setScrollbarsHidden',{hidden:true});renderer=await cdp('Browser.getVersion');await metrics();
for(const p of cov.pages.filter(p=>!smoke||['today-headline','food-rows','goals-filled','technical-chatPrompt','weight-chart'].includes(p.id))){
 admit();for(const theme of ['paper','night']){let before;
 for(const version of ['before','after']){
  await go(p.id+'.html',`theme=${theme}&version=${version}`);
  const observed=await js(`({page:location.pathname.split('/').pop(),theme:document.documentElement.dataset.theme,version:document.documentElement.dataset.version,content:document.querySelector('#specimen').innerText,voices:[...document.querySelectorAll('.voice')].map(e=>{const c=getComputedStyle(e),r=e.getBoundingClientRect();return {sites:e.dataset.sites.split(' ').filter(Boolean),keep:e.classList.contains('keep'),text:e.textContent,font:c.fontFamily,size:c.fontSize,weight:c.fontWeight,features:c.fontFeatureSettings,rect:{x:r.x,y:r.y,w:r.width,h:r.height,bottom:r.bottom},color:c.color}})})`);
  check(p.id+' observed route',observed.page===p.id+'.html'&&observed.theme===theme&&observed.version===version);
  const g=await geometry();check(p.id+' geometry',!g.overflow&&g.controls.every(c=>c.width>=44&&c.height>=44),g);
  check(p.id+' every source glyph visible',observed.voices.every(v=>v.text===''||v.rect.x>=24&&v.rect.x+v.rect.w<=391&&v.rect.y>=48&&v.rect.bottom<=805),observed.voices);
  check(p.id+' source-site coverage',p.sites.every(s=>observed.voices.some(v=>v.sites.includes(s))));
  check(p.id+' intended family',observed.voices.every(v=>v.font.includes(version==='after'&&!v.keep?'Garamond':'Plex')));
  check(p.id+' tnum applied',observed.voices.every(v=>v.features.includes('"tnum"')));
  const actualFonts=await fonts('.voice');check(p.id+' real custom face',actualFonts.some(f=>f.isCustomFont&&f.familyName.includes(version==='after'&&p.group!=='technical'?'Garamond':'Plex')),actualFonts);
  if(version==='before')before=observed;else {check(p.id+' paired content identical',before.content===observed.content);check(p.id+' sizes and weights unchanged',JSON.stringify(before.voices.map(v=>[v.size,v.weight,v.color,v.sites]))===JSON.stringify(observed.voices.map(v=>[v.size,v.weight,v.color,v.sites])));}
  await shot(`${p.id}-${theme}-${version}`,{page:p.id,theme,version,sites:p.sites,fonts:actualFonts,voices:observed.voices});check(p.id+' no console errors',errors.length===0,errors);
 }
 }
}
if(!smoke){
for(const scale of ['small','large'])for(const theme of ['paper','night'])for(const weight of [400,500]){
 admit();await metrics(390,scale==='small'?1180:1360);await go('alignment-'+scale+'.html','theme='+theme);await js(`document.querySelectorAll('.digitline,.columns').forEach(e=>e.style.fontWeight=${JSON.stringify(String(weight))})`);await js('document.fonts.ready');
 const actualFonts=await fonts('.digitline');check('Proof actual EB Garamond',actualFonts.every(f=>f.isCustomFont&&f.familyName.includes('Garamond')),actualFonts);
 const lines=await js(`(()=>{const rangeWidth=e=>{const r=document.createRange();r.selectNodeContents(e);return r.getBoundingClientRect().width};return [...document.querySelectorAll('.digitline')].map(e=>({size:Number(e.dataset.size),feature:e.dataset.feature,weight:getComputedStyle(e).fontWeight,widths:[...e.querySelectorAll('.digit')].map(rangeWidth),boxes:[...e.querySelectorAll('.digit')].map(s=>{const c=getComputedStyle(s);return {display:c.display,width:c.width,padding:c.padding}})}))})()`);
 for(const line of lines){line.spread=Math.max(...line.widths)-Math.min(...line.widths);check('Measured '+theme+' '+weight+' '+line.size+' '+line.feature,line.feature==='tnum'?line.spread<=.016:line.spread>.5,line);check('No equal-cell trick',line.boxes.every(b=>b.display==='inline'&&b.width==='auto'&&b.padding==='0px'));}
 const columns=await js(`(()=>{return [...document.querySelectorAll('.columns')].map(e=>({size:Number(e.dataset.size),widths:[...e.children].map(x=>{const r=document.createRange();r.selectNodeContents(x);return r.getBoundingClientRect().width})}))})()`);for(const c of columns)check('Natural digit-column width '+c.size,Math.max(...c.widths)-Math.min(...c.widths)<=.016,c);
 align.push({renderer:'Chromium DOM Range (not SwiftUI)',scale,theme,weight,fonts:actualFonts,lines,columns});await shot(`alignment-${scale}-${theme}-${weight}`,{theme,weight,scale,lines,columns});
}
for(const width of [390,1100]){
 admit();await metrics(width,width===390?844:1000);await go('index.html');let g=await geometry();check('Gallery '+width+' geometry',!g.overflow&&g.controls.every(c=>c.width>=44&&c.height>=44),g);
 await until('[...document.images].slice(0,2).every(i=>i.complete&&i.naturalWidth>0)');await shot('gallery-'+width,{width,theme:'paper'});
 // Actual pointer input switches the theme; no state assignment.
 await js("document.querySelector('#night-button').scrollIntoView({block:'center',behavior:'instant'})");
 const loc=await js("(()=>{let e=document.querySelector('#night-button'),r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;if(!e.contains(document.elementFromPoint(x,y)))throw Error('button obscured');return{x,y}})()");
 await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...loc,button:'left',clickCount:1});await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',...loc,button:'left',clickCount:1});
 await until("galleryState.theme==='night'");check('Gallery theme updates links and captures',await js("[...document.querySelectorAll('[data-page]')].every(a=>a.href.includes('theme=night'))"));
 // Group filter is an explicit DOM change-event seam, not claimed as native pointer coverage.
 await js("document.querySelector('#group').value='technical';document.querySelector('#group').dispatchEvent(new Event('change'))");check('Filter exposes only technical',await js("[...document.querySelectorAll('.group')].filter(e=>!e.hidden).map(e=>e.dataset.group).join()==='technical'"));
}
check('Exhaustive capture count',captures.length===cov.pages.length*4+10,{actual:captures.length,expected:cov.pages.length*4+10});
}
check('Runtime clean',errors.length===0,errors);check('No HTTP requests from artifact',network.length===0,network);
const report={status:'PASS',mode:smoke?'smoke':compare?'independent-rerender':'full',inputDigest,renderer,checks,captures,errors,network,native_alignment:'UNVERIFIED: no-Swift fence; clarification timed out'};
fs.writeFileSync(path.join(O,smoke?'smoke.json':compare?'rerender.json':'verification.json'),JSON.stringify(report,null,2)+'\n');if(!smoke&&!compare)fs.writeFileSync(path.join(O,'alignment.json'),JSON.stringify(align,null,2)+'\n');console.log('PASS '+checks.length+' checks; '+captures.length+' captures');
}catch(e){fs.writeFileSync(path.join(O,smoke?'smoke-failure.json':'verification-failure.json'),JSON.stringify({status:process.exitCode===75?'DEFER':'FAIL',error:String(e),checks,captures,errors},null,2));console.error(e);process.exitCode=process.exitCode===75?75:1}finally{ws.close();await fetch(endpoint+'/json/close/'+target.id)}
