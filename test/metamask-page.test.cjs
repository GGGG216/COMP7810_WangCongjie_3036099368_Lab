// Exercise the real page script without a browser or any wallet transactions.
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = readFileSync(join(__dirname, '../scripts/metamask-deploy.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const admin = '0x' + '11'.repeat(20), deployed = '0x' + '22'.repeat(20);
const txHash = '0x' + '33'.repeat(32);
const elements = new Map();
let canonical;
const context = vm.createContext({
  document: {getElementById(id) {if(!elements.has(id)) elements.set(id, {}); return elements.get(id);}},
  window: {addEventListener() {}, dispatchEvent() {}}, Event: class {},
  fetch: async(path, options) => {
    assert.equal(path, '/transaction');
    assert.equal(JSON.parse(options.body).hash, txHash);
    return {ok: true, json: async()=>canonical};
  },
});
vm.runInContext(script, context);
vm.runInContext(`account='${admin}'; wallet={request(){throw Error('Must not rely on wallet transaction cache');}};`, context);
const run = () => vm.runInContext(`checkTx('MockUSDC','${txHash}',{data:'0x6000'})`, context);
(async()=>{
  canonical={pending:false,transaction:{from:admin,chainId:'0xaa36a7',value:'0x0',input:'0x6000',to:null},receipt:{status:'0x1',contractAddress:deployed}};
  await run();
  assert.equal(vm.runInContext('addresses.MockUSDC', context),deployed);
  canonical.transaction.chainId='0x1';
  await assert.rejects(run(), /unexpected chain ID/);
  canonical.transaction.chainId='0xaa36a7';
  canonical.transaction.from=deployed;
  await assert.rejects(run(), /original deploying account/);
  canonical.transaction.from=admin;
  canonical.transaction.input='0x6001';
  await assert.rejects(run(), /bytecode or constructor/);
  console.log('Page regression checks passed: canonical RPC success; wrong chain, account, and bytecode rejected.');
})().catch(e=>{console.error(e);process.exitCode=1;});
