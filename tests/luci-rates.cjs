// Exercise the installed getAssocList() -> status/wireless formatter call path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function extract(source, marker) {
  let start = source.indexOf(marker);
  assert(start >= 0, `Missing ${marker}`);
  start += marker.length;
  const end = source.indexOf('\nreturn s;}', start);
  if (marker.includes('wifirate')) return source.slice(start, end + '\nreturn s;}'.length);
  return source.slice(start, source.indexOf('},getFrequency:', start) + 1);
}

String.prototype.format = function(...args) {
  let i = 0;
  return this.replace(/%(?:\.(\d+))?([dfs])/g, (_, precision, type) => {
    const value = args[i++];
    if (type === 's') return String(value);
    if (type === 'd') return String(Math.trunc(value));
    return Number(value).toFixed(Number(precision || 0));
  });
};

(async () => {
  const root = process.argv[2] || 'http://192.168.0.1:8080/luci-static/resources';
  async function read(relative) {
    if (!root.startsWith('http')) return fs.readFileSync(path.join(root, relative), 'utf8');
    const response = await fetch(`${root}/${relative}`);
    assert(response.ok, `${relative}: HTTP ${response.status}`);
    return response.text();
  }
  const [network, status, wireless] = await Promise.all([
    read('network.js'), read('view/status/include/60_wifi.js'), read('view/network/wireless.js')
  ]);
  const formatters = [
    new Function('_', `return ${extract(status, 'wifirate:')}`)(s => s),
    new Function('_', `return function ${extract(wireless, 'function format_wifirate')}`)(s => s)
  ];
  // Flat fields captured from the AX10's native iwinfo response; no LAN identifiers.
  const legacy = {rx_rate:432350, tx_rate:720580, signal:-62, noise:-91};
  const modern = {rx:{rate:65000,mhz:20,ht:true,mcs:7,short_gi:true}, tx:{rate:72000,mhz:20}};
  const getAssocList = new Function('callIwinfoAssoclist',
    `return ${extract(network, 'getAssocList:')}`)(async () => [structuredClone(legacy), structuredClone(modern), {}]);
  const clients = await getAssocList.call({getIfname:()=>'test', getVlanIfnames:()=>[]});
  assert.equal(clients.length, 3);
  for (const format of formatters) {
    // The exact table call sites pass bss.rx / bss.tx.
    assert.match(format(clients[0].rx), /432\.4.*Mbit\/s/);
    assert.match(format(clients[0].tx), /720\.6.*Mbit\/s/);
    assert(!format(clients[0].rx).includes('MHz'), 'Unknown bandwidth must not become 0/NaN MHz');
    assert.match(format(clients[1].rx), /65\.0.*Mbit\/s, 20.*MHz.*MCS/);
    assert.equal(format(clients[2].rx), '?');
    assert.equal(format(null), '?');
  }
  assert.deepEqual(clients[1], modern, 'Preserve modern rate metadata');
  console.log('PASS: AX10 flat rates, modern rates, and missing rates render in both LuCI tables.');
})().catch(error => { console.error(`${error.name}: ${error.message}`); process.exitCode = 1; });
