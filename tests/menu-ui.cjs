const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
function setup(overrides={}) {
  const requests=[];
  const elements=new Map();
  const el=()=>({innerHTML:'',textContent:'',value:'',scrollTop:0,classList:{add(){},remove(){}},style:{},dataset:{}});
  const sandbox={console,setTimeout:()=>0,clearTimeout(){},window:{webkit:{messageHandlers:{rustclick:{postMessage(){}}}},addEventListener(){}},document:{querySelector(s){if(!elements.has(s))elements.set(s,el());return elements.get(s)},addEventListener(){}},capture:r=>requests.push(JSON.parse(JSON.stringify(r)))};
  vm.runInNewContext(fs.readFileSync('ui/app.js','utf8'),sandbox);
  const groups=[{id:'tools',title:'文件工具',section:'文件工具',isSubmenu:true,defaultGroupLevel:2,enabled:true,actions:[{id:'copy_path',title:'拷贝路径',menuTitle:'拷贝路径',defaultLevel:3,enabled:true},{id:'copy_name',title:'拷贝名称',menuTitle:'拷贝名称',defaultLevel:3,enabled:true}]},{id:'copy',title:'复制文件到',section:'复制文件到',isSubmenu:true,defaultGroupLevel:2,enabled:true,actions:[{id:'copy:path:/tmp/a"<test>',title:'复制到 <test>',menuTitle:'<test>',defaultLevel:3,enabled:true}]}];
  sandbox.initial=JSON.parse(JSON.stringify({config:{showTray:false,disabled:[],menuOrder:['tools','copy'],menuLevels:{copy_path:1},...overrides},menuCatalog:{groups}}));
  vm.runInNewContext(`model=initial;config=model.config;page='menu';rpc=async r=>{capture(r);return r.request?.cmd==='menu_catalog'?model.menuCatalog:{}};globalThis.api={html:()=>typeof menuPage==='function'?menuPage():'尚无菜单配置页面',set:typeof setMenuLevel==='function'?setMenuLevel:null,inherit:typeof inheritMenuGroup==='function'?inheritMenuGroup:null,batch:typeof setMenuGroupLevel==='function'?setMenuGroupLevel:null,reset:typeof resetMenuLevels==='function'?resetMenuLevels:null,config:()=>config,search:s=>{menuSearch=s}}`,sandbox);
  return {api:sandbox.api,requests};
}
test('settings expose the three depths with explicit menu paths and safe dynamic names',()=>{
  const {api}=setup();const html=api.html();
  assert.match(html,/一级/);assert.match(html,/二级/);assert.match(html,/三级/);
  assert.match(html,/data-menu-level="copy_path"/);
  assert.match(html,/value="1" selected/);
  assert.match(html,/RightClick/);
  assert(!html.includes('复制到 <test>'));
  assert(html.includes('&lt;test&gt;'));
});
test('changing one depth persists it while keeping other settings',async()=>{
  const {api,requests}=setup();assert.equal(typeof api.set,'function');
  await api.set('copy_name','2');
  const save=requests.find(r=>r.cmd==='save_config');
  assert.equal(save.config.menuLevels.copy_name,2);
  assert.equal(save.config.menuLevels.copy_path,1);
  assert.equal(save.config.showTray,false);
});
test('queued depth changes are merged rather than losing an earlier choice',async()=>{
  const {api}=setup();assert.equal(typeof api.set,'function');
  await Promise.all([api.set('copy_name','1'),api.set('copy_path','2')]);
  assert.equal(api.config().menuLevels.copy_name,1);
  assert.equal(api.config().menuLevels.copy_path,2);
});
test('moving a group preserves child overrides and reset clears both kinds of positions',async()=>{
  const {api}=setup({menuLevels:{'copy:path:/tmp/a"<test>':1}});assert.equal(typeof api.batch,'function');
  await api.batch('tools','2');
  assert.equal(api.config().menuGroupLevels?.tools,2);assert.equal(api.config().menuLevels.copy_name,undefined);assert.equal(api.config().menuLevels.copy_path,undefined);
  assert.equal(api.config().menuLevels['copy:path:/tmp/a"<test>'],1);
  await api.reset();assert.equal(Object.keys(api.config().menuLevels).length,0);assert.equal(Object.keys(api.config().menuGroupLevels).length,0);
  assert.equal(api.config().showTray,false);
});
test('search filters groups without dropping configured levels',()=>{
  const {api}=setup();api.search('拷贝名称');const html=api.html();
  assert.match(html,/data-menu-level="copy_name"/);assert(!html.includes('data-menu-level="copy_path"'));
  assert.equal(api.config().menuLevels.copy_path,1);
});

test('a root group renders inherited second-level children and a separate group position control',async()=>{
  const {api}=setup({menuLevels:{}});
  await api.batch('tools','1');
  assert.equal(api.config().menuGroupLevels?.tools,1);
  assert.equal(Object.keys(api.config().menuLevels).length,0);
  const html=api.html();
  assert.match(html,/aria-label="文件工具分组位置"/);
  assert.match(html,/访达右键 → 文件工具 → 拷贝路径/);
  assert.match(html,/跟随分组（二级）/);
  assert(!html.includes('全部放到一级'));
});
test('a child can leave a root group while siblings continue to inherit',async()=>{
  const {api}=setup({menuLevels:{}});
  await api.batch('tools','1');await api.set('copy_path','1');
  const html=api.html();
  assert.match(html,/访达右键 → 拷贝路径/);
  assert.match(html,/访达右键 → 文件工具 → 拷贝名称/);
  await api.set('copy_path','default');
  assert.match(api.html(),/访达右键 → 文件工具 → 拷贝路径/);
});
test('group and child changes merge and following a group clears only its child overrides',async()=>{
  const {api}=setup({menuLevels:{'copy:path:/tmp/a"<test>':1,copy_path:1}});
  await Promise.all([api.batch('tools','1'),api.set('copy_name','1')]);
  assert.equal(api.config().menuGroupLevels?.tools,1);
  assert.equal(api.config().menuLevels.copy_path,1);
  assert.equal(api.config().menuLevels.copy_name,1);
  assert.equal(typeof api.inherit,'function');await api.inherit('tools');
  assert.equal(api.config().menuLevels.copy_path,undefined);
  assert.equal(api.config().menuLevels.copy_name,undefined);
  assert.equal(api.config().menuLevels['copy:path:/tmp/a"<test>'],1);
  assert.equal(api.config().menuGroupLevels.tools,1);
});
