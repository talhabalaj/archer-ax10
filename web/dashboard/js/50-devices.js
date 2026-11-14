/* ------------------------------------------------------------------ views */
function render() {
  document.querySelectorAll("#tabs [data-tab]").forEach(b => b.dataset.tab === S.tab ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current"));
  const v = $id("view"); if (!v) return;
  const focus = document.activeElement && document.activeElement.id;
  const caret = focus && document.activeElement.selectionStart;
  v.innerHTML = ({ devices: viewDevices, networks: viewNetworks, internet: viewInternet })[S.tab]();
  if (focus && $id(focus)) { const el = $id(focus); el.focus(); try { if (caret != null) el.setSelectionRange(caret, caret); } catch (x) {} }
  if (S.qr) drawQr();
  renderSide();
}
const skel = n => `<div class="list">${'<div class="sk"></div>'.repeat(n)}</div>`;
function sortDevices(list) {
  return list.slice().sort((a, b) => (b.this - a.this) || (b.online - a.online) || devName(a).localeCompare(devName(b), undefined, { sensitivity: "base" }));
}

function viewDevices() {
  const D = S.devices;
  const online = D ? D.list.filter(d => d.online) : [];
  const sub = D ? [`${online.length} online`, online.filter(d => d.net === "guest").length ? `${online.filter(d => d.net === "guest").length} on guest Wi-Fi` : "",
    online.filter(d => d.net === "iot").length ? `${online.filter(d => d.net === "iot").length} IoT` : ""].filter(Boolean).join(", ") : "Loading…";
  if (!D) return pageHead("Devices", sub) + skel(6);
  const counts = { all: D.list.length, home: 0, guest: 0, iot: 0, blocked: 0 };
  D.list.forEach(d => { counts[d.net]++; if (d.blocked) counts.blocked++; });
  const q = S.q.trim().toLowerCase();
  const shown = shownDevices();
  const filters = [["all", "All"], ["home", "Home"], ["guest", "Guest"], ["iot", "IoT"], ["blocked", "Blocked"]]
    .filter(([k]) => k === "all" || counts[k])
    .map(([k, l]) => `<button data-filter="${k}" aria-pressed="${S.filter === k}">${l}<span class="n">${counts[k]}</span></button>`).join("");
  const tools = `<div class="toolbar">
      <div class="input search">${ic("search")}<input id="q" placeholder="Search name, IP or MAC" value="${esc(S.q)}" autocomplete="off" aria-label="Search devices" style="margin-left:8px"></div>
      <div class="seg" id="flt">${filters}</div></div>`;
  return pageHead("Devices", sub, tools) + nowCard() + deviceGroups(shown, !!q);
}
// The live traffic band: totals now, and a stacked graph by network.
const NETS = [["home", "Home"], ["guest", "Guest"], ["iot", "IoT"]];
function nowCard() {
  const F = S.flow || [], last = F[F.length - 1];
  const down = last ? last.home + last.guest + last.iot : null, up = last ? last.up : null;
  const big = v => { if (v == null) return "–"; const t = fmtRate(v).split(" "); return `${t[0]}<small>${t[1]}</small>`; };
  const W = 600, H = 64, n = 36, max = Math.max(1e5, ...F.map(f => f.home + f.guest + f.iot));
  const x = i => (W * i) / Math.max(1, F.length - 1), y = v => H - (v / max) * (H - 4);
  let paths = "";
  if (F.length > 1) {
    const base = F.map(() => 0);
    NETS.forEach(([k]) => {
      const top = F.map((f, i) => base[i] + f[k]);
      const d = "M" + top.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("L") + "L" + base.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).reverse().join("L") + "Z";
      paths += `<path d="${d}" style="fill:var(--${k})" opacity="${k === "home" ? .85 : .9}"/>`;
      top.forEach((v, i) => { base[i] = v; });
    });
  }
  const legend = NETS.map(([k, l]) => `<span><i style="background:var(--${k})"></i>${l} ${last ? fmtRate(last[k]) : "–"}</span>`).join("")
    + (last && last.mesh ? `<span>${last.mesh} on the mesh satellite not counted</span>` : "");
  return `<section class="now" aria-label="Traffic right now">
    <div class="nums"><div class="num"><span>Download now</span><b>${big(down)}</b></div><div class="num"><span>Upload now</span><b>${big(up)}</b></div></div>
    <svg class="flow" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Download over the last 3 minutes">${paths || `<line x1="0" y1="${H - 1}" x2="${W}" y2="${H - 1}" style="stroke:var(--line-2)"/>`}</svg>
    <div class="legend">${legend}</div></section>`;
}
// The devices matching the current filter and search: what the list shows, and
// exactly what "Forget all offline" acts on.
function shownDevices() {
  const D = S.devices, q = S.q.trim().toLowerCase();
  return sortDevices(D.list).filter(d =>
    (S.filter === "all" || (S.filter === "blocked" ? d.blocked : d.net === S.filter)) &&
    (!q || [devName(d), d.host, d.ip, d.mac, d.where].join(" ").toLowerCase().includes(q)));
}
// Online devices first; offline ones folded away (shown while searching), with a
// way to forget the old ones.
function deviceGroups(shown, searching) {
  if (!shown.length) return '<div class="list" id="dl"><div class="empty">No devices match.</div></div>';
  const on = shown.filter(d => d.online), off = shown.filter(d => !d.online);
  const open = searching || S.showOffline;
  const forgettable = off.filter(canForget);
  const scope = S.filter !== "all" || searching ? "shown here" : "offline";
  const offHead = off.length ? `<div class="grouph">${searching ? `<span class="linkbtn" style="cursor:default">Offline<span class="count">${off.length}</span></span>`
      : `<button class="linkbtn" data-act="off-toggle" aria-expanded="${open}">${ic("chev", "chev" + (open ? " up" : ""))}Offline<span class="count">${off.length}</span></button>`}
    ${open && forgettable.length > 1 ? `<button class="btn sm" data-act="forget-offline">Forget the ${forgettable.length} ${scope}…</button>` : ""}</div>` : "";
  const thead = '<div class="thead" aria-hidden="true"><span></span><span>Device</span><span>Network</span><span>Connection</span><span class="c-addr">Address</span><span class="r">Now</span><span></span></div>';
  return `<div class="list" id="dl">${thead}${on.length ? on.map(deviceRow).join("") : '<div class="empty">Nothing online right now.</div>'}</div>
    ${offHead}${off.length && open ? `<div class="list">${off.map(deviceRow).join("")}</div>` : ""}`;
}
// Forget: not the device in use, and not one pinned on the allow list.
const canForget = d => !d.this && !(S.devices && (S.devices.white || []).some(w => w.mac === d.mac && w.keep));

