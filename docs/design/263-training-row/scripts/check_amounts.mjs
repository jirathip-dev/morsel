// Execute the prototype's actual parser/formatter without rendering.
import fs from 'node:fs';import vm from 'node:vm';import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url),src=fs.readFileSync(new URL('prototype.js',root),'utf8').split('function renderToday(){')[0];
function run(code){const sandbox={URLSearchParams,location:{search:''},window:{STATES:[{id:'usual'}]},document:{body:{dataset:{variant:'a'}},documentElement:{classList:{toggle(){}}},querySelector(){return {}}}};vm.createContext(sandbox);return vm.runInContext(src+'\n'+code,sandbox)}
const checks=[];
for(const [draft,expected] of [['',null],['0',null],['-1',null],['NaN',null],['1e999',null],['1,000',null],['2,126',null],['1,500.5',null],['300',300],['400.5',400.5],['0.004',0.004],['300.005',300.005]]){const actual=run(`m.draft=${JSON.stringify(draft)};numeric()`);assert.equal(actual,expected);checks.push({draft,actual,expected,pass:true})}
for(const amount of [0.004,300.005,300.001]){const display=run(`fmt(${amount})`);assert.equal(display,String(amount));checks.push({amount,display,pass:true})}
const changed=src.replace('const s=m.draft.trim();',"const s=m.draft.trim().replace(',','.');");assert.notEqual(changed,src);
const mutantSandbox={URLSearchParams,location:{search:''},window:{STATES:[{id:'usual'}]},document:{body:{dataset:{variant:'a'}},documentElement:{classList:{toggle(){}}},querySelector(){return {}}}};vm.createContext(mutantSandbox);
assert.equal(vm.runInContext(changed+"\nm.draft='1,000';numeric()",mutantSandbox),1);
const report={status:'PASS',scope:'actual prototype parser/formatter only; no browser claim',checks,mutation:{oldCommaParserReturns:1,expected:null,detected:true}};
fs.writeFileSync(new URL('evidence/amount-regression.json',root),JSON.stringify(report,null,2)+'\n');console.log('PASS '+checks.length+' parser/formatter checks; old comma mutation discriminated');
