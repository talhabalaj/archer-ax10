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
      <div class="field"><label for="iot-allow">IoT → home exceptions</label><div class="input"><input id="iot-allow" class="mono" value="${esc(f.allow_lan)}" placeholder="tcp:8899@192.168.50.10"></div>
        <div class="help">Connections IoT devices may open to your home network. Space-separated, e.g. tcp:8899@192.168.50.10</div></div>
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
  ${c.lan_mode === "selected" ? `<div style="margin-top:12px">${'<div class="list">' + (homes.map(d => simpleRow(d, rowSwitch("allowed", d, d.allowed, "Can reach IoT devices"))).join("") || '<div class="empty">No home devices.</div>') + "</div>"}</div>` : ""}`;
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
