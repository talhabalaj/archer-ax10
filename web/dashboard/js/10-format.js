/* ------------------------------------------------------------------ formatting */
const dur = s => { s = +s || 0; const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`; };
const devName = d => d.name || d.host || "Unknown device";
const fmtRate = bps => bps >= 1e6 ? (bps / 1e6).toFixed(bps >= 1e7 ? 0 : 1) + " Mbps" : bps >= 1e3 ? Math.round(bps / 1e3) + " kbps" : Math.round(bps) + " bps";
const fmtBytes = b => b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : b >= 1e6 ? (b / 1e6).toFixed(1) + " MB" : b >= 1e3 ? Math.round(b / 1e3) + " KB" : (b || 0) + " B";
const sigWord = r => r >= -60 ? "Excellent" : r >= -67 ? "Good" : r >= -75 ? "Fair" : "Weak";
const sigBars = r => { const n = r >= -60 ? 4 : r >= -67 ? 3 : r >= -75 ? 2 : 1;
  return `<span class="bars" aria-hidden="true">${[5, 8, 11, 14].map((h, i) => `<i class="${i < n ? "on" : ""}" style="height:${h - 2}px"></i>`).join("")}</span>`; };
// Speed from two byte-counter readings; null if there is no earlier reading or the
// counter went backwards (the device reconnected).
function rates(prev, cur, t0, t1) {
  if (!prev || prev.down == null || cur.down == null || !(t1 > t0)) return null;
  const dd = cur.down - prev.down, du = cur.up - prev.up;
  if (dd < 0 || du < 0) return null;
  return { down: dd * 8 / (t1 - t0), up: du * 8 / (t1 - t0) };
}
const isPrivateMac = mac => /^.[26AE]/i.test(mac);
// Icon: how the device is connected. (The stock device-type guesses are often wrong.)
function connIcon(d) {
  if (d.net === "iot") return "iot";
  if (/^Wired/.test(d.where)) return "wired";
  if (/^Mesh/.test(d.where)) return "mesh";
  return d.net === "guest" ? "guest" : "wifi";
}
function whereText(d) {
  if (!d.online) return "Offline";
  if (d.where === "Online") return "Connected";
  // Mesh backhaul networks have long random names; don't show those.
  const m = /^([A-Za-z0-9]{20,}) \((.+)\)$/.exec(d.where);
  return m ? `Mesh link (${m[2]})` : d.where;
}