const NET_NAME = { home: "Home", guest: "Guest", iot: "IoT" };
const rateShort = v => v < 1000 ? "&lt;1 kbps" : fmtRate(v);
function deviceRow(d) {
  const open = S.open === d.mac, D = S.devices;
  const tags = [d.this && '<span class="tag you">This device</span>', d.blocked && '<span class="tag blocked">Blocked</span>',
    d.online && D.allowOn && d.net === "home" && !d.onWhite && '<span class="tag no" title="Not on the home Wi-Fi allow list">Not allowed</span>',
    d.net === "guest" && d.online && d.onWhite && D.allowOn && '<span class="tag cap" title="On the home allow list: it sees a page with the home Wi-Fi password instead of internet">Sent to home Wi-Fi</span>',
    d.net === "iot" && !d.internet && '<span class="tag">No internet</span>', d.net === "iot" && d.reach && '<span class="tag cap" title="Can open connections to your home devices on any port">Reaches home</span>', d.net === "guest" && d.fast && !d.cap && '<span class="tag">Full speed</span>',
    d.cap && `<span class="tag cap" title="Speed cap">${capText(d.cap)}</span>`].filter(Boolean).join("");
  const conn = d.online ? `${esc(whereText(d))}${d.rssi ? sigBars(d.rssi) : ""}` : esc(d.seen ? ago(D.now, d.seen) : "Offline");
  const mob = [NET_NAME[d.net], d.online ? whereText(d) : (d.seen ? ago(D.now, d.seen) : "Offline"), d.ip].filter(Boolean).join(", ");
  const live = d.online && d.live && (d.live.down >= 1000 || d.live.up >= 1000)
    ? `<div class="rate"><b>↓ ${rateShort(d.live.down)}</b><br>↑ ${rateShort(d.live.up)}</div>` : "";
  return `<div class="row dev click ${d.online ? "" : "offline"} ${open ? "open" : ""}" data-mac="${d.mac}" tabindex="0" role="button" aria-expanded="${open}">
      <div class="av">${ic(connIcon(d))}<span class="dot ${d.online ? "on" : ""}"></span></div>
      <div style="min-width:0"><div class="nm"><span>${esc(devName(d))}</span>${tags}</div><div class="meta m">${esc(mob)}</div></div>
      <div class="cell c-net"><span class="netpill ${d.net}">${NET_NAME[d.net]}</span></div>
      <div class="cell c-conn" title="${d.online && d.rssi ? `${d.rssi} dBm, ${sigWord(d.rssi).toLowerCase()} signal` : ""}">${conn}</div>
      <div class="cell c-addr">${esc(d.ip || "")}</div>
      <div class="cell r">${live}</div>
      ${ic("chev", "chev")}
    </div>${open ? deviceDetail(d) : ""}`;
}

