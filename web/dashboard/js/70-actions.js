/* ------------------------------------------------------------------ actions */
const findDev = mac => S.devices && S.devices.list.find(d => d.mac === mac);
async function setDevice(mac, field, value) {
  const d = findDev(mac); if (!d) return;
  const before = d[field];
  d[field] = value; render();                                   // optimistic
  try {
    await iot("device", { operation: "write", mac, [field]: field === "name" ? value : (value ? "on" : "off") });
    if (field !== "name") toast(({ internet: value ? "Internet on" : "Internet off", fast: value ? "Full speed on" : "Guest limit applies again", allowed: value ? "Can reach IoT devices" : "Can no longer reach IoT devices" })[field] + " · " + devName(d));
  } catch (e) { d[field] = before; render(); fail(e); }
}
async function setBlocked(mac, on) {
  const d = findDev(mac), D = S.devices; if (!d) return;
  if (on && !await confirmBox(`Block ${devName(d)}?`, "It is disconnected now and can't rejoin. If it uses a private (random) address, it can come back with a new one; changing the Wi-Fi password is the lasting fix.", "Block", true)) return;
  S.busy[mac] = true; render();
  const dashed = mac.replace(/:/g, "-");
  try {
    if (on) {
      if (D.block.mode !== "black") await API.call("/admin/access_control?form=mode", { operation: "write", access_mode: "black" });
      if (D.block.enable !== "on") await API.call("/admin/access_control?form=enable", { operation: "write", enable: "on" });
      if (!d.listed) await API.call("/admin/access_control?form=black_list", { operation: "insert", key: "add", old: "add", index: 0, new: JSON.stringify({ name: devName(d).slice(0, 32), mac: dashed }) });
    } else {
      const list = (await API.call("/admin/access_control?form=black_list", { operation: "load" })).data || [];
      const idx = Array.isArray(list) ? list.findIndex(x => (x.mac || "").toUpperCase() === dashed) : -1;
      if (idx < 0) throw new ApiError("not in the block list");
      await API.call("/admin/access_control?form=black_list", { operation: "remove", key: dashed, index: idx });
      // Last one out: switch Access Control back off, as it was before anything was blocked.
      if (list.length === 1) await API.call("/admin/access_control?form=enable", { operation: "write", enable: "off" });
    }
    toast((on ? "Blocked " : "Unblocked ") + devName(d));
    await loadDevices();
  } catch (e) { fail(e); }
  delete S.busy[mac]; render();
}

