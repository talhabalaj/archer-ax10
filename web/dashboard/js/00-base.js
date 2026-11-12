"use strict";
const OWNER = "Talha";
const FULL = "/webpages/index.html";

/* ------------------------------------------------------------------ icons */
const ICON = {
  devices: '<rect x="2" y="4" width="14" height="10" rx="2"/><path d="M6 18h6M9 14v4"/><rect x="17" y="8" width="5" height="12" rx="1.5"/>',
  iot: '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
  guest: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M21.5 20a6.5 6.5 0 0 0-4-6"/>',
  wifi: '<path d="M2 8.8a15 15 0 0 1 20 0"/><path d="M5 12.4a10.5 10.5 0 0 1 14 0"/><path d="M8.5 15.9a5.5 5.5 0 0 1 7 0"/><circle cx="12" cy="19.2" r=".9"/>',
  wired: '<rect x="4" y="3" width="16" height="12" rx="2"/><path d="M8 15v3h8v-3M10 18v3h4v-3M8 7v3M12 7v3M16 7v3"/>',
  mesh: '<circle cx="12" cy="5" r="2.5"/><circle cx="5" cy="18" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="M10.8 7.2 6.3 15.8M13.2 7.2l4.5 8.6M7.5 18h9"/>',
  gauge: '<path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="M12 13l4-5"/><circle cx="12" cy="13" r="1.4"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.6-4.5L4 8"/><path d="M4 3v5h5"/><path d="M4 13a8 8 0 0 0 14.6 4.5L20 16"/><path d="M20 21v-5h-5"/>',
  power: '<path d="M12 3v9"/><path d="M6.3 6.3a8 8 0 1 0 11.4 0"/>',
  out: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4"/><path d="M9 16l-4-4 4-4M5 12h11"/>',
  ext: '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/>',
  eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  copy: '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
  qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M17 17h4v4h-4"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  chev: '<path d="M9 6l6 6-6 6"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
};
const ic = (n, cls) => `<svg viewBox="0 0 24 24"${cls ? ` class="${cls}"` : ""} aria-hidden="true">${ICON[n]}</svg>`;
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const $id = id => document.getElementById(id);