// "5↓ 2↑" for a cap of 5 Mbps down, 2 up; 0 means not capped that way.
const capText = c => [c.down ? `${c.down}↓` : "", c.up ? `${c.up}↑` : ""].filter(Boolean).join(" ") + " Mbps";
function effectiveCap(d) {
  const D = S.devices;
  if (d.cap) return { text: capText(d.cap), why: "Speed cap set for this device" };
  if (d.net === "guest" && D.guest_limit && !d.fast) return { text: capText({ down: D.guest_down, up: D.guest_up }), why: "Guest limit" };
  return null;
}
function capEditor(d) {
  const c = d.cap || { down: "", up: "" };
  return `<form class="capform" data-cap="${d.mac}">
    <div class="input short"><input id="cap-d" inputmode="numeric" placeholder="none" value="${c.down || ""}" aria-label="Download cap"><span class="unit">↓ Mbps</span></div>
    <div class="input short"><input id="cap-u" inputmode="numeric" placeholder="none" value="${c.up || ""}" aria-label="Upload cap"><span class="unit">↑ Mbps</span></div>
    <button class="btn sm primary">Save</button><button type="button" class="btn sm" data-act="cap-cancel">Cancel</button></form>`;
}
function deviceDetail(d) {
  const D = S.devices, busy = S.busy[d.mac];
  const toggles = [];
  if (d.net === "iot") toggles.push(toggle("internet", d, d.internet, "Internet access"), toggle("reach", d, d.reach, "Can reach home devices (any port)"));
  if (d.net === "guest" && D.guest_limit) toggles.push(toggle("fast", d, d.fast, "Full speed (skip guest limit)"));
  if (d.net === "home" && D.iot_enabled && D.lan_mode === "selected") toggles.push(toggle("allowed", d, d.allowed, "Can reach IoT devices"));
  const canBlock = !d.this;
  return `<div class="detail">
    ${S.editing === d.mac ? `<form class="rename" data-rename="${d.mac}"><div class="input"><input id="rn" value="${esc(d.name || d.host)}" maxlength="40" placeholder="Name"></div>
      <button class="btn sm primary">Save</button><button type="button" class="btn sm" data-act="cancel">Cancel</button></form>` : ""}
    ${S.capEdit === d.mac ? capEditor(d) : ""}
    <div class="acts">${toggles.join("")}
      ${S.editing === d.mac ? "" : `<button class="btn sm" data-act="rename" data-mac="${d.mac}">Rename</button>`}
      ${d.net !== "iot" && S.capEdit !== d.mac ? `<button class="btn sm" data-act="cap" data-mac="${d.mac}">${d.cap ? "Change speed cap" : "Cap speed"}</button>` : ""}
      ${d.cap && S.capEdit !== d.mac ? `<button class="btn sm" data-act="cap-remove" data-mac="${d.mac}">Remove cap</button>` : ""}
      ${d.net !== "iot" && d.pinned ? `<button class="btn sm" data-act="forget" data-mac="${d.mac}" title="Left over from when it was on the IoT network">Remove old IoT address (${esc(d.pinned)})</button>` : ""}
      ${d.net !== "iot" && D.white ? (d.onWhite
        ? (d.this ? "" : `<button class="btn sm" data-act="ac-remove" data-mac="${d.mac}">Remove from home Wi-Fi</button>`)
        : `<button class="btn sm" data-act="ac-allow" data-mac="${d.mac}">Allow on home Wi-Fi</button>`) : ""}
      ${canBlock ? `<button class="btn sm ${d.blocked ? "" : "danger"}" data-act="${d.blocked ? "unblock" : "block"}" data-mac="${d.mac}" ${busy ? "disabled" : ""}>${d.blocked ? "Unblock" : "Block"}</button>` : ""}
      ${canForget(d) ? `<button class="btn sm danger" data-act="forget-device" data-mac="${d.mac}" ${busy ? "disabled" : ""} title="Clear its name, settings and allow-list entry, and hide it while it is offline">Forget</button>` : ""}
      ${busy ? '<span class="spin"></span>' : ""}
    </div>
    ${detailPanes(d)}</div>`;
}
// The nerdy part: polled every 2 s while a device is open (backend form "client").
function sparkline(hist) {
  if (hist.length < 2) return '<svg class="spark"></svg>';
  const W = 300, H = 54, max = Math.max(1e5, ...hist.map(h => Math.max(h.down, h.up)));
  const pts = k => hist.map((h, i) => `${(i / (hist.length - 1) * W).toFixed(1)},${(H - 3 - h[k] / max * (H - 8)).toFixed(1)}`).join(" ");
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-label="Speed over the last minute">
    <polyline points="${pts("up")}" fill="none" stroke="#93c5fd" stroke-width="1.5" vector-effect="non-scaling-stroke"/>
    <polyline points="${pts("down")}" fill="none" stroke="var(--accent)" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;
}
function modulation(n) {
  if (!n) return "";
  let m = /he mcs (\d+) Nss (\d+).*?bw(\d+).*?GI ([\d.]+us)/.exec(n);
  if (m) return `HE-MCS ${m[1]} · ${m[2]}SS · ${m[3]} MHz · ${m[4].replace("us", " µs")} GI`;
  m = /vht mcs (\d+) Nss (\d+).*?bw(\d+)/.exec(n);
  if (m) return `VHT-MCS ${m[1]} · ${m[2]}SS · ${m[3]} MHz`;
  m = /mcs index (\d+)/.exec(n);
  if (m) return `HT-MCS ${m[1]}`;
  return n.replace(/ auto$/, "");
}
// conntrack prints IPv6 zero-padded; show the usual short form.
function shortIp(a) {
  if (!a || a.indexOf(":") < 0) return a;
  const g = a.split(":").map(x => x.replace(/^0+(?=.)/, ""));
  let best = -1, len = 0;
  for (let i = 0; i < g.length; i++) { let j = i; while (j < g.length && g[j] === "0") j++; if (j - i > len && j - i > 1) { best = i; len = j - i; } i = Math.max(i, j - 1); }
  if (best < 0) return g.join(":");
  return (g.slice(0, best).join(":") + "::" + g.slice(best + len).join(":")).replace(/^:::/, "::");
}
// What a port usually is. Only a guess: apps can use any port.
function service(c) {
  const p = c.rport, u = c.p === "udp", in_ = (a, b) => p >= a && p <= b;
  if (c.p === "icmp" || c.p === "ipv6-icmp" || c.icmp != null) return "Ping (ICMP)";
  if (p === 443) return u ? "QUIC (HTTP/3)" : "HTTPS";
  if (p === 80) return "HTTP";
  if (p === 53) return "DNS";
  if (p === 853) return "DNS over TLS";
  if (p === 123) return "Time (NTP)";
  if (in_(19302, 19309)) return "Google Meet";
  if (in_(8801, 8810)) return "Zoom";
  if (in_(3478, 3481)) return "Call relay (STUN/TURN)";
  if (in_(50000, 50059) && u) return "Microsoft Teams";
  if (p === 5228) return "Google push";
  if (p === 5223) return "Apple push";
  if (p === 3074 || p === 3075) return "Xbox Live";
  if (in_(27000, 27050)) return "Steam";
  if (p === 7844) return "Cloudflare Tunnel";
  if (p === 22) return "SSH";
  if (p === 993 || p === 143) return "Email (IMAP)";
  if (p === 465 || p === 587 || p === 25) return "Email (SMTP)";
  if (p === 1900) return "SSDP";
  if (p === 5353) return "mDNS";
  if (c.dir === "in") return "Incoming";
  return u ? "UDP" : "TCP";
}
// Rough match of the priority-lane rules: call ports, ping, small UDP packets.
function laneOf(c) {
  const p = c.rport, u = c.p === "udp";
  if (c.p === "icmp" || c.p === "ipv6-icmp" || c.icmp != null) return true;
  if (!u) return false;
  if ((p >= 8800 && p <= 8815) || (p >= 3476 && p <= 3483) || (p >= 19296 && p <= 19311) || (p >= 49984 && p <= 50111)) return true;
  const avg = (c.up + c.down) / Math.max(1, c.upk + c.downk);
  return avg < 512;
}
function connPane(d) {
  const x = S.conns && S.conns.mac === d.mac ? S.conns : null;
  if (!d.online) return "";
  const head = `<h4>Connections${x && x.data ? ` · ${x.data.total}` : ""}<button class="btn sm" data-act="${x ? "conns-off" : "conns-on"}" data-mac="${d.mac}">${x ? "Hide" : "Show"}</button></h4>`;
  if (!x) return `<div class="pane wide">${head}<div class="muted" style="font-size:13px">What this device is talking to right now.</div></div>`;
  if (!x.data) return `<div class="pane wide">${head}<span class="spin"></span></div>`;
  const rows = x.data.list.map(c => {
    const key = [c.p, c.rip, c.rport, c.lport].join("|"), r = x.rates && x.rates[key];
    const now = r && (r.down + r.up) >= 1000 ? `${fmtRate(r.down)}<div class="sub">↑ ${fmtRate(r.up)}</div>` : "";
    const lane = laneOf(c) ? ' <span class="tag cap">Priority</span>' : "";
    return `<tr><td><span class="svc">${esc(service(c))}</span>${lane}<div class="sub">${esc(c.p.toUpperCase())}${c.state ? " · " + esc(c.state.toLowerCase().replace(/_/g, " ")) : ""}${c.dir === "in" ? " · incoming" : ""}</div></td>
      <td><span class="mono">${esc(shortIp(c.rip))}</span>${c.rport != null ? `<div class="sub">port ${c.rport}${c.lport != null ? ` · local ${c.lport}` : ""}</div>` : ""}</td>
      <td class="num">${fmtBytes(c.down)}<div class="sub">↑ ${fmtBytes(c.up)}</div></td>
      <td class="num">${now}</td></tr>`;
  }).join("");
  return `<div class="pane wide">${head}<div class="cwrap"><table class="ctable"><thead><tr><th>Service</th><th>Remote</th><th class="num">Total ↓/↑</th><th class="num">Now</th></tr></thead>
    <tbody>${rows || '<tr><td colspan="4" class="muted">No open connections.</td></tr>'}</tbody></table></div>
    ${x.data.total > x.data.list.length ? `<div class="sub" style="margin-top:8px">Showing the ${x.data.list.length} busiest of ${x.data.total}.</div>` : ""}</div>`;
}
async function pollConns() {
  const x = S.conns; if (!x || S.open !== x.mac || S.tab !== "devices" || document.hidden) return;
  try {
    const c = await iot("connections", { mac: x.mac });
    if (S.conns !== x) return;
    const prev = {}, rates_ = {};
    if (x.data) x.data.list.forEach(o => { prev[[o.p, o.rip, o.rport, o.lport].join("|")] = o; });
    c.list.forEach(o => { const k = [o.p, o.rip, o.rport, o.lport].join("|"); const r = prev[k] && rates(prev[k], o, x.data.t, c.t); if (r) rates_[k] = r; });
    x.data = c; x.rates = rates_;
    // Busiest right now first, then by total.
    c.list.sort((a, b) => { const ka = [a.p, a.rip, a.rport, a.lport].join("|"), kb = [b.p, b.rip, b.rport, b.lport].join("|");
      const ra = rates_[ka] ? rates_[ka].down + rates_[ka].up : 0, rb = rates_[kb] ? rates_[kb].down + rates_[kb].up : 0;
      return (rb - ra) || ((b.up + b.down) - (a.up + a.down)); });
    if (!S.editing && !S.capEdit) render();
  } catch (e) { if (e instanceof AuthError) fail(e); }
}
let connTimer = null;
function watchConns() { clearInterval(connTimer); connTimer = null; if (S.conns) { pollConns(); connTimer = setInterval(pollConns, 3000); } }
const kv = (rows, two) => `<div class="kv${two ? " two" : ""}">${rows.filter(Boolean).map(([k, v]) => `<span>${k}</span><b>${v}</b>`).join("")}</div>`;
function detailPanes(d) {
  const nw = v => `<span class="nw">${v}</span>`;
  const x = S.detail && S.detail.mac === d.mac ? S.detail : null, c = x && x.data, w = c && c.wifi;
  const cap = d.net !== "iot" ? (e => e ? esc(e.text) + ` <span class="muted" style="font-weight:400">· ${esc(e.why)}</span>` : "No cap")(effectiveCap(d)) : "";
  const live = x && x.live;
  const livePane = `<div class="pane"><h4>Live${c && c.approx ? " · approximate" : ""}</h4>
    ${!d.online ? '<div class="muted" style="font-size:13px">Offline</div>'
      : c && c.down == null ? `<div class="muted" style="font-size:13px;margin-bottom:8px">${/^Mesh/.test(d.where) ? "Live speed isn't available for devices connected through the mesh satellite: their traffic is counted there, not here." : "No traffic counters for this device."}</div>`
      : `<div class="live"><div><span>Download</span><b>${live ? fmtRate(live.down) : "…"}</b></div><div><span>Upload</span><b>${live ? fmtRate(live.up) : "…"}</b></div></div>
    ${sparkline((x && x.hist) || [])}`}
    ${kv([
      c && c.down != null && ["Used since connecting", nw(`↓ ${fmtBytes(c.down)} · ↑ ${fmtBytes(c.up)}`)],
      w && w.conn != null && ["Connected for", dur(w.conn)],
      d.net !== "iot" && ["Speed cap", cap],
    ])}</div>`;
  const wifiPane = w ? `<div class="pane wide"><h4>Wi-Fi</h4>${kv([
      ["Network", `${esc(w.ssid || "")} · ${w.iface && w.iface.startsWith("wl0") ? "5 GHz" : "2.4 GHz"} · ch ${esc(String(w.chanspec || "").split("/")[0])}`],
      ["Signal", nw(`${w.rssi} dBm · ${sigWord(w.rssi)}${sigBars(w.rssi)}`)],
      w.antennas && w.antennas.length > 1 && ["Per antenna", w.antennas.map(a => a + " dBm").join(" / ")],
      w.noise != null && ["Noise · SNR", `${w.noise} dBm · ${w.rssi - w.noise} dB`],
      ["Standard", esc(w.standard)],
      ["Channel width", (w.width || String(w.chanspec || "").split("/")[1] || "20") + " MHz"],
      w.streams && ["Streams", `${w.streams}×${w.streams} MIMO`],
      ["Link rate", nw(`↓ ${w.tx_rate} · ↑ ${w.rx_rate} Mbps`)],
      w.tx_nrate && ["Down modulation", esc(modulation(w.tx_nrate))],
      w.rx_nrate && ["Up modulation", esc(modulation(w.rx_nrate))],
      ["Security", nw(`${esc(w.auth || "?")} · ${esc((w.crypto || "").replace("AES_CCM", "AES-CCMP"))}`)],
      w.tx_pkts && ["Retries", nw(`${(100 * (w.tx_retries || 0) / w.tx_pkts).toFixed(1)}% sent · ${w.rx_pkts ? (100 * (w.rx_retried || 0) / w.rx_pkts).toFixed(1) : 0}% received`)],
    ], true)}</div>` : "";
  const v6 = c && c.ipv6 ? c.ipv6.slice().sort((a, b) => (a.startsWith("fe80") ? 1 : 0) - (b.startsWith("fe80") ? 1 : 0)) : [];
  const netPane = `<div class="pane"><h4>Network</h4>${kv([
      ["IPv4", `<span class="mono">${esc(d.ip || (c && c.ip) || "—")}</span>`],
      v6.length && ["IPv6", v6.map(a => `<span class="mono">${esc(a)}</span>`).join("<br>")],
      ["MAC", `<span class="mono">${esc(d.mac)}</span>${isPrivateMac(d.mac) ? ' <span class="muted" title="The device picked a random address for this network">· private</span>' : ""}`],
      ["Connection", esc(whereText(d))],
      d.host && d.name && d.host !== d.name && ["Reported name", esc(d.host)],
      c && c.lease_left > 0 && ["DHCP lease", dur(c.lease_left) + " left"],
      c && c.connections != null && ["Open connections", c.connections],
      c && c.iface && ["Interface", `<span class="mono">${esc(c.iface)}</span>`],
    ])}</div>`;
  return `<div class="panes">${livePane}${netPane}${wifiPane}${connPane(d)}</div>`;
}
let detailTimer = null;
async function pollDetail() {
  const mac = S.open; if (!mac || S.tab !== "devices" || document.hidden) return;
  try {
    const c = await iot("client", { mac });
    if (S.open !== mac) return;
    let x = S.detail && S.detail.mac === mac ? S.detail : { mac, hist: [] };
    const r = x.data ? rates(x.data, c, x.data.t, c.t) : null;
    if (r) { x.live = r; x.hist = x.hist.concat([r]).slice(-30); }
    x.data = c; S.detail = x;
    if (!S.editing && !S.capEdit) render();
  } catch (e) { if (e instanceof AuthError) fail(e); }
}
function watchDetail() {
  clearInterval(detailTimer); detailTimer = null;
  if (S.open) { pollDetail(); detailTimer = setInterval(pollDetail, 2000); } else S.detail = null;
}
const toggle = (field, d, on, label) => `<label class="togg"><span class="sw"><input type="checkbox" data-field="${field}" data-mac="${d.mac}" ${on ? "checked" : ""}><span></span></span>${esc(label)}</label>`;

