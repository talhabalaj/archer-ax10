function viewInternet() {
  const D = S.devices, w = S.shaping, sm = S.summary;
  const head = pageHead("Internet", "Your connection, and how its speed is shared.");
  if (!D || !w) return head + `<div class="card"><div class="card-b" style="padding:22px;border:0"><span class="spin"></span></div></div>` + skel(2);
  const wf = S.dirty.wan || w, wDirty = !!S.dirty.wan, auto = wf.auto === "on";
  const capped = sortDevices(D.list.filter(d => d.cap));
  const up = sm && sm.internet === "connected";
  const status = `<div class="card"><div class="card-h"><div style="flex:1"><h3><span class="dot ${up ? "on" : "bad"}" style="margin-right:8px;vertical-align:1px"></span>${sm ? (up ? "Connected" : "Not connected") : "Checking…"}</h3>
      <p>${sm ? `Public address ${esc(sm.wan_ip || "none")}${sm.wan_uptime ? `, connected for ${dur(sm.wan_uptime)}` : ""}.` : ""}</p></div></div></div>`;
  return head + status + usageCard() + `<h2>Whole connection</h2>
  <div class="card">
    <div class="card-h"><div style="flex:1"><h3>Keep the connection responsive</h3><p>Holds all internet traffic just under what your line can carry, so calls and games stay smooth while someone downloads.</p></div>
      <label class="sw"><input type="checkbox" id="w-enable" ${wf.enable === "on" ? "checked" : ""} aria-label="Whole-connection limit on"><span></span></label></div>
    <div class="card-b">
      <div class="field"><label>Speed</label><div class="seg" id="w-auto" data-v="${auto ? "on" : "off"}" role="group" aria-label="How the limit is set">
          <button data-wauto="on" aria-pressed="${auto}">Automatic</button><button data-wauto="off" aria-pressed="${!auto}">Fixed</button></div>
        <div class="help">${auto ? `Follows your line: it rises when there is room and backs off when the line fills up. <span id="w-now">${autoNow(w)}</span>`
          : "Always the speeds below. Set about 90% of what a speed test shows. Anything your line gives beyond that goes unused."}</div></div>
      <div class="field"><label for="w-down">${auto ? "Usual download" : "Download"}</label><div class="input short"><input id="w-down" inputmode="numeric" value="${esc(wf.down)}" placeholder="e.g. 30"><span class="unit">Mbps</span></div>
        ${auto ? '<div class="help">Where it starts, and where it returns when the line is quiet. A normal speed test result is a good value.</div>' : ""}</div>
      <div class="field"><label for="w-up">${auto ? "Usual upload" : "Upload"}</label><div class="input short"><input id="w-up" inputmode="numeric" value="${esc(wf.up)}" placeholder="e.g. 30"><span class="unit">Mbps</span></div></div>
      ${auto ? `<details class="addmac" ${S.wRange ? "open" : ""} id="w-range"><summary>Lowest and highest it may go</summary>
        <div class="field" style="border:0"><label for="w-min-d">Download</label><div class="rangerow"><div class="input short"><input id="w-min-d" inputmode="numeric" value="${esc(wf.min_down || "")}" placeholder="${Math.max(1, Math.floor((+wf.down || 30) / 2))}" aria-label="Lowest download"><span class="unit">Mbps</span></div><span class="muted">to</span>
          <div class="input short"><input id="w-max-d" inputmode="numeric" value="${esc(wf.max_down || "")}" placeholder="${Math.min(1000, (+wf.down || 30) * 3)}" aria-label="Highest download"><span class="unit">Mbps</span></div></div></div>
        <div class="field"><label for="w-min-u">Upload</label><div class="rangerow"><div class="input short"><input id="w-min-u" inputmode="numeric" value="${esc(wf.min_up || "")}" placeholder="${Math.max(1, Math.floor((+wf.up || 30) / 2))}" aria-label="Lowest upload"><span class="unit">Mbps</span></div><span class="muted">to</span>
          <div class="input short"><input id="w-max-u" inputmode="numeric" value="${esc(wf.max_up || "")}" placeholder="${Math.min(1000, (+wf.up || 30) * 3)}" aria-label="Highest upload"><span class="unit">Mbps</span></div></div>
          <div class="help">Leave empty for half to three times the usual speed.</div></div></details>` : ""}
      <div class="field"><label for="w-prio">Calls and games first</label><label class="sw"><input type="checkbox" id="w-prio" ${wf.prio === "on" ? "checked" : ""}><span></span></label>
        <div class="help">Zoom, Meet, Teams and FaceTime calls, game traffic and ping skip ahead of downloads and uploads. Works while the connection limit above is on.</div></div>
      <div class="field"><label for="w-glow">Guests go last</label><label class="sw"><input type="checkbox" id="w-glow" ${wf.guest_low === "on" ? "checked" : ""}><span></span></label>
        <div class="help">When the line is busy, home devices come first and guests share what is left (at least 10%). When it is quiet, guests still get full speed, up to their own limit.</div></div>
    </div>
    <div class="note">While this is on, all traffic runs through the router's processor instead of its hardware fast path.</div>
    ${wDirty ? `<div class="card-f"><button class="btn" data-act="w-reset">Discard</button><button class="btn primary" data-act="w-save">Save changes</button></div>` : ""}
  </div>
  ${sectionList("Capped devices", capped.map(d => simpleRow(d, `<span class="tag cap">${capText(d.cap)}</span><button class="btn sm" data-act="cap-remove" data-mac="${d.mac}">Remove</button>`)), "No device has its own cap. Open a device on the Devices tab and choose Cap speed.")}
  ${loadCard()}
  ${namesCard()}`;
}
// Is the router keeping up? Its processor over the last 24 hours (ax10.sh load_guard).
function loadCard() {
  const L = S.load; if (!L) return "";
  if (!L.now) return `<h2>Router load</h2><div class="card"><div class="card-b" style="border:0;padding:18px 20px">Measuring. The first reading appears within a minute.</div></div>`;
  const pk = L.peak || L.now, mins = Math.round((L.full_s || 0) / 60);
  const mbps = k => (k / 1000).toFixed(k < 10000 ? 1 : 0);
  const ago = s => s < 90 ? "just now" : s < 5400 ? Math.round(s / 60) + " min ago" : Math.round(s / 3600) + " h ago";
  const W = 600, H = 64, n = L.buckets.length || 96, bw = (W - 4) / n - 1.5, y90 = H - 0.9 * (H - 4);
  const bars = L.buckets.map((b, i) => !b.n ? "" : `<rect x="${(2 + i * (bw + 1.5)).toFixed(1)}" y="${(H - Math.max(2, b.busy / 100 * (H - 4))).toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(2, b.busy / 100 * (H - 4)).toFixed(1)}" rx="1.5" style="fill:var(${b.busy >= 90 ? "--bad" : b.busy >= 70 ? "--warn" : "--signal"})"><title>${(n - i) * 15 > 60 ? Math.round((n - i) / 4) + " h" : (n - i) * 15 + " min"} ago: up to ${b.busy}% busy, up to ${b.mbps} Mbps</title></rect>`).join("");
  const verdict = mins === 0 ? "It has kept up: never nearly full in the last 24 hours."
    : `Nearly full for ${mins} min in the last 24 hours. At those times the router, not your line, may be what limits speed.`;
  return `<h2>Router load</h2>
  <div class="card"><div class="now" style="border:0;box-shadow:none;margin:0;background:none">
    <div class="nums"><div class="num"><span>Processor now</span><b>${L.now.busy}<small>%</small></b></div>
      <div class="num"><span>Busiest, last 24 h</span><b>${pk.busy}<small>%</small></b></div>
      <div class="num"><span>Nearly full</span><b>${mins}<small>min</small></b></div></div>
    <svg class="flow" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Processor load over the last 24 hours">
      <line x1="0" x2="${W}" y1="${y90.toFixed(1)}" y2="${y90.toFixed(1)}" style="stroke:var(--line-2);stroke-dasharray:4 4"/>${bars}</svg>
    <div class="legend"><span>Last 24 hours, busiest moment per quarter hour. Dashed line: 90%.</span></div></div>
    <div class="card-b"><p style="margin:0">${verdict} The busiest moment was ${ago(pk.ago)}: ${pk.busy}% (network ${pk.net}%) while moving ${mbps(pk.down)} Mbps down and ${mbps(pk.up)} up.
      Now: network ${L.now.net}%, load ${esc(String(L.now.load))} across ${L.cores || 3} cores.</p></div>
    ${L.event ? `<div class="note">Last noted ${ago(L.event.ago)}: ${esc(L.event.text.replace(/^router processor /, "processor "))}.</div>` : ""}
    <div class="note">The speed limit and device caps run on the processor, not the hardware fast path, so this is where a busy router shows first.</div>
  </div>`;
}
// Data used: this month and today, a bar per day, and who used it.
const gb = b => b >= 1073741824 * 100 ? Math.round(b / 1073741824) + " GB" : b >= 1073741824 ? (b / 1073741824).toFixed(1) + " GB" : Math.round(b / 1048576) + " MB";
function usageCard() {
  const u = S.usage; if (!u) return "";
  const m = u.months.find(x => x.month === u.month) || { down: 0, up: 0 };
  const t = u.days.find(x => x.day === u.today) || { down: 0, up: 0 };
  if (!u.days.length) return `<h2>Data used</h2><div class="card"><div class="card-b" style="border:0;padding:18px 20px">Nothing counted yet. The first figures appear within a minute.</div></div>`;
  const first = u.days[0].day, monthName = new Date(u.month + "-15").toLocaleDateString(undefined, { month: "long" });
  const dayLabel = d => new Date(d + "T12:00:00").toLocaleDateString(undefined, { day: "numeric", month: "short" });
  // one bar per day, the last 30 days with data
  const days = u.days.slice(-30), max = Math.max(1, ...days.map(d => d.down + d.up));
  const W = 600, H = 70, bw = Math.min(26, (W - 4) / Math.max(days.length, 12) - 4);
  const bars = days.map((d, i) => { const h = Math.max(2, (d.down + d.up) / max * (H - 6)), hu = d.up / max * (H - 6), x = 2 + i * (bw + 4);
    return `<g><title>${dayLabel(d.day)}: ${gb(d.down)} down, ${gb(d.up)} up</title><rect x="${x.toFixed(1)}" y="${(H - h).toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="2" style="fill:var(--signal)"/>
      <rect x="${x.toFixed(1)}" y="${(H - hu).toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(0, hu).toFixed(1)}" rx="2" style="fill:var(--ink-3)"/></g>`; }).join("");
  const counted = u.devices.reduce((a, d) => a + d.down + d.up, 0), other = m.down + m.up - counted;
  const share = b => Math.max(1, Math.round(b / Math.max(1, m.down + m.up) * 100));
  const row = (name, sub, d, up, total) => `<div class="row"><div style="min-width:0;grid-column:1 / 3"><div class="nm"><span>${name}</span></div><div class="meta">${sub}</div>
      <div class="ubar"><i style="width:${Math.min(100, share(total))}%"></i></div></div><div class="right" style="text-align:right"><div><b style="color:var(--ink)">${gb(total)}</b><br><span style="font-size:12.5px">${gb(d)} down, ${gb(up)} up</span></div></div></div>`;
  const rows = u.devices.filter(d => d.down + d.up >= 1048576).slice(0, 12).map(d => row(esc(d.name || d.mac), esc(d.mac), d.down, d.up, d.down + d.up));
  if (other > 52428800) rows.push(row("Not matched to a device", "Mostly IPv6 traffic of devices on the mesh satellite or a cable, which the router only counts in the total.", 0, 0, other).replace(/<br>.*?<\/span>/, ""));
  return `<h2>Data used</h2>
  <div class="card"><div class="now" style="border:0;box-shadow:none;margin:0;background:none">
    <div class="nums"><div class="num"><span>${esc(monthName)} so far</span><b>${gb(m.down + m.up).replace(" ", "<small>")}</small></b></div>
      <div class="num"><span>Today</span><b>${gb(t.down + t.up).replace(" ", "<small>")}</small></b></div></div>
    <svg class="flow" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Data used per day">${bars}</svg>
    <div class="legend"><span><i style="background:var(--signal)"></i>Download ${gb(m.down)}</span><span><i style="background:var(--ink-3)"></i>Upload ${gb(m.up)}</span><span>Counted since ${dayLabel(first)}</span></div></div></div>
  ${rows.length ? sectionList(`Who used it in ${esc(monthName)}`, rows, "") + '<p class="muted" style="font-size:13px;margin:10px 2px 0;max-width:76ch">Devices on this router&rsquo;s Wi-Fi are counted at the radio, which includes traffic between devices at home. Devices on the mesh satellite or a cable are counted at the internet connection, IPv4 only. So per-device figures are approximate; the totals above are exact.</p>' : ""}`;
}
// What the automatic limit is doing: "Now 41 Mbps down, 28 up."
function autoNow(w) {
  if (w.auto !== "on" || w.enable !== "on") return "";
  if (!w.now_down) return "Starting…";
  const m = k => (k / 1000).toFixed(k < 10000 ? 1 : 0);
  return `<b>Now ${m(w.now_down)} Mbps down, ${m(w.now_up)} up.</b>${w.now_extra >= 15 ? " The line is full right now." : w.now_ceil_down || w.now_ceil_up ? " It has found the top of your line and is holding just under it." : ""}`;
}
// Local names: <name>.<suffix> for the router and devices, from the router's DNS.
const dnsLabel = v => String(v || "").toLowerCase().replace(/[\s_.]/g, "-").replace(/[^a-z0-9-]/g, "").replace(/-+/g, "-").replace(/^-|-$/g, "").slice(0, 63);
function namesCard() {
  const n = S.names; if (!n) return "";
  const f = S.dirty.names || n, dirty = !!S.dirty.names, sfx = dnsLabel(f.domain) || "home";
  const first = dnsLabel(String(f.router).trim().split(/\s+/)[0]) || "router";
  const D = S.devices, sample = D && D.list.find(d => d.online && d.net === "home" && !d.this);
  const rows = f.hosts.map((h, i) => `<div class="hostrow"><div class="input"><input class="nm-host" id="nm-h-${i}-name" data-i="${i}" data-k="name" value="${esc(h.name)}" placeholder="name" aria-label="Name"><span class="unit">.${esc(sfx)}</span></div>
      <div class="input"><input class="nm-host" id="nm-h-${i}-ip" data-i="${i}" data-k="ip" value="${esc(h.ip)}" placeholder="192.168.0.10" inputmode="decimal" aria-label="Address"></div>
      <button class="iconbtn" data-act="nm-del" data-i="${i}" aria-label="Remove this name" title="Remove">${ic("x")}</button></div>`).join("");
  return `<h2>Local names</h2>
  <div class="card">
    <div class="card-h"><div style="flex:1"><h3>Names and private lookups</h3>
      <p>${f.enable === "on" ? `Open this dashboard at <b>${esc(first)}.${esc(sfx)}</b>, and reach any device as its name plus <b>.${esc(sfx)}</b>${sample ? `, like ${esc(dnsLabel(devName(sample)))}.${esc(sfx)}` : ""}.`
        : "Give the router and every device a name you can type, like router.home."} Devices then ask the router for DNS, and it passes everything else on to the servers below.</p></div>
      <label class="sw"><input type="checkbox" id="nm-enable" ${f.enable === "on" ? "checked" : ""} aria-label="Local names on"><span></span></label></div>
    <div class="card-b">
      <div class="field"><label for="nm-domain">Ending</label><div class="input short"><span class="unit" style="padding-left:0">.</span><input id="nm-domain" value="${esc(f.domain)}" maxlength="30" autocapitalize="off" spellcheck="false"></div>
        <div class="help">Any word except "local", which phones and Macs look up differently.</div></div>
      <div class="field"><label for="nm-router">This router's name</label><div class="input"><input id="nm-router" value="${esc(f.router)}" maxlength="80" autocapitalize="off" spellcheck="false"><span class="unit">.${esc(sfx)}</span></div>
        <div class="help">Several names work too, separated by spaces.</div></div>
      <div class="field"><label for="nm-doh">Encrypt lookups</label><label class="sw"><input type="checkbox" id="nm-doh" ${f.doh === "on" ? "checked" : ""}><span></span></label>
        <div class="help">DNS over HTTPS: your internet provider can't see or change which sites are looked up. ${n.doh === "on" && n.enable === "on" ? (n.doh_ok
          ? `<b style="color:var(--signal)">Working</b>${n.doh_answered ? `, ${n.doh_answered.toLocaleString()} lookups, about ${n.doh_ms} ms each` : ""}.`
          : `<b style="color:var(--warn)">Not answering right now</b>; the plain servers below are used until it does.`) : ""}</div></div>
      ${f.doh === "on" ? `<div class="field"><label for="nm-prov">Encrypted DNS service</label><div class="input short" style="max-width:240px"><select id="nm-prov" style="width:100%;background:transparent;border:0;color:inherit;font:inherit">
          ${[["cloudflare", "Cloudflare (1.1.1.1)"], ["google", "Google (8.8.8.8)"], ["quad9", "Quad9 (9.9.9.9), blocks malware sites"]].map(([v, l]) => `<option value="${v}" ${f.provider === v ? "selected" : ""}>${l}</option>`).join("")}</select></div></div>` : ""}
      <div class="field"><label for="nm-up">${f.doh === "on" ? "Fallback, not encrypted" : "Look everything else up at"}</label><div class="input"><input id="nm-up" value="${esc(f.upstream)}" maxlength="80" inputmode="decimal" spellcheck="false"></div>
        <div class="help">DNS servers, separated by spaces. 1.1.1.1 and 1.0.0.1 are Cloudflare.${f.doh === "on" ? " Used only while the encrypted service can't be reached, for example right after the router starts." : ""}</div></div>
      <div class="field"><label>Your own names</label><div>${rows}<button class="btn sm" data-act="nm-add">Add a name</button></div>
        <div class="help">For something with a fixed address, like a camera or a NAS. Devices get their own name without this.</div></div>
    </div>
    <div class="note">A device starts using this the next time it joins the Wi-Fi, or within about an hour. IoT devices keep using public DNS servers directly: they are not allowed to talk to the router.</div>
    ${dirty ? `<div class="card-f"><button class="btn" data-act="nm-reset">Discard</button><button class="btn primary" data-act="nm-save">Save changes</button></div>` : ""}
  </div>`;
}
function readNamesForm() {
  const hosts = []; document.querySelectorAll(".nm-host").forEach(i => { (hosts[+i.dataset.i] = hosts[+i.dataset.i] || {})[i.dataset.k] = i.value.trim(); });
  return { enable: $id("nm-enable").checked ? "on" : "off", domain: $id("nm-domain").value.trim(), router: $id("nm-router").value.trim(), upstream: $id("nm-up").value.trim(), hosts,
           doh: $id("nm-doh").checked ? "on" : "off", provider: $id("nm-prov") ? $id("nm-prov").value : S.names.provider };
}
// The draft `f` becomes the state shown: used after reading the form, and directly
// when a row was added or removed (re-reading the form then would undo that).
function setNamesDraft(f, force) {
  const n = S.names;
  const same = ["enable", "domain", "router", "upstream", "doh", "provider"].every(k => f[k] === n[k]) && JSON.stringify(f.hosts) === JSON.stringify(n.hosts);
  const was = !!S.dirty.names;
  if (same) delete S.dirty.names; else S.dirty.names = f;
  if (force || was !== !same) render();
}
function markNames(force) { setNamesDraft(readNamesForm(), force); }
async function saveNames() {
  const f = S.dirty.names; if (!f) return;
  const hosts = f.hosts.filter(h => h.name || h.ip);
  if (hosts.some(h => !dnsLabel(h.name) || !/^\d+\.\d+\.\d+\.\d+$/.test(h.ip))) return toast("Each of your own names needs a name and an address like 192.168.0.10.", true);
  try {
    const n = await iot("names", { operation: "write", enable: f.enable, domain: f.domain, router: f.router, upstream: f.upstream, doh: f.doh, provider: f.provider, hosts: hosts.map(h => `${dnsLabel(h.name)}=${h.ip}`).join(" ") });
    if (!Array.isArray(n.hosts)) n.hosts = [];
    S.names = n; delete S.dirty.names; render();
    toast(n.enable === "on" ? `Saved. ${dnsLabel(n.router.split(" ")[0])}.${n.domain} works once a device rejoins the Wi-Fi.` : "Local names off");
  } catch (e) { if (e instanceof AuthError) fail(e); else toast(e.code && e.code !== "-1" ? `Not saved: ${e.code}.` : "Not saved. Check the fields.", true); }
}

