/* ------------------------------------------------------------------ QR (loaded on first use) */
let qrLib = null;
function drawQr() {
  const box = $id("qrbox"), n = (S.nets || []).find(x => x.id === S.qr);
  if (!box || !n) return;
  const escq = s => String(s).replace(/([\\;,:"])/g, "\\$1");
  const text = `WIFI:T:WPA;S:${escq(n.ssid)};P:${escq(n.key)};;`;
  const draw = () => { box.innerHTML = ""; jQuery(box).qrcode({ width: 180, height: 180, text: unescape(encodeURIComponent(text)) }); };
  if (qrLib) return qrLib.then(draw);
  qrLib = new Promise((res, rej) => { const s = document.createElement("script"); s.src = "/webpages/js/libs/jquery.qrcode.min.js"; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
  qrLib.then(draw, () => { box.textContent = "QR code unavailable."; qrLib = null; });
}