function sectionList(title, rows, empty, right) {
  return `<h2>${title}<span class="count">${rows.length}</span></h2>
    <div class="list">${rows.length ? rows.join("") : `<div class="empty">${empty}</div>`}</div>`;
}
function simpleRow(d, control) {
  return `<div class="row ${d.online ? "" : "offline"}">
    <div class="av">${ic(connIcon(d))}<span class="dot ${d.online ? "on" : ""}"></span></div>
    <div style="min-width:0"><div class="nm"><span>${esc(devName(d))}</span>${d.this ? '<span class="tag you">This device</span>' : ""}</div>
      <div class="meta">${esc([d.ip, whereText(d)].filter(Boolean).join(", "))}</div></div>
    <div class="right">${control}</div></div>`;
}
const rowSwitch = (field, d, on, label) => `<label class="sw" title="${esc(label)}"><input type="checkbox" aria-label="${esc(label + ": " + devName(d))}" data-field="${field}" data-mac="${d.mac}" ${on ? "checked" : ""}><span></span></label>`;

function pwField(id, value, ph) {
  const shown = S.reveal[id];
  return `<div class="input"><input id="${id}" type="${shown ? "text" : "password"}" value="${esc(value)}" ${ph ? `placeholder="${esc(ph)}"` : ""} autocomplete="off">
    <button type="button" class="iconbtn" data-reveal="${id}" aria-label="Show password">${ic("eye")}</button></div>`;
}

