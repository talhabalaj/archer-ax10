const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  const root = process.argv[2] || 'http://192.168.0.1:8080/luci-static/resources';
  const relative = 'view/system/leds.js';
  const source = root.startsWith('http') ? await (await fetch(`${root}/${relative}`)).text() : fs.readFileSync(path.join(root, relative), 'utf8');
  let data, maps;
  class Map {
    constructor() { maps++; }
    section() { return {option:()=>({value(){}})}; }
    render() { return 'FORM'; }
  }
  const L = {env:{documentroot:''}, resource:s=>s, resolveDefault:(p,d)=>Promise.resolve(p).catch(()=>d)};
  const view = new Function('view','uci','rpc','form','fs','L','_','E',source)(
    {extend:s=>s}, {}, {declare:()=>async()=>data}, {Map}, {list:async()=>[]}, L, s=>s, (_,__,text)=>text
  );
  // The live AX10 omits triggers because its LED devices have no trigger sysfs file.
  data = {power:{trigger:'none',brightness:0,max_brightness:8}}; maps = 0;
  const result = await view.render(await view.load());
  assert.match(result, /LED control through LuCI is unavailable/);
  assert.equal(maps, 0, 'Do not offer controls the stock driver cannot apply');
  data = {power:{triggers:['none','timer'],brightness:1,max_brightness:1}}; maps = 0;
  assert.equal(await view.render(await view.load()), 'FORM');
  assert.equal(maps, 1, 'Preserve standard LED configuration');
  console.log('PASS: LED page handles AX10 without triggers and preserves standard LED support.');
})().catch(error=>{console.error(`${error.name}: ${error.message}`);process.exitCode=1;});
