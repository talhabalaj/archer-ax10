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
      + `<span class="muted" style="font-size:12.5px">Internet</span>` + rowSwitch("internet", d, d.internet, "Internet access")
      + (d.pinned && (!d.online || c.lock === "on") ? `<button class="btn sm" data-act="forget" data-mac="${d.mac}">Remove fixed address</button>` : ""))),
    "Nothing has joined the IoT network yet.")}
  <h2>Who can reach IoT devices</h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Home devices</h3><p>${c.lan_mode === "selected" ? "Only the devices switched on below can open connections to IoT devices." : "Every device on your home network can open connections to IoT devices."}</p></div>
    <div class="seg" id="lanmode"><button data-mode="all" aria-pressed="${c.lan_mode !== "selected"}">All</button><button data-mode="selected" aria-pressed="${c.lan_mode === "selected"}">Selected</button></div></div></div>
  ${c.lan_mode === "selected" ? `<div style="margin-top:12px">${'<div class="list">' + (homes.map(d => simpleRow(d, rowSwitch("allowed", d, d.allowed, "Can reach IoT devices"))).join("") || '<div class="empty">No home devices.</div>') + "</div>"}</div>` : ""}
  ${rulesCard(c, iotDevs)}`;
}

// What IoT devices may open to the home network (iot_allow_lan). Each rule is
// "proto:port", "proto:first-last", either with "@<IoT address>" for one device only.
const PORT_NAMES = { 80: "web page", 443: "web page (HTTPS)", 554: "camera stream (RTSP)", 1400: "Sonos", 1883: "MQTT",
  5353: "device discovery (mDNS)", 8096: "Jellyfin", 8123: "Home Assistant", 8883: "MQTT over TLS", 8899: "inverter link", 32400: "Plex" };
function parseRule(w) {
  const m = /^(tcp|udp):(\d+)(?:[-:](\d+))?(?:@((?:(?:0|[1-9]\d{0,2})\.){3}(?:0|[1-9]\d{0,2})))?$/.exec(w);
  return m ? { proto: m[1], from: +m[2], to: m[3] ? +m[3] : 0, ip: m[4] || "" } : null;
}
function rulesCard(c, iotDevs) {
  const rules = (c.allow_lan || "").split(/\s+/).filter(Boolean);
  const devAt = ip => iotDevs.find(d => d.pinned === ip) || iotDevs.find(d => d.ip === ip);
  const rows = rules.map((w, i) => {
    const r = parseRule(w), d = r && r.ip ? devAt(r.ip) : null;
    const who = !r ? w : !r.ip ? "Any IoT device" : d ? devName(d) : r.ip;
    const port = r && (r.to && r.to !== r.from ? `ports ${r.from}–${r.to}` : `port ${r.from}`);
    const what = r ? `${r.proto.toUpperCase()} ${port}${PORT_NAMES[r.from] && !r.to ? " · " + PORT_NAMES[r.from] : ""}` : "Not understood; it has no effect";
    const where = r && r.ip ? (d ? r.ip + (d.pinned === r.ip ? "" : " (address not fixed)") : r.ip + " · no device has this address now") : "";
    return `<div class="row ${d && !d.online ? "offline" : ""}">
      <div class="av">${ic(d ? connIcon(d) : "iot")}${d ? `<span class="dot ${d.online ? "on" : ""}"></span>` : ""}</div>
      <div style="min-width:0"><div class="nm"><span>${esc(who)}</span></div>
        <div class="meta">${esc([what, where].filter(Boolean).join(" · "))} → your home network</div></div>
      <div class="right"><button class="btn sm" data-act="rl-del" data-rule="${esc(w)}" ${S.rulesBusy ? "disabled" : ""} aria-label="Remove this rule">Remove</button></div></div>`;
  });
  const opts = iotDevs.filter(d => d.pinned || d.ip).map(d => { const ip = d.pinned || d.ip;
    return `<option value="${esc(ip)}" ${S.ruleDev === ip ? "selected" : ""}>${esc(devName(d))} (${esc(ip)})${d.pinned ? "" : " · address not fixed"}</option>`; }).join("");
  return `<h2>What IoT devices can reach<span class="count">${rules.length}</span></h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Exceptions to the IoT network's isolation</h3>
    <p>IoT devices can't open connections to your home network, except for the rules below. Replies to connections your own devices open always get through.</p></div></div>
    ${rows.length ? `<div class="rules">${rows.join("")}</div>` : `<div class="note">No exceptions: IoT devices can't reach anything on your home network.</div>`}
    <div class="card-b"><form class="acadd" id="rl-add">
      <div class="input"><select id="rl-dev" aria-label="Which IoT device" style="width:100%;background:transparent;border:0;color:inherit;font:inherit"><option value="">Any IoT device</option>${opts}</select></div>
      <div class="input short" style="flex:0 0 96px"><select id="rl-proto" aria-label="Protocol" style="width:100%;background:transparent;border:0;color:inherit;font:inherit"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div>
      <div class="input short" style="flex:0 1 190px"><input id="rl-port" class="mono" placeholder="Port, e.g. 8123" list="rl-ports" autocomplete="off" inputmode="numeric" aria-label="Port or range, e.g. 6001-6010"></div>
      <datalist id="rl-ports">${Object.entries(PORT_NAMES).map(([p, n]) => `<option value="${p}">${esc(n)}</option>`).join("")}</datalist>
      <button class="btn primary" ${S.rulesBusy ? "disabled" : ""}>Add rule</button></form>
      <div class="meta" style="margin-top:6px">A port (8123) or a range (6001-6010) on any home device. Pick a device with a fixed address, so the rule keeps pointing at it.</div></div>
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
