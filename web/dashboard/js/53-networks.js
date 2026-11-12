// The router's Wi-Fi networks, from the stock settings (S.wifi).
function buildNets() {
  const W = S.wifi, nets = [];
  if (!W) return nets;
  if (W.w2) {
    if (W.smart || (W.w5 && W.w5.ssid === W.w2.ssid && W.w5.psk_key === W.w2.psk_key))
      nets.push({ id: "main", ssid: W.w2.ssid, band: "2.4 and 5 GHz, Smart Connect", key: W.w2.psk_key, on: W.w2.enable === "on", edit: "wirelessSettingsAdv" });
    else {
      nets.push({ id: "w2", ssid: W.w2.ssid, band: "2.4 GHz", key: W.w2.psk_key, on: W.w2.enable === "on", edit: "wirelessSettingsAdv" });
      if (W.w5) nets.push({ id: "w5", ssid: W.w5.ssid, band: "5 GHz", key: W.w5.psk_key, on: W.w5.enable === "on", edit: "wirelessSettingsAdv" });
    }
  }
  if (W.g2) nets.push({ id: "g2", ssid: W.g2.ssid, band: "2.4 GHz", key: W.g2.psk_key, on: W.g2.enable === "on", edit: "guestNetworkAdv" });
  if (W.g5) nets.push({ id: "g5", ssid: W.g5.ssid, band: "5 GHz", key: W.g5.psk_key, on: W.g5.enable === "on", edit: "guestNetworkAdv" });
  if (S.iot) nets.push({ id: "iotnet", ssid: S.iot.ssid, band: "2.4 GHz", key: S.iot.password, on: S.iot.enable === "on" });
  return nets;
}
function netCards(ids) {
  const nets = (S.nets = buildNets()).filter(n => ids.includes(n.id));
  if (!S.wifi) return `<div class="nets">${'<div class="card net"><span class="spin"></span></div>'.repeat(ids.length > 1 ? 2 : 1)}</div>`;
  return `<div class="nets">${nets.map(n => `<div class="card net ${n.on ? "" : "off-net"}">
      <div class="t">${ic(n.id === "iotnet" ? "iot" : /^g/.test(n.id) ? "guest" : "wifi")}<b>${esc(n.ssid)}</b><span class="spacer"></span>${n.on ? '<span class="tag you">On</span>' : '<span class="tag">Off</span>'}</div>
      <div class="band">${esc(n.band)}</div>
      ${n.key ? `<div class="pw"><code>${S.reveal[n.id] ? esc(n.key) : "•".repeat(Math.min(n.key.length, 14))}</code>
        <button class="iconbtn" data-reveal="${n.id}" aria-label="Show password" title="Show password">${ic("eye")}</button>
        <button class="iconbtn" data-copy="${n.id}" aria-label="Copy password" title="Copy password">${ic("copy")}</button>
        <button class="iconbtn" data-qr="${n.id}" aria-label="Show QR code" title="QR code to join">${ic("qr")}</button></div>` : '<div class="muted" style="font-size:13px">Open network</div>'}
      ${S.qr === n.id ? `<div class="qr" id="qrbox"></div>` : ""}
      ${n.edit ? `<div style="margin-top:12px;font-size:13px"><a href="${FULL}">Change name or password in TP-Link settings ${ic("ext").replace("<svg", '<svg style="width:13px;height:13px;vertical-align:-2px"')}</a></div>` : ""}
    </div>`).join("")}</div>`;
}