document.addEventListener("click", async ev => {
  const t = ev.target;
  const tl = t.closest("[data-tab-link]"); if (tl) { ev.preventDefault(); const r = route(tl.dataset.tabLink); go(r.tab, r.net); return; }
  const wa = t.closest("[data-wauto]"); if (wa) { $id("w-auto").dataset.v = wa.dataset.wauto; markWan(true); return; }
  const sn = t.closest("[data-subnet]"); if (sn) { go("networks", sn.dataset.subnet); return; }
  const f = t.closest("[data-filter]"); if (f) { S.filter = f.dataset.filter; S.open = null; render(); return; }
  const rv = t.closest("[data-reveal]"); if (rv) { S.reveal[rv.dataset.reveal] = !S.reveal[rv.dataset.reveal]; render(); return; }
  const cp = t.closest("[data-copy]"); if (cp) {
    const n = (S.nets || []).find(x => x.id === cp.dataset.copy);
    try { await navigator.clipboard.writeText(n.key); toast("Password copied"); } catch (e) { S.reveal[n.id] = true; render(); toast("Couldn't copy here; the password is shown instead.", true); }
    return;
  }
  const qr = t.closest("[data-qr]"); if (qr) { S.qr = S.qr === qr.dataset.qr ? null : qr.dataset.qr; render(); return; }
  const m = t.closest("[data-mode]"); if (m && S.iot && m.dataset.mode !== S.iot.lan_mode) {
    const base = Object.assign({}, S.iot, { lan_mode: m.dataset.mode });
    try { S.iot = await iot("settings", Object.assign({ operation: "write" }, base)); await loadDevices(); render(); toast(m.dataset.mode === "all" ? "All home devices can reach IoT devices" : "Only selected home devices can reach IoT devices"); }
    catch (e) { fail(e); }
    return;
  }
  const a = t.closest("[data-act]"); if (a) {
    const act = a.dataset.act, mac = a.dataset.mac;
    if (act === "rename") { S.editing = mac; render(); const i = $id("rn"); if (i) { i.focus(); i.select(); } return; }
    if (act === "cancel") { S.editing = null; render(); return; }
    if (act === "block" || act === "unblock") return setBlocked(mac, act === "block");
    if (act === "iot-reset") { delete S.dirty.iot; render(); return; }
    if (act === "g-reset") { delete S.dirty.guest; render(); return; }
    if (act === "iot-save") return saveIot();
    if (act === "g-save") return saveGuest();
    if (act === "w-reset") { delete S.dirty.wan; render(); return; }
    if (act === "w-save") return saveWan();
    if (act === "cap") { S.capEdit = mac; render(); const i = $id("cap-d"); if (i) i.focus(); return; }
    if (act === "cap-cancel") { S.capEdit = null; render(); return; }
    if (act === "iot-open" || act === "iot-close") {
      try { await iot("iot_open", { operation: "write", seconds: act === "iot-open" ? 600 : 0 }); await new Promise(r => setTimeout(r, 1200)); await loadIot(); render();
            toast(act === "iot-open" ? "New devices can join for 10 minutes" : "IoT network locked"); } catch (e) { fail(e); }
      return;
    }
    if (act === "forget") {
      const d = findDev(mac); if (!d) return;
      if (!await confirmBox(`Remove the fixed address of ${devName(d)}?`, S.iot && S.iot.lock === "on" ? "It can no longer join the IoT network until you allow new devices." : "If it joins again it gets a new address.", "Remove fixed address", true)) return;
      try { await iot("device", { operation: "write", mac, pin: "off" }); await loadDevices(); render(); toast(`Fixed address removed: ${devName(d)}`); } catch (e) { fail(e); }
      return;
    }
    if (act === "conns-on") { S.conns = { mac }; render(); watchConns(); return; }
    if (act === "conns-off") { S.conns = null; watchConns(); render(); return; }
    if (act === "cap-remove") return setCap(mac, "");
    if (act === "rl-del") { const gone = a.dataset.rule, list = (S.iot.allow_lan || "").split(/\s+/).filter(Boolean);
      return list.includes(gone) ? saveRules(list.filter(x => x !== gone), `Rule removed: ${gone}`) : undefined; }
    if (act === "nm-save") return saveNames();
    if (act === "nm-reset") { delete S.dirty.names; render(); return; }
    if (act === "nm-add") { const f = readNamesForm(); f.hosts.push({ name: "", ip: "" }); setNamesDraft(f, true); return; }
    if (act === "nm-del") { const f = readNamesForm(); f.hosts.splice(+a.dataset.i, 1); setNamesDraft(f, true); return; }
    if (act === "mesh-toggle") { S.showMesh = !S.showMesh; render(); return; }
    if (act === "off-toggle") { S.showOffline = !S.showOffline; S.open = null; render(); return; }
    if (act === "forget-device") { const d = findDev(mac); return forgetDevices(d ? [d] : []); }
    if (act === "forget-offline") return forgetDevices(shownDevices().filter(d => !d.online && canForget(d)));
    if (act === "ac-allow") { const d = findDev(mac); return acAllow(mac, d && (d.name || d.host)); }
    if (act === "ac-remove") return acRemove(mac);
    if (act === "ac-keep" || act === "ac-unkeep") return acBusy(async () => { await homeAllow(mac, act === "ac-keep" ? "keep" : "unkeep"); toast(act === "ac-keep" ? "Kept: stays allowed however long it is away" : "No longer kept"); });
    if (act === "ac-open" || act === "ac-close") return acBusy(async () => { await iot("home_open", { operation: "write", seconds: act === "ac-open" ? 600 : 0 }); toast(act === "ac-open" ? "New devices can join for 10 minutes" : "Home network locked"); });
  }
  if (t.closest(".detail") || t.closest("input,label,button,a")) return;
  const row = t.closest(".row.click"); if (row) { S.open = S.open === row.dataset.mac ? null : row.dataset.mac; S.editing = null; S.capEdit = null; S.detail = null; S.conns = null; watchConns(); render(); watchDetail(); }
});
document.addEventListener("keydown", ev => {
  const row = ev.target.closest && ev.target.closest(".row.click");
  if (row && (ev.key === "Enter" || ev.key === " ") && ev.target === row) { ev.preventDefault(); row.click(); }
  if (ev.key === "Escape" && S.editing) { S.editing = null; render(); }
});
document.addEventListener("change", ev => {
  const i = ev.target;
  if (i.dataset.field && i.dataset.mac) return setDevice(i.dataset.mac, i.dataset.field, i.checked);
  if (i.id === "iot-lock") return setLock(i.checked);
  if (i.id === "ac-on") return setAllowList(i.checked);
  if (/^nm-/.test(i.id)) return markNames(true);
  if (i.id === "ac-exp") return acBusy(async () => { await iot("home", { operation: "write", expire: i.value }); toast(+i.value ? `Devices away for ${i.value} days are removed` : "Devices are never removed for being away"); });
  if (/^iot-/.test(i.id)) return markIot();
  if (/^g-/.test(i.id)) return markGuest();
  if (/^w-/.test(i.id)) return markWan();
  if (/^nm-/.test(i.id) || i.classList.contains("nm-host")) return markNames();
});
document.addEventListener("toggle", ev => { const e = ev.target; if (!e.classList || !e.classList.contains("addmac")) return; if (e.id === "w-range") S.wRange = e.open; else S.addMac = e.open; }, true);
document.addEventListener("input", ev => {
  const i = ev.target;
  if (i.id === "q") { S.q = i.value; S.open = null; render(); return; }
  if (/^iot-/.test(i.id)) return markIot();
  if (/^g-/.test(i.id)) return markGuest();
  if (/^w-/.test(i.id)) return markWan();
  if (/^nm-/.test(i.id)) return markNames();
});
document.addEventListener("submit", ev => {
  if (ev.target.id === "rl-add") { ev.preventDefault(); return addRule(); }
  if (ev.target.id === "ac-add") {
    ev.preventDefault();
    const raw = $id("ac-mac").value.trim().toUpperCase().replace(/[-.\s]/g, ":");
    const mac = /^[0-9A-F]{12}$/.test(raw.replace(/:/g, "")) ? raw.replace(/:/g, "").match(/../g).join(":") : "";
    if (!mac) return toast("That isn't a MAC address. It looks like AA:BB:CC:DD:EE:FF.", true);
    return acAllow(mac, $id("ac-name").value.trim());
  }
  const cf = ev.target.closest("[data-cap]");
  if (cf) {
    ev.preventDefault();
    const num = v => v.trim() === "" ? 0 : (/^\d+$/.test(v.trim()) ? +v.trim() : NaN);
    const d = num($id("cap-d").value), u = num($id("cap-u").value);
    if (!(d >= 0 && d <= 1000 && u >= 0 && u <= 1000)) return toast("Use whole Mbps from 1 to 1000, or leave a box empty for no cap.", true);
    return setCap(cf.dataset.cap, d || u ? `${d}/${u}` : "");
  }
  const f = ev.target.closest("[data-rename]"); if (!f) return;
  ev.preventDefault();
  const mac = f.dataset.rename, v = $id("rn").value.trim();
  S.editing = null; setDevice(mac, "name", v);
});

