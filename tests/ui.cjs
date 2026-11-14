const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');
function ui(){const el=()=>({classList:{add(){},remove(){}},style:{},dataset:{}});const sandbox={console,setTimeout,clearTimeout,window:{webkit:{messageHandlers:{rustclick:{postMessage(){}}}},addEventListener(){}},document:{querySelector:el,addEventListener(){}}};vm.runInNewContext(fs.readFileSync('ui/app.js','utf8')+'\nglobalThis.testResult=v=>{lastResult=v;lastLabel="Result";return resultView()};',sandbox);return sandbox;}
test('disk scan renders numeric file count without treating it as hash results',()=>{const html=ui().testResult({files:3,bytes:4096,unreadable:1,largest:[{path:'/test/a',bytes:4096}]});assert.match(html,/3 个文件/);assert.match(html,/4.0 KB/)});
test('file paths are escaped in result view',()=>{const html=ui().testResult({paths:['/tmp/<img src=x onerror=alert(1)>']});assert(!html.includes('<img'));assert(html.includes('&lt;img'))});

test('input rule editor preserves a disabled input source and escapes application and source names',()=>{
  const context=ui();
  const html=vm.runInNewContext(`
    inputSourceStatus={sources:[{id:'us',name:'English <US>'}],accessibility:false};
    config={inputSourceRules:[{bundleID:'example.app',name:'<Editor>',defaultSourceID:'inactive"ime',rememberLast:true,forceEnglishPunctuation:true}]};
    inputSourcesPage()+inputRuleFields(config.inputSourceRules[0]);
  `,context);
  assert.match(html,/&lt;Editor&gt;/);
  assert.match(html,/English &lt;US&gt;/);
  assert.match(html,/value="inactive&quot;ime" selected/);
  assert.match(html,/data-action="ax-permission"/);
  assert(!html.includes('<Editor>'));
});

test('input rule edits apply only after saving, preserve other settings and support independent options',async()=>{
  const context=ui(), requests=[];
  let failNextSave=true;
  context.send=async request=>{
    requests.push(JSON.parse(JSON.stringify(request)));
    if(request.cmd==='save_config'&&failNextSave){failNextSave=false;throw Error('写入失败')}
    return request.request?.cmd==='input_source_status'?{sources:[],accessibility:true}:{};
  };
  vm.runInNewContext(`
    config={showTray:false};model={config};rpc=send;
    const editor={name:'编辑器',bundleID:'editor',defaultSourceID:null,rememberLast:false,forceEnglishPunctuation:true};
    const chat={name:'聊天',bundleID:'chat',defaultSourceID:null,rememberLast:true,forceEnglishPunctuation:false};
  `,context);
  const run=code=>vm.runInNewContext(code,context);
  await assert.rejects(run('saveInputRule("editor",editor)'),/写入失败/);
  assert.equal(run('config.inputSourceRules'),undefined);
  assert(!requests.some(request=>request.request?.cmd==='apply_settings'));
  await run('Promise.all([saveInputRule("editor",editor),saveInputRule("chat",chat)])');
  await run('saveInputRule("editor",{...editor,defaultSourceID:"us"})');
  assert.equal(run('config.inputSourceRules.length'),2);
  assert.equal(run('config.inputSourceRules[0].defaultSourceID'),'us');
  await run('saveInputRule("editor",null)');
  const applied=requests.filter(request=>request.request?.cmd==='apply_settings').at(-1).request.config;
  assert.equal(applied.showTray,false);
  assert.deepEqual(applied.inputSourceRules,[{name:'聊天',bundleID:'chat',defaultSourceID:null,rememberLast:true,forceEnglishPunctuation:false}]);
});