// Networks: one page per network, with everything about it in one place.
function viewNetworks() {
  const D = S.devices, on = k => D ? D.list.filter(d => d.online && d.net === k).length : 0;
  const seg = `<div class="seg" role="tablist" aria-label="Network">${SUBNETS.map(([k, l]) =>
    `<button data-subnet="${k}" role="tab" aria-pressed="${S.net === k}" aria-selected="${S.net === k}">${l}<span class="n">${on(k)}</span></button>`).join("")}</div>`;
  const sub = { home: "Your own devices. Only the ones you allow can join.", guest: "For visitors: internet only, kept away from your devices.", iot: "For smart devices: cut off from your home devices and this router." }[S.net];
  const body = S.net === "guest" ? guestPage() : S.net === "iot" ? viewIot() : netCards(["main", "w2", "w5"]) + accessCard();
  return pageHead("Networks", sub, seg) + body;
}
function guestPage() {
  const g = S.guest, D = S.devices;
  if (!g || !D) return netCards(["g2", "g5"]) + skel(2);
  const f = S.dirty.guest || g, isDirty = !!S.dirty.guest;
  const guests = sortDevices(D.list.filter(d => d.net === "guest" || d.fast));
  return netCards(["g2", "g5"]) + `<h2>Speed for each guest</h2>
  <div class="card">
    <div class="card-h"><div style="flex:1"><h3>Limit each guest</h3><p>Caps every device on the guest Wi-Fi. A device's own speed cap wins over this.</p></div>
      <label class="sw"><input type="checkbox" id="g-enable" ${f.enable === "on" ? "checked" : ""} aria-label="Guest speed limit on"><span></span></label></div>
    <div class="card-b">
      <div class="field"><label for="g-down">Download</label><div class="input short"><input id="g-down" inputmode="numeric" value="${esc(f.down)}"><span class="unit">Mbps</span></div></div>
      <div class="field"><label for="g-up">Upload</label><div class="input short"><input id="g-up" inputmode="numeric" value="${esc(f.up)}"><span class="unit">Mbps</span></div></div>
    </div>
    ${isDirty ? `<div class="card-f"><button class="btn" data-act="g-reset">Discard</button><button class="btn primary" data-act="g-save">Save changes</button></div>` : ""}
  </div>
  ${sectionList("Guests", guests.map(d => simpleRow(d, g.enable === "on" ? `<span class="muted" style="font-size:13px">Full speed</span>` + rowSwitch("fast", d, d.fast, "Full speed") : "")), "No one is on the guest Wi-Fi.")}
  <p class="muted" style="font-size:13px;margin:12px 2px 0;max-width:72ch">To let a guest use the home Wi-Fi, open them on the Devices page and choose Allow on home Wi-Fi. While they stay on the guest Wi-Fi, they see a page with the home Wi-Fi name and password.</p>`;
}

// Who can join the home network: our own allow list (ax10.sh home_sync). The home
// Wi-Fi radios take only listed devices; unlisted ones behind the mesh satellite or
// on a cable are cut off by the firewall. The guest Wi-Fi is never touched.
const ago = (now, t) => { if (!t) return "Not seen yet"; const s = Math.max(0, now - t);
  return s < 120 ? "Seen just now" : s < 3600 ? `Seen ${Math.round(s / 60)} min ago` : s < 86400 ? `Seen ${Math.round(s / 3600)} h ago` : `Seen ${Math.round(s / 86400)} days ago`; };