/* home allow list (ax10.sh home_sync) */
const MESH_RE = /archer|deco|tp-?link|mesh|extender|repeater/i;
function meshUnits(D) { return D.mesh.filter(m => MESH_RE.test(devName(m))); }
async function acBusy(fn) {
  S.busy.ac = true; render();
  try { await fn(); } catch (e) { fail(e); }
  delete S.busy.ac;
  await new Promise(r => setTimeout(r, 800));                    // let ax10.sh home finish
  try { await loadDevices(); } catch (e) { if (e instanceof AuthError) fail(e); }
  render();
}
const homeAllow = (mac, op, name) => iot("home_allow", Object.assign({ operation: "write", mac, op }, name ? { name } : {}));
function acAllow(mac, name) {
  return acBusy(async () => { await homeAllow(mac, "add", name); toast(`${name || mac} can join the home network`); });
}
async function acRemove(mac) {
  const D = S.devices, d = findDev(mac) || D.mesh.find(m => m.mac === mac), nm = d ? devName(d) : mac;
  if (d && d.this) return toast("That's the device you're using; removing it would lock you out.", true);
  if (D.allowOn && D.white.length <= 1) return toast("That's the last device on the list. Turn the allow list off instead.", true);
  const mesh = (D.white.find(w => w.mac === mac) || {}).mesh || meshUnits(D).some(m => m.mac === mac) || MESH_RE.test(nm);   // for the warning only
  if (!await confirmBox(`Remove ${nm}?`, (mesh ? "This looks like mesh or Wi-Fi equipment; removing it can take the satellite and everything on it offline. " : "")
    + (D.allowOn ? "It is disconnected now and can't rejoin the home network. The guest Wi-Fi still works for it." : "It won't be able to join once the allow list is on."), "Remove", true)) return;
  return acBusy(async () => { await homeAllow(mac, "remove"); toast(`Removed ${nm}`); });
}
async function setAllowList(on) {
  const D = S.devices; if (!D || !D.white) return;
  if (!on) {
    if (!await confirmBox("Turn the allow list off?", "Any device with the password can join the home network again. The list is kept for next time.", "Turn off")) return render();
    return acBusy(async () => { await iot("home", { operation: "write", lock: "off" }); toast("Allow list off"); });
  }
  // Never lock out the device in use or the mesh satellite: pin them first.
  const have = new Set(D.white.map(w => w.mac));
  const must = D.list.filter(d => d.this && !d.onWhite)
    .concat(D.home.mesh_macs.map(m => m.toUpperCase()).filter(m => !have.has(m)).map(m => ({ mac: m, name: "Mesh satellite" })));
  const out = D.list.filter(d => d.online && d.net === "home" && !d.onWhite && !d.this);
  const msg = [`Only the ${D.white.length + must.length} devices on the list can use the home network.`,
    must.length ? `${must.map(devName).join(", ")} ${must.length === 1 ? "is" : "are"} added first so you stay connected.` : "",
    out.length ? `${out.length} connected device${out.length === 1 ? " is" : "s are"} not on the list and will be cut off: ${out.map(devName).join(", ")}.` : ""].filter(Boolean).join(" ");
  if (!await confirmBox("Turn the allow list on?", msg, "Turn on")) return render();
  return acBusy(async () => {
    for (const m of must) await homeAllow(m.mac, "keep", devName(m));
    await iot("home", { operation: "write", lock: "on" });
    toast("Allow list on: only listed devices can use the home network");
  });
}

