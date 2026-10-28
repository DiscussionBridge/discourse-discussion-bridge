import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const path = fileURLToPath(new URL('../../assets/javascripts/discourse/components/discussion-bridge-cms-configuration.gjs', import.meta.url));
const source = fs.readFileSync(path, 'utf8');
const pretemplate = source.slice(0, source.indexOf('  <template>'));
const script = pretemplate.replace(/^import .*;\r?\n/gm, '').replaceAll('@tracked ', '').replace(/^\s*@action\s*\r?\n/gm, '').replace('export default class ', 'class ') + '\n}\nglobalThis.Subject = DiscussionBridgeCmsConfiguration;';
let calls, errors, sequence, mode;
function fixture() {
  calls = []; errors = []; sequence = 0; mode = 'success';
  const sandbox = {
    Component: class { constructor() { this.args = { connection: { id: '7' } }; } },
    i18n: (key) => key, crypto: { randomUUID: () => '00000000-0000-4000-8000-' + String(++sequence).padStart(12, '0') },
    popupAjaxError: (error) => errors.push(error),
    ajax: async (url, options) => { calls.push({ url, options }); if (mode === 'lost') throw new Error('synthetic lost response'); return { items: [{status: 'waiting'}] }; },
  };
  vm.createContext(sandbox); vm.runInContext(script, sandbox, {filename:path});
  const subject = new sandbox.Subject(); subject.loadDelivery = async () => {};
  subject.deliveries = [{work:{work_id:'00000000-0000-4000-8000-000000000101'}, attention_recovery:{can_check:true, mapping_revision:'mapping:1', settlement_required:false,
    inspection:{inspection_id:'00000000-0000-4000-8000-000000000201',context_sha256:'a'.repeat(64),status:'ready'}}},
    {work:{work_id:'00000000-0000-4000-8000-000000000102'}, attention_recovery:{can_check:true, mapping_revision:'mapping:2', settlement_required:true,
    inspection:{inspection_id:'00000000-0000-4000-8000-000000000202',context_sha256:'b'.repeat(64),status:'ready'}}}];
  return subject;
}
const passed=[], failures=[];
async function run(name, callback) { try {await callback();passed.push(name);}catch(error){failures.push({name,error:error.message});} }
await run('individual Check submits only current Work and mapping revision with native JSON POST', async () => {
  const subject=fixture(); await subject.checkAttention(subject.deliveries[0]);
  assert.equal(calls.length,1); assert.equal(calls[0].url,'/admin/content-connections/7/cms-attention/check.json');
  assert.equal(calls[0].options.type,'POST'); assert.equal(calls[0].options.contentType,'application/json');
  assert.deepEqual(JSON.parse(calls[0].options.data).selected,[{work_id:subject.deliveries[0].work.work_id,mapping_revision:'mapping:1'}]);
});
await run('selected Check and Retry are explicit distinct actions', async () => {
  const subject=fixture(); subject.attentionSelection=subject.deliveries.map(row=>row.work.work_id); assert.equal(calls.length,0);
  await subject.checkAttention(); assert.equal(JSON.parse(calls[0].options.data).selected.length,2); assert.equal(calls.length,1);
  await subject.retryAttention(); const request=JSON.parse(calls[1].options.data);
  assert.equal(request.selected.length,1); assert.equal(request.selected[0].settle_restored_baseline,false); assert.equal(subject.attentionSelection.length,0);
});
await run('named settlement action emits true only for selected prepared ready rows', async () => {
  const subject=fixture();subject.attentionSelection=subject.deliveries.map(row=>row.work.work_id);
  await subject.retryAttention(null,true); const selected=JSON.parse(calls[0].options.data).selected;
  assert.deepEqual(selected,[{inspection_id:subject.deliveries[1].attention_recovery.inspection.inspection_id,context_sha256:'b'.repeat(64),settle_restored_baseline:true}]);
  assert.match(source,/settlement_effect/);assert.match(source,/settle_selected/);
});
await run('lost native response reuses the exact mutation UUID/body on explicit retry', async () => {
  const subject=fixture(); mode='lost'; await subject.checkAttention(subject.deliveries[0]);
  assert.equal(errors.length,1); assert.equal(subject.attentionBusy,false);
  mode='success'; await subject.checkAttention(subject.deliveries[0]);
  assert.equal(calls[0].options.data,calls[1].options.data);
  await subject.checkAttention(subject.deliveries[0]); assert.notEqual(calls[1].options.data,calls[2].options.data);
});
await run('loading or restoration indicators never auto-submit Check or Retry', async () => {
  const subject=fixture(); subject.deliveries[0].attention_recovery.metadata_restored=true;
  assert.equal(subject.checkAttentionDisabled,true);assert.equal(subject.retryAttentionDisabled,true);assert.equal(calls.length,0);
  subject.attentionBusy=true;await subject.checkAttention(subject.deliveries[0]);assert.equal(calls.length,0);
});
await run('bulk Retry ready selection excludes Not ready and unselected rows', async () => {
  const subject=fixture();subject.attentionSelection=subject.deliveries.map(row=>row.work.work_id);
  subject.deliveries[0].attention_recovery.inspection.status='not_ready';await subject.retryAttention();assert.equal(calls.length,0);
});
console.log(JSON.stringify({checks:passed.length,passed,failures,boundary:'Actual existing GJS component class methods mechanically extracted before template; Glimmer/decorators/native AJAX/UI rendering and CSRF are explicit framework seams; no Ember/browser execution.'},null,2));
process.exitCode=failures.length?1:0;
