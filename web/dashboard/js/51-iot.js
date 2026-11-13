function viewIot() {
  const c = S.iot, D = S.devices;
  if (!c || !D) return `<div class="card"><div class="card-b" style="padding:22px"><span class="spin"></span></div></div>` + skel(3);
  const f = S.dirty.iot || c;
  const isDirty = !!S.dirty.iot;
  const iotDevs = sortDevices(D.list.filter(d => d.net === "iot"));
  const homes = sortDevices(D.list.filter(d => d.net === "home"));
  return `
  <div class="card">
    <div class="card-h"><div style="flex:1"><h3>${esc(c.ssid || "IoT network")}</h3>
      <p>A separate 2.4 GHz network for smart devices. They can't reach your devices or this router.</p></div>
      <label class="sw"><input type="checkbox" id="iot-enable" ${f.enable === "on" ? "checked" : ""} aria-label="IoT Wi-Fi on"><span></span></label></div>
    <div class="card-b" id="iot-form">
      <div class="field"><label for="iot-ssid">Network name</label><div class="input"><input id="iot-ssid" value="${esc(f.ssid)}" maxlength="32"></div></div>
      <div class="field"><label for="iot-pw">Password</label>${pwField("iot-pw", f.password)}</div>
      <div class="field"><label for="iot-hidden">Hide network name</label><label class="sw"><input type="checkbox" id="iot-hidden" ${f.hidden === "on" ? "checked" : ""}><span></span></label></div>
      <div class="field"><label>Gateway</label><span class="mono">${esc(c.gateway)}</span></div>
    </div>
    ${isDirty ? `<div class="card-f"><button class="btn" data-act="iot-reset">Discard</button><button class="btn primary" data-act="iot-save">Save changes</button></div>` : ""}
  </div>
  ${joinCard(c, iotDevs)}
  ${sectionList("IoT devices", iotDevs.map(d => simpleRow(d,
      (d.pinned ? `<span class="tag" title="This device always gets ${esc(d.pinned)}">Fixed ${esc(d.pinned.split(".").pop() === d.pinned ? d.pinned : "." + d.pinned.split(".").pop())}</span>` : "")
      + `<span class="pair"><span class="muted" style="font-size:12.5px">Internet</span>${rowSwitch("internet", d, d.internet, "Internet access")}</span>`
      + `<span class="pair" title="Can open connections to your home devices on any port"><span class="muted" style="font-size:12.5px">Home</span>${rowSwitch("reach", d, d.reach, "Can reach home devices on any port")}</span>`
      + (d.pinned && (!d.online || c.lock === "on") ? `<button class="btn sm" data-act="forget" data-mac="${d.mac}">Remove fixed address</button>` : ""))),
    "Nothing has joined the IoT network yet.")}
  <h2>Who can reach IoT devices</h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Home devices</h3><p>${c.lan_mode === "selected" ? "Only the devices switched on below can open connections to IoT devices." : "Every device on your home network can open connections to IoT devices."}</p></div>
    <div class="seg" id="lanmode"><button data-mode="all" aria-pressed="${c.lan_mode !== "selected"}">All</button><button data-mode="selected" aria-pressed="${c.lan_mode === "selected"}">Selected</button></div></div></div>
  ${c.lan_mode === "selected" ? `<div style="margin-top:12px">${'<div class="list">' + (homes.map(d => simpleRow(d, rowSwitch("allowed", d, d.allowed, "Can reach IoT devices"))).join("") || '<div class="empty">No home devices.</div>') + "</div>"}</div>` : ""}
  ${rulesCard(c, iotDevs)}`;
}

// What IoT devices may open to the home network (iot_allow_lan), as a table:
// from (an IoT device, or any), to (a home device, or any), and which port. A rule is
// "tcp:8123", "udp:6001-6010" or "any" (every port), then "@<IoT address>" for one
// IoT device and ">home address" for one home device, e.g.
// tcp:8123@192.168.50.137>192.168.0.20. IoT devices with their Home switch on
// (iot_lan_open) are listed too: any port, any home device.
const PORT_NAMES = { 80: "web page", 443: "web page (HTTPS)", 554: "camera stream (RTSP)", 1400: "Sonos", 1883: "MQTT",
  5353: "device discovery (mDNS)", 8096: "Jellyfin", 8123: "Home Assistant", 8883: "MQTT over TLS", 8899: "inverter link", 32400: "Plex" };
