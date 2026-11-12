/* ------------------------------------------------------------------ shell */
function shell() {
  const menu = `<div class="menu"><button class="iconbtn" id="mb" aria-label="More" aria-expanded="false">${ic("more")}</button>
      <div class="menu-pop hidden" id="mp">
        <a href="${FULL}">${ic("ext")}Full TP-Link settings</a>
        <button id="mr">${ic("power")}Reboot router</button>
        <button id="mo" class="danger">${ic("out")}Log out</button>
      </div></div>`;
  $id("app").innerHTML = `<div class="app">
    <aside class="side">
      <div class="brand"><span class="mark">${ic("wifi")}</span><div>${esc(OWNER)}'s network<small>Archer AX10</small></div></div>
      <nav class="tabs" id="tabs" aria-label="Sections">${TABS.map(([id, label, icon]) => `<button data-tab="${id}">${ic(icon)}<span>${label}</span></button>`).join("")}</nav>
      <div class="spacer"></div>
      <div class="sidestat" id="sidestat"></div>
      <div class="sideacts"><button class="iconbtn" id="rf" aria-label="Refresh" title="Refresh">${ic("refresh")}</button>${menu}</div>
    </aside>
    <div class="main">
      <div class="mobilehead"><div class="brand"><span class="mark">${ic("wifi")}</span><div>${esc(OWNER)}'s network</div></div><span id="mobstat"></span></div>
      <main class="wrap" id="view"></main>
    </div></div>`;
  $id("tabs").onclick = ev => { const b = ev.target.closest("[data-tab]"); if (b) go(b.dataset.tab); };
  $id("rf").onclick = async () => { const b = $id("rf"); b.firstChild.style.animation = "rot .7s linear infinite"; await refresh(); b.firstChild.style.animation = ""; };
  const mp = $id("mp");
  $id("mb").onclick = ev => { ev.stopPropagation(); mp.classList.toggle("hidden"); $id("mb").setAttribute("aria-expanded", !mp.classList.contains("hidden")); };
  document.addEventListener("click", ev => { if (!ev.target.closest(".menu")) mp.classList.add("hidden"); });
  $id("mr").onclick = reboot;
  $id("mo").onclick = logout;
}
// Router and internet state, in the sidebar (and a dot on phones).
function renderSide() {
  const sm = S.summary, D = S.devices, el = $id("sidestat"), mob = $id("mobstat");
  if (!el) return;
  const up = sm && sm.internet === "connected";
  el.innerHTML = sm ? `<b><span class="dot ${up ? "on" : "bad"}"></span>${up ? "Internet connected" : "Internet down"}</b>
      <span class="sub">${esc(sm.wan_ip || "No address")}${sm.wan_uptime ? `, up ${dur(sm.wan_uptime)}` : ""}</span>
      <span class="sub">Router up ${dur(sm.uptime)}${D ? `, ${D.list.filter(d => d.online).length} devices online` : ""}</span>` : '<span class="sub">Checking the connection…</span>';
  if (mob) mob.innerHTML = sm ? `<span class="dot ${up ? "on" : "bad"}" title="${up ? "Internet connected" : "Internet down"}"></span>` : "";
}
const pageHead = (title, sub, right) => `<div class="pagehead"><div><h1>${title}</h1>${sub ? `<p>${sub}</p>` : ""}</div>${right || ""}</div>`;
function go(tab, net) {
  net = net || (tab === "networks" ? S.net : undefined);
  if (S.tab === tab && (!net || S.net === net)) return;
  S.tab = tab; if (net) S.net = net;
  S.open = null; S.editing = null; S.qr = null; S.conns = null; watchConns(); watchDetail();
  const h = "#" + tab + (tab === "networks" ? "/" + S.net : "");
  if (location.hash !== h) history.pushState(null, "", h);
  render(); refresh(true);
  window.scrollTo(0, 0);
}
async function reboot() {
  if (!await confirmBox("Reboot the router?", "Everything goes offline for about two minutes, then reconnects by itself.", "Reboot", true)) return;
  // Through our backend: it saves the usage log first (ax10.sh reboot). If that call
  // fails, TP-Link's own reboot still restarts the router.
  // (A reply that can't be read, or a session gone, means it is already going down.)
  try { await iot("reboot", { operation: "write" }); }
  catch (e) {
    if (!(e instanceof AuthError)) {
      try { await API.call("/admin/system?form=reboot", { operation: "write" }); } catch (e2) { if (!(e2 instanceof AuthError)) return fail(e2); }
    }
  }
  clearInterval(timer);
  $id("app").innerHTML = `<div class="login"><div><div class="busy"><span class="spin"></span><b>Rebooting…</b></div>
    <p class="muted" style="margin-top:10px">This page reloads when the router is back.</p></div></div>`;
  const t0 = Date.now();
  const ping = async () => {
    try { const r = await fetch("/?" + Date.now(), { cache: "no-store" }); if (r.ok && Date.now() - t0 > 40000) return location.reload(); } catch (x) {}
    setTimeout(ping, 4000);
  };
  setTimeout(ping, 20000);
}
async function logout() {
  try { await API.call("/admin/system?form=logout", { operation: "write" }); } catch (e) {}
  API.forget(); showLogin("Logged out.");
}