function accessCard() {
  const D = S.devices, H = D && D.home;
  if (!D) return `<h2>Who can join the home network</h2>` + skel(3);
  if (!H) return `<h2>Who can join the home network</h2><div class="card"><div class="card-b" style="padding:18px">Couldn't read the allow list.</div></div>`;
  const on = D.allowOn, ssid = (S.wifi && S.wifi.w2 && S.wifi.w2.ssid) || "the home Wi-Fi";
  const byMac = {}; D.list.concat(D.mesh).forEach(d => { byMac[d.mac] = d; });
  const busy = S.busy.ac, now = H.now || Math.floor(Date.now() / 1000);
  const left = Math.max(0, Math.round((H.open_left || 0) - (Date.now() - (S.homeAt || Date.now())) / 1000));
  const open = on && left > 0, mmss = x => `${Math.floor(x / 60)}:${String(x % 60).padStart(2, "0")}`;
  const allowed = D.white.map(x => {
    const d = byMac[x.mac], mesh = x.mesh, live = d && d.online || mesh;
    const nm = d ? devName(d) : x.name || x.mac;
    const meta = [x.mac, mesh ? "Mesh satellite" : d && d.online ? whereText(d) : ago(now, x.seen)].join(", ");
    const expiring = +H.expire > 0;
    const right = (expiring && x.keep ? '<span class="tag" title="Stays allowed however long it is away">Kept</span>' : "")
      + (d && d.this ? '<span class="tag you">This device</span>'
        : `${expiring ? `<button class="btn sm" data-act="ac-${x.keep ? "unkeep" : "keep"}" data-mac="${x.mac}" ${busy ? "disabled" : ""} title="${x.keep ? "Remove it after the same absence as the others" : "Keep it allowed however long it is away"}">${x.keep ? "Stop keeping" : "Keep"}</button>` : ""}
           <button class="btn sm" data-act="ac-remove" data-mac="${x.mac}" ${busy ? "disabled" : ""}>Remove</button>`);
    return { live, nm, mesh, html: `<div class="row ${live ? "" : "offline"}">
      <div class="av">${ic(d && !mesh ? connIcon(d) : mesh ? "mesh" : "wifi")}<span class="dot ${live ? "on" : ""}"></span></div>
      <div style="min-width:0"><div class="nm"><span>${esc(nm)}</span>${d && d.net === "guest" ? '<span class="tag guest">On guest now</span>' : ""}</div><div class="meta mono">${esc(meta)}</div></div>
      <div class="right">${right}</div></div>` };
  }).sort((a, b) => (b.live - a.live) || a.nm.localeCompare(b.nm, undefined, { sensitivity: "base" }));
  // The mesh satellite's entries fold into one line; Show brings them back, so
  // nothing on the list is ever out of reach.
  const meshRows = allowed.filter(x => x.mesh), devRows = allowed.filter(x => !x.mesh).map(x => x.html);
  const meshLine = meshRows.length ? `<div class="row"><div class="av">${ic("mesh")}<span class="dot on"></span></div>
      <div style="min-width:0"><div class="nm"><span>Mesh satellite</span></div><div class="meta">${meshRows.length} address${meshRows.length === 1 ? "" : "es"}, kept allowed so the satellite stays connected</div></div>
      <div class="right"><button class="btn sm" data-act="mesh-toggle" aria-expanded="${!!S.showMesh}">${S.showMesh ? "Hide" : "Show"}</button></div></div>${S.showMesh ? meshRows.map(x => x.html).join("") : ""}` : "";
  const listRows = devRows.concat(meshLine ? [meshLine] : []);
  const others = sortDevices(D.list.filter(d => d.net !== "iot" && !d.onWhite)).map(d => `<div class="row ${d.online ? "" : "offline"}">
    <div class="av">${ic(connIcon(d))}<span class="dot ${d.online ? "on" : ""}"></span></div>
    <div style="min-width:0"><div class="nm"><span>${esc(devName(d))}</span>${d.net === "guest" ? '<span class="tag guest">Guest</span>' : ""}${isPrivateMac(d.mac) ? '<span class="tag" title="Private (random) address: the phone may show up with a new one later">Private address</span>' : ""}${(H.dropped || []).includes(d.mac.toLowerCase()) ? '<span class="tag blocked">Cut off</span>' : ""}</div>
      <div class="meta mono">${esc([d.mac, d.ip, whereText(d)].filter(Boolean).join(", "))}</div></div>
    <div class="right"><button class="btn sm" data-act="ac-allow" data-mac="${d.mac}" ${busy ? "disabled" : ""}>Allow</button></div></div>`);
  const exp = [[0, "Never"], [7, "After 7 days away"], [14, "After 14 days away"], [30, "After 30 days away"], [90, "After 90 days away"]];
  return `<h2>Who can join the home network</h2>
  <div class="card"><div class="card-h"><div style="flex:1"><h3>Only allowed devices</h3>
    <p>${!on ? "Off. Any device with the password can join. You can build the list first, then turn this on."
      : open ? `<b style="color:var(--warn)">Open to new devices · ${mmss(left)} left.</b> Connect the new device now; it is added as soon as it shows up.`
      : `Only the ${devRows.length} devices below${meshRows.length ? " and the mesh satellite" : ""} can use ${esc(ssid)}, on Wi-Fi, through the mesh satellite or on a cable. Others are turned away, even with the password. The guest Wi-Fi still lets in anyone with its password.`}</p></div>
    ${busy ? '<span class="spin"></span>' : ""}<label class="sw"><input type="checkbox" id="ac-on" ${on ? "checked" : ""} ${busy ? "disabled" : ""} aria-label="Only allowed devices can join the home network"><span></span></label></div>
    <div class="card-b"><div class="field"><label for="ac-exp">Remove home access after absence</label><div class="input short" style="max-width:240px"><select id="ac-exp" style="width:100%;background:transparent;border:0;color:inherit;font:inherit">${exp.map(([v, l]) => `<option value="${v}" ${+H.expire === v ? "selected" : ""}>${l}</option>`).join("")}</select></div>
      <div class="help">A device not seen for this long is taken off the list. This device and the mesh satellite always stay${+H.expire > 0 ? "; use Keep on others that should too" : ""}.</div></div>
      <details class="addmac" ${S.addMac ? "open" : ""}><summary>Add a device by its MAC address</summary>
        <form class="acadd" id="ac-add"><div class="input"><input id="ac-name" maxlength="32" placeholder="Name" autocomplete="off"></div>
        <div class="input"><input id="ac-mac" class="mono" placeholder="MAC, e.g. AA:BB:CC:DD:EE:FF" autocomplete="off"></div>
        <button class="btn" ${busy ? "disabled" : ""}>Add</button></form></details></div>
    ${on ? `<div class="card-f">${open ? `<button class="btn" data-act="ac-close">Lock now</button>` : `<button class="btn primary" data-act="ac-open">Allow new devices for 10 minutes</button>`}</div>` : ""}</div>
  ${sectionList("Allowed", listRows, "The list is empty.").replace(`<span class="count">${listRows.length}</span>`, `<span class="count">${devRows.length}</span>`)}
  ${sectionList("Not on the list", others, "Every device seen is on the list.")}`;
}