const IP_RE = "((?:(?:0|[1-9]\\d{0,2})\\.){3}(?:0|[1-9]\\d{0,2}))";
const RULE_RE = new RegExp(`^(?:(tcp|udp):(\\d+)(?:[-:](\\d+))?|(any))(?:@${IP_RE})?(?:>${IP_RE})?$`);
const ipOk = ip => !ip || ip.split(".").every(n => +n <= 255);
function parseRule(w) {
  const m = RULE_RE.exec(w);
  if (!m || !(ipOk(m[5]) && ipOk(m[6]))) return null;
  const a = m[2] ? +m[2] : 0, b = m[3] ? +m[3] : 0;
  if (m[1] && (a < 1 || a > 65535 || (m[3] && (b < a || b > 65535)))) return null;      // as the firewall reads it
  return { proto: m[1] || "any", from: a, to: b, ip: m[5] || "", dst: m[6] || "" };
}
const portText = r => r.proto === "any" ? "Any port" : `${r.proto.toUpperCase()} ${r.to && r.to !== r.from ? `${r.from}–${r.to}` : r.from}`;
const sel = (id, label, opts) => `<label class="rf"><span>${label}</span><div class="input"><select id="${id}" class="sel" ${S.rulesBusy ? "disabled" : ""}>${opts}</select></div></label>`;
function ruleCell(name, sub, warn, d) {
  return `<div class="rc">${d ? `<span class="dot ${d.online ? "on" : ""}" title="${d.online ? "Online" : "Offline"}"></span>` : ""}<div style="min-width:0">
    <div class="rn">${esc(name)}</div>${sub || warn ? `<div class="rs">${sub ? `<span class="mono">${esc(sub)}</span>` : ""}${warn ? `<span class="rw">${esc(warn)}</span>` : ""}</div>` : ""}</div></div>`;
}
function rulesCard(c, iotDevs) {
  const homes = sortDevices((S.devices ? S.devices.list : []).filter(d => d.net === "home" && d.ip));
  const rules = (c.allow_lan || "").split(/\s+/).filter(Boolean);
  const iotAt = ip => iotDevs.find(d => d.pinned === ip) || iotDevs.find(d => d.ip === ip);
  const homeAt = ip => homes.find(d => d.ip === ip);
  const busy = S.rulesBusy ? "disabled" : "";
  const fromCell = ip => { if (!ip) return ruleCell("Any IoT device"); const d = iotAt(ip);
    return ruleCell(d ? devName(d) : "Nobody has this address", ip, d ? (d.pinned === ip ? "" : "address may change") : "", d); };
  const toCell = ip => { if (!ip) return ruleCell("Any home device"); const d = homeAt(ip);
    return ruleCell(d ? devName(d) : "Nobody has this address now", ip, "", d); };
  const tr = (from, to, r, btn) => `<tr><td data-l="From">${from}</td><td data-l="To">${to}</td>
    <td data-l="Port"><div class="rn">${esc(portText(r))}</div>${r.proto !== "any" && !r.to && PORT_NAMES[r.from] ? `<div class="rs">${esc(PORT_NAMES[r.from])}</div>` : r.proto === "any" ? `<div class="rs">All protocols</div>` : ""}</td>
    <td class="rx">${btn}</td></tr>`;
  const rows = [];
  iotDevs.filter(d => d.reach).forEach(d => rows.push(tr(ruleCell(devName(d), d.pinned || d.ip, "Home switch on", d), ruleCell("Any home device"), { proto: "any" },
    `<button class="btn sm" data-act="reach-off" data-mac="${d.mac}" ${busy} aria-label="Remove: ${esc(devName(d))} to any home device">Remove</button>`)));
  rules.forEach(w => { const r = parseRule(w);
    rows.push(r ? tr(fromCell(r.ip), toCell(r.dst), r, `<button class="btn sm" data-act="rl-del" data-rule="${esc(w)}" ${busy} aria-label="Remove this rule">Remove</button>`)
      : `<tr><td colspan="3" data-l="Rule"><div class="rn mono">${esc(w)}</div><div class="rs"><span class="rw">Not understood; it has no effect</span></div></td>
         <td class="rx"><button class="btn sm" data-act="rl-del" data-rule="${esc(w)}" ${busy}>Remove</button></td></tr>`); });
  const f = S.ruleForm || {};
  const iotOpts = `<option value="">Any IoT device</option>` + iotDevs.filter(d => d.pinned || d.ip).map(d => { const ip = d.pinned || d.ip;
    return `<option value="${esc(ip)}" ${f.from === ip ? "selected" : ""}>${esc(devName(d))} · ${esc(ip)}${d.pinned ? "" : " (may change)"}</option>`; }).join("")
    + (f.from && !iotDevs.some(d => (d.pinned || d.ip) === f.from) ? `<option value="${esc(f.from)}" selected>${esc(f.from)} · no device has it now</option>` : "");
  const homeOpts = `<option value="">Any home device</option>` + homes.map(d =>
    `<option value="${esc(d.ip)}" ${f.to === d.ip ? "selected" : ""}>${esc(devName(d))} · ${esc(d.ip)}</option>`).join("")
    + (f.to && !homes.some(d => d.ip === f.to) ? `<option value="${esc(f.to)}" selected>${esc(f.to)} · no device has it now</option>` : "");
  const protoOpts = [["tcp", "TCP"], ["udp", "UDP"], ["any", "Any port"]].map(([v, l]) => `<option value="${v}" ${(f.proto || "tcp") === v ? "selected" : ""}>${l}</option>`).join("");
  return `<h2>What IoT devices can reach<span class="count">${rows.length}</span></h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Exceptions to the IoT network's isolation</h3>
    <p>IoT devices can't open connections to your home network, except as listed here. Replies to connections your own devices open always get through. None of this opens the router itself.</p></div></div>
    ${rows.length ? `<table class="rtable"><thead><tr><th>From (IoT)</th><th>To (home)</th><th>Port</th><th></th></tr></thead><tbody>${rows.join("")}</tbody></table>`
      : `<div class="note">No exceptions: IoT devices can't reach anything on your home network.</div>`}
    <div class="card-b"><h4 class="rh">Add a rule</h4><form class="rform" id="rl-add">
      ${sel("rl-dev", "From", iotOpts)}${sel("rl-to", "To", homeOpts)}${sel("rl-proto", "Protocol", protoOpts)}
      <label class="rf rp"><span>Port</span><div class="input"><input id="rl-port" class="mono" placeholder="e.g. 8123" value="${esc(f.port || "")}" list="rl-ports" autocomplete="off" inputmode="numeric" aria-label="Port or range, e.g. 6001-6010" ${f.proto === "any" || S.rulesBusy ? "disabled" : ""}></div></label>
      <datalist id="rl-ports">${Object.entries(PORT_NAMES).map(([p, n]) => `<option value="${p}">${esc(n)}</option>`).join("")}</datalist>
      <button class="btn primary" ${busy}>Add rule</button></form>
      <div class="meta" style="margin-top:8px;white-space:normal">A port (8123) or a range (6001-6010). Pick devices with a fixed address so the rule keeps pointing at them. Home addresses come from the router's DHCP; reserve one in TP-Link's settings if it must not change.</div></div>
  </div>`;
}

// Who can join the IoT Wi-Fi: lock switch and the "allow new devices" window.
function joinCard(c, iotDevs) {
  const known = iotDevs.filter(d => d.pinned).length;
  const left = Math.max(0, Math.round((c.open_left || 0) - (Date.now() - (S.iotLoadedAt || Date.now())) / 1000));
  const open = c.lock === "on" && left > 0;
  const mmss = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  return `<h2>Who can join</h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Lock the IoT network</h3>
    <p>${c.lock !== "on" ? "Any device with the password can join. Each one keeps its address once it has joined."
      : open ? `<b style="color:var(--warn)">Open to new devices · ${mmss(left)} left.</b> Set up the device in its app now; it is added when it gets an address.`
      : `Only the ${known} known device${known === 1 ? "" : "s"} below can join. Others are turned away, even with the password.`}</p></div>
    <label class="sw"><input type="checkbox" id="iot-lock" ${c.lock === "on" ? "checked" : ""} aria-label="Lock the IoT network"><span></span></label></div>
    ${c.lock === "on" ? `<div class="card-f">${open ? `<button class="btn" data-act="iot-close">Lock now</button>` : `<button class="btn primary" data-act="iot-open">Allow new devices for 10 minutes</button>`}</div>` : ""}
  </div>`;
}