async function forgetDevices(list) {
  if (!list.length) return;
  const one = list.length === 1, nm = one ? devName(list[0]) : `${list.length} devices`;
  const listed = list.filter(d => d.onWhite).length, online = list.filter(d => d.online).length;
  const text = [(one ? "Its" : "Their") + " name, speed cap and other settings are cleared.",
    listed ? (one ? "It is taken off the home allow list" : `${listed} of them are taken off the home allow list`) + (online && S.devices.allowOn ? ", so it is disconnected from the home network now." : ".") : "",
    list.some(d => d.pinned) ? "An IoT device loses its fixed address and has to be let in again." : "",
    online ? "It stays on this list while it is connected." : (one ? "It leaves this list, and comes back if it reconnects." : "They leave this list, and come back if they reconnect.")].filter(Boolean).join(" ");
  if (!await confirmBox(`Forget ${nm}?`, text, "Forget", true)) return;
  list.forEach(d => { S.busy[d.mac] = true; }); render();
  let done = 0;
  try {
    for (let i = 0; i < list.length; i += 50) {          // the router takes at most 64 at a time
      const part = list.slice(i, i + 50);
      await iot("device", { operation: "write", forget: part.map(d => d.mac).join(",") });
      done += part.length;
    }
    toast(`Forgot ${nm}`);
  } catch (e) {
    if (e instanceof AuthError) fail(e);
    else toast(done ? `Forgot ${done} of ${list.length}; the rest failed. ${e.code || ""}` : `Nothing was forgotten. ${e.code && e.code !== "-1" ? e.code : ""}`, true);
  }
  if (list.some(d => d.mac === S.open)) { S.open = null; watchDetail(); }
  list.forEach(d => { delete S.busy[d.mac]; });
  await new Promise(r => setTimeout(r, 800));
  try { await loadDevices(); } catch (e) { if (e instanceof AuthError) fail(e); }
  render();
}

