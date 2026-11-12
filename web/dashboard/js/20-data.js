/* ------------------------------------------------------------------ data */
// Our list, checked against the stock client list (the same one as the TP-Link
// network map). For home and guest devices the stock list decides who is online: it
// knows clients behind the mesh satellite, and leaves out the satellite itself.
// IoT devices are ours only; TP-Link doesn't see that network.
const BAND = { "2.4G": "2.4 GHz", "5G": "5 GHz", "5G_2": "5 GHz" };
async function loadDevices() {
  const [r, stock, home] = await Promise.all([iot("devices"),
    API.call("/admin/access_control?form=black_devices", { operation: "load" }).then(x => x.data).catch(() => null),
    iot("home").catch(() => null)]);
  r.mesh = [];
  if (Array.isArray(stock)) {
    const by = {};
    stock.forEach(x => { if (x.mac) by[x.mac.toUpperCase().replace(/-/g, ":")] = x; });
    const keep = d => d.name || d.blocked || d.fast || d.allowed || !d.internet;   // has a setting
    r.list = r.list.filter(d => {
      if (d.net === "iot") return true;
      // Guests on our own guest Wi-Fi radio: TP-Link's list leaves them out while
      // Access Control is on with guests exempt, so our radio's word counts.
      if (d.net === "guest" && d.online && !by[d.mac]) return true;
      const x = by[d.mac];
      if (!x) {
        if (d.online && !keep(d)) { r.mesh.push(d); return false; }   // mesh equipment, not a client
        d.online = false; d.where = ""; return true;
      }
      if (!d.host && x.name) d.host = x.name;
      if (x.guest === "GUEST") d.net = "guest";
      if (!d.ip && x.ipaddr) d.ip = x.ipaddr;
      if (!d.online || !d.where || d.where === "Online") {
        d.where = x.conn_type === "wired" ? "Wired" : `Wi-Fi (${BAND[x.raw_conn_type] || x.raw_conn_type || "?"})`;
      }
      d.online = true; return true;
    });
  }
  // A device on the block list is only blocked while Access Control is on, in block-list mode.
  const live = r.block.enable === "on" && r.block.mode === "black";
  r.list.forEach(d => { d.listed = d.blocked; d.blocked = d.blocked && live; });
  // Our home allow list (ax10.sh home_sync).
  // The router's JSON encoder turns an empty list into {}.
  if (home) { ["list", "dropped", "mesh_macs"].forEach(k => { if (!Array.isArray(home[k])) home[k] = []; }); }
  r.home = home; S.homeAt = Date.now();
  r.white = home ? home.list.map(x => ({ mac: x.mac.toUpperCase(), seen: x.seen, keep: x.keep, name: x.name || "", mesh: !!x.mesh })) : null;
  r.allowOn = !!home && home.lock === "on";
  const wl = new Set((r.white || []).map(x => x.mac));
  r.list.forEach(d => { d.onWhite = wl.has(d.mac); });
  const prev = S.devices && S.devices.byMac, now = {};
  r.list.forEach(d => {
    now[d.mac] = { down: d.down, up: d.up };
    const p = prev && prev[d.mac];
    d.live = p ? rates(p, d, S.devices.t, r.t) : null;
  });
  r.byMac = now;
  // Live traffic by network, for the "Right now" graph (last ~3 minutes).
  if (prev) {
    const f = { home: 0, guest: 0, iot: 0, up: 0, mesh: 0 };
    r.list.forEach(d => { if (!d.online) return; if (d.live) { f[d.net] += d.live.down; f.up += d.live.up; } else if (/^Mesh/.test(d.where)) f.mesh++; });
    S.flow = (S.flow || []).concat([f]).slice(-36);
  }
  S.devices = r;
}
async function loadSummary() {
  const [s, inet] = await Promise.all([iot("summary"), API.call("/admin/status?form=internet").then(r => r.data).catch(() => null)]);
  S.summary = Object.assign({}, s, { internet: inet ? inet.internet_status : (s.wan_up ? "connected" : "disconnected") });
}
async function loadIot() { S.iot = await iot("settings"); S.iotLoadedAt = Date.now(); }
async function loadGuest() { S.guest = await iot("guest_settings"); }
async function loadShaping() { S.shaping = await iot("shaping"); }
async function loadLoad() { const l = await iot("load"); if (!Array.isArray(l.buckets)) l.buckets = []; S.load = l; }
async function loadUsage() { const u = await iot("usage"); ["days", "months", "devices"].forEach(k => { if (!Array.isArray(u[k])) u[k] = []; }); S.usage = u; }
async function loadNames() { const n = await iot("names"); if (!Array.isArray(n.hosts)) n.hosts = []; S.names = n; }
async function loadWifi() {
  const get = f => API.call("/admin/wireless?form=" + f).then(r => r.data).catch(() => null);
  const [w2, w5, g2, g5, sc] = await Promise.all([get("wireless_2g"), get("wireless_5g"), get("guest_2g"), get("guest_5g"), get("smart_connect")]);
  if (!S.iot) await loadIot();
  S.wifi = { w2, w5, g2, g5, smart: sc && sc.smart_enable === "on" };
}
const NEEDS = { devices: [loadDevices, loadSummary], networks: [loadWifi, loadDevices, loadIot, loadGuest, loadSummary], internet: [loadDevices, loadShaping, loadNames, loadUsage, loadLoad, loadSummary] };
async function refresh(quiet) {
  const tab = S.tab;
  try { await Promise.all(NEEDS[tab].map(f => f())); if (tab === S.tab) render(); }
  catch (e) { if (!quiet || e instanceof AuthError) fail(e); }
}
let timer = null;
function startPolling() {
  clearInterval(timer);
  timer = setInterval(() => {
    // Internet page: only the "Now ..." line of the automatic limit moves; a full
    // refresh would fight with what is being typed.
    if (S.tab === "internet" && !document.hidden && API.has() && S.shaping && S.shaping.auto === "on") {
      iot("shaping").then(w => { ["now_down", "now_up", "now_extra", "now_ceil_down", "now_ceil_up"].forEach(k => { S.shaping[k] = w[k]; }); const el = $id("w-now"); if (el) el.innerHTML = autoNow(S.shaping); }).catch(() => {});
    }
    if (document.hidden || !API.has() || S.editing || S.capEdit || S.tab === "networks" || S.tab === "internet" || Object.keys(S.dirty).length) return;
    refresh(true);
  }, 5000);
}
window.addEventListener("hashchange", () => { if (!API.has()) return; const r = route(location.hash); go(r.tab, r.net); });
document.addEventListener("visibilitychange", () => { if (!document.hidden && API.has()) refresh(true); });