/* ------------------------------------------------------------------ API */
class AuthError extends Error {}
class ApiError extends Error { constructor(code, data) { super("Router said: " + code); this.code = code; this.data = data; } }
const API = (() => {
  const L = "/cgi-bin/luci/;stok=";
  let enc = null, stok = "";
  const qs = o => Object.entries(o).flatMap(([k, v]) => [].concat(v).map(x => encodeURIComponent(k) + "=" + encodeURIComponent(x))).join("&");
  async function raw(url, body) {
    const r = await fetch(url, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
    if (r.status === 401 || r.status === 403) throw new AuthError("session");
    return r.text();
  }
  function seal(e, params, login) { const d = e.dataEncrypt(qs(params), login); return "sign=" + encodeURIComponent(d.sign) + "&data=" + encodeURIComponent(d.data); }
  function open(e, text) {
    let outer; try { outer = JSON.parse(text); } catch (x) { throw new AuthError("garbled"); }
    if (outer && outer.data === undefined && outer.success === false) return outer;          // plain error reply
    try { return JSON.parse(e.dataDecrypt(outer.data)); } catch (x) { throw new AuthError("keys"); }
  }
  // Reuse a login made here or in the stock UI (same localStorage keys as its encryptManager).
  function restore() {
    try {
      const t = localStorage.getItem("token"), a = localStorage.getItem("encryptorAES"), r = localStorage.getItem("encryptorRsa"),
            h = localStorage.getItem("encryptorHash"), q = localStorage.getItem("encryptorSeq");
      if (!t || !a || !r || !h || !q) return false;
      const e = new jQuery.encrypt.encryptor();
      e.setAESStringKey(a); e.setRSAStringKey(r); e.setHash(h); e.setSeq(q);
      enc = e; stok = t; return true;
    } catch (x) { return false; }
  }
  function forget() { enc = null; stok = ""; try { localStorage.setItem("token", ""); } catch (x) {} }
  async function login(pw) {
    const keys = JSON.parse(await raw(L + "/login?form=keys", "operation=read")).data.password;
    const auth = JSON.parse(await raw(L + "/login?form=auth", "operation=read")).data;
    const e = new jQuery.encrypt.encryptor();
    e.setRSAKey(auth.key[0], auth.key[1]); e.setSeq(auth.seq); e.genAESKey();
    e.setHash("admin", pw);           // MD5; the stock UI uses SHA-256 only for Singapore units
    const res = open(e, await raw(L + "/login?form=login", seal(e, { password: jQuery.su.encrypt(pw, keys), operation: "login", confirm: "true" }, true)));
    if (!res.success || !res.data || !res.data.stok) throw new ApiError(res.errorcode || (res.data && res.data.errorcode) || "login", res.data);
    enc = e; stok = res.data.stok;
    try {
      localStorage.setItem("token", stok);
      localStorage.setItem("encryptorAES", e.getAESKey()); localStorage.setItem("encryptorSeq", e.getSeq());
      localStorage.setItem("encryptorHash", e.getHash()); localStorage.setItem("encryptorRsa", e.getRSAKey());
    } catch (x) {}
  }
  async function call(path, params) {
    if (!enc || !stok) throw new AuthError("none");
    const res = open(enc, await raw(L + stok + path, seal(enc, Object.assign({ operation: "read" }, params))));
    const code = res.errorcode || res.errorCode || res.error_code;
    if (!res.success) {
      if (/timeout|conflict|permission|login/i.test(String(code))) throw new AuthError(code);
      throw new ApiError(code || "error", res.data);
    }
    return res;
  }
  return { restore, login, call, forget, has: () => !!(enc && stok) };
})();
const iot = (form, params) => API.call("/admin/ax10?form=" + form, params).then(r => r.data);

/* ------------------------------------------------------------------ state */
// "#networks/guest" -> { tab: "networks", net: "guest" }. Links from older versions
// (#iot, #wifi, #speed, #guests) land on the page that now holds that content.
function route(hash) {
  const [t, n] = String(hash || "").replace(/^#/, "").split("/");
  const OLD = { iot: ["networks", "iot"], wifi: ["networks", "home"], guests: ["networks", "guest"], speed: ["internet"] };
  const old = Object.prototype.hasOwnProperty.call(OLD, t) ? OLD[t] : null;      // "#constructor" is not a page
  if (old) return { tab: old[0], net: old[1] || "home" };
  if (t === "networks") return { tab: t, net: ["home", "guest", "iot"].includes(n) ? n : "home" };
  return { tab: t === "internet" ? t : "devices", net: "home" };
}
const S = {
  ...route(location.hash),
  devices: null, summary: null, iot: null, guest: null, wifi: null,
  filter: "all", q: "", open: null, editing: null, reveal: {}, qr: null,
  menu: false, busy: {}, dirty: {},
};
const TABS = [["devices", "Devices", "devices"], ["networks", "Networks", "wifi"], ["internet", "Internet", "globe"]];
const SUBNETS = [["home", "Home"], ["guest", "Guest"], ["iot", "IoT"]];

function toast(msg, bad) {
  const t = document.createElement("div"); t.className = "toast" + (bad ? " bad" : ""); t.textContent = msg;
  $id("toasts").appendChild(t); setTimeout(() => t.remove(), bad ? 5200 : 2600);
}
function fail(e) {
  if (e instanceof AuthError) {
    API.forget();
    // A reply we can't decrypt means another login replaced ours: the router allows one admin at a time.
    showLogin(e.message === "keys" ? "Signed out: the router was opened on another device or tab (it allows one admin at a time)." : "Your session ended. Log in again.");
    return;
  }
  if (e instanceof TypeError) { toast("Can't reach the router.", true); return; }
  toast(e && e.message ? e.message : "Something went wrong.", true);
}
function confirmBox(title, text, ok, danger) {
  return new Promise(res => {
    const d = document.createElement("div"); d.className = "scrim";
    d.innerHTML = `<div class="dialog" role="dialog" aria-modal="true"><h3>${esc(title)}</h3><p>${esc(text)}</p>
      <div class="acts"><button class="btn" data-v="0">Cancel</button><button class="btn ${danger ? "danger" : "primary"}" data-v="1">${esc(ok)}</button></div></div>`;
    d.addEventListener("click", ev => { const b = ev.target.closest("[data-v]"); if (b || ev.target === d) { d.remove(); res(!!(b && b.dataset.v === "1")); } });
    document.body.appendChild(d); d.querySelector('[data-v="1"]').focus();
  });
}