// IoT -> home rules: saved at once, like the switches.
// One save at a time: each starts from the list the last one returned.
async function saveRules(list, msg) {
  if (S.rulesBusy) return;
  S.rulesBusy = true; render();
  try { S.iot = await iot("settings", Object.assign({ operation: "write" }, S.iot, { allow_lan: list.join(" ") })); S.iotLoadedAt = Date.now(); toast(msg); }
  catch (e) { fail(e); }
  S.rulesBusy = false; render();
}
function addRule() {
  const ip = $id("rl-dev").value, proto = $id("rl-proto").value, port = $id("rl-port").value.trim().replace(/\s*[–:]\s*|\s+-\s+/g, "-");
  const m = /^(\d+)(?:-(\d+))?$/.exec(port), a = m && +m[1], b = m && m[2] ? +m[2] : a;
  if (!m || a < 1 || b > 65535 || b < a) return toast("The port is a number from 1 to 65535, or a range like 6001-6010.", true);
  const rule = `${proto}:${a}${b !== a ? "-" + b : ""}${ip ? "@" + ip : ""}`;
  const list = (S.iot.allow_lan || "").split(/\s+/).filter(Boolean);
  if (list.includes(rule)) return toast("That rule is already there.", true);
  S.ruleDev = ip;
  const d = ip && S.devices && S.devices.list.find(x => x.pinned === ip || x.ip === ip);
  return saveRules(list.concat(rule), `${d ? devName(d) : ip || "Every IoT device"} can now reach ${proto.toUpperCase()} ${b !== a ? `ports ${a}–${b}` : `port ${a}`} on your home network`);
}
async function setLock(on) {
  if (on && S.devices && !S.devices.list.some(d => d.net === "iot" && d.pinned)) { toast("No known IoT devices yet; locking now would keep everything out.", true); render(); return; }
  try {
    S.iot = await iot("settings", Object.assign({ operation: "write" }, S.iot, { lock: on ? "on" : "off" })); S.iotLoadedAt = Date.now();
    render(); toast(on ? "IoT network locked to known devices" : "IoT network unlocked");
  } catch (e) { fail(e); }
}
function readIotForm() {
  return { enable: $id("iot-enable").checked ? "on" : "off", ssid: $id("iot-ssid").value, password: $id("iot-pw").value,
           hidden: $id("iot-hidden").checked ? "on" : "off", lan_mode: S.iot.lan_mode };
}
function markIot() {
  const f = readIotForm(), c = S.iot;
  const same = ["enable", "ssid", "password", "hidden"].every(k => (f[k] || "") === (c[k] || ""));
  const was = !!S.dirty.iot;
  if (same) delete S.dirty.iot; else S.dirty.iot = Object.assign({}, c, f);
  if (was !== !same) render();
}
async function saveIot() {
  const f = S.dirty.iot; if (!f) return;
  if (f.enable === "on" && (f.ssid.length < 1 || f.ssid.length > 32)) return toast("The network name needs 1 to 32 characters.", true);
  if (f.enable === "on" && (f.password.length < 8 || f.password.length > 63)) return toast("The password needs 8 to 63 characters.", true);
  try {
    S.iot = await iot("settings", Object.assign({ operation: "write" }, f, { allow_lan: S.iot.allow_lan, lock: S.iot.lock }));
    delete S.dirty.iot; render(); toast("Saved. IoT devices reconnect in a few seconds.");
    await loadDevices(); render();
  } catch (e) { fail(e); }
}
function readGuestForm() { return { enable: $id("g-enable").checked ? "on" : "off", down: $id("g-down").value.trim(), up: $id("g-up").value.trim() }; }
function markGuest() {
  const f = readGuestForm(), g = S.guest, same = ["enable", "down", "up"].every(k => String(f[k]) === String(g[k]));
  const was = !!S.dirty.guest;
  if (same) delete S.dirty.guest; else S.dirty.guest = f;
  if (was !== !same) render();
}
async function setCap(mac, cap) {
  const d = findDev(mac); if (!d) return;
  try {
    await iot("device", { operation: "write", mac, cap });
    S.capEdit = null;
    toast(cap ? `${devName(d)} capped at ${capText({ down: +cap.split("/")[0], up: +cap.split("/")[1] })}` : `Cap removed · ${devName(d)}`);
    await loadDevices(); render();
  } catch (e) { fail(e); }
}
function readWanForm() {
  const v = (id, k) => $id(id) ? $id(id).value.trim() : (S.dirty.wan || S.shaping)[k] || "";
  return { enable: $id("w-enable").checked ? "on" : "off", down: $id("w-down").value.trim(), up: $id("w-up").value.trim(), prio: $id("w-prio").checked ? "on" : "off", guest_low: $id("w-glow").checked ? "on" : "off",
           auto: $id("w-auto").dataset.v, min_down: v("w-min-d", "min_down"), max_down: v("w-max-d", "max_down"), min_up: v("w-min-u", "min_up"), max_up: v("w-max-u", "max_up") };
}
function markWan(force) {
  const f = readWanForm(), w = S.shaping;
  const same = ["enable", "down", "up", "prio", "guest_low", "auto", "min_down", "max_down", "min_up", "max_up"].every(k => String(f[k]) === String(w[k] || (/^(prio|guest_low|auto)$/.test(k) ? "off" : "")));
  const was = !!S.dirty.wan;
  if (same) delete S.dirty.wan; else S.dirty.wan = Object.assign({}, w, f);
  if (force || was !== !same) render();
}
async function saveWan() {
  const f = S.dirty.wan; if (!f) return;
  const d = +f.down, u = +f.up;
  if (f.enable === "on" && !(d >= 1 && d <= 1000 && u >= 1 && u <= 1000)) return toast("Speeds must be between 1 and 1000 Mbps.", true);
  const rng = ["min_down", "max_down", "min_up", "max_up"].map(k => f[k]);
  if (rng.some(v => v !== "" && !(/^\d+$/.test(v) && +v >= 1 && +v <= 1000))) return toast("The lowest and highest speeds are whole Mbps from 1 to 1000, or empty.", true);
  if ((f.min_down && +f.min_down > d) || (f.max_down && +f.max_down < d) || (f.min_up && +f.min_up > u) || (f.max_up && +f.max_up < u)) return toast("The usual speed has to lie between the lowest and the highest.", true);
  const send = { operation: "write" }; ["enable", "down", "up", "prio", "guest_low", "auto", "min_down", "max_down", "min_up", "max_up"].forEach(k => { send[k] = f[k]; });
  try { S.shaping = await iot("shaping", send); delete S.dirty.wan; render();
    toast(f.enable !== "on" ? "Whole-connection limit off" : (f.auto === "on" ? `Automatic limit on, starting at ${d}↓ ${u}↑ Mbps` : `Whole connection capped at ${d}↓ ${u}↑ Mbps`) + (f.prio === "on" ? ", calls and games first" : "") + (f.guest_low === "on" ? ", guests last" : "")); }
  catch (e) { fail(e); }
}
async function saveGuest() {
  const f = S.dirty.guest; if (!f) return;
  const d = +f.down, u = +f.up;
  if (f.enable === "on" && !(d >= 1 && d <= 1000 && u >= 1 && u <= 1000)) return toast("Speeds must be between 1 and 1000 Mbps.", true);
  try { S.guest = await iot("guest_settings", Object.assign({ operation: "write" }, f)); delete S.dirty.guest; await loadDevices(); render(); toast("Guest limit saved"); }
  catch (e) { fail(e); }
}

