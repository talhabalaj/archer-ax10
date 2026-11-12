/* ------------------------------------------------------------------ start */
function boot() { shell(); render(); refresh(); startPolling(); }
if (typeof jQuery === "undefined" || !jQuery.encrypt) {
  $id("app").innerHTML = `<div class="login"><div><b>Couldn't load the router's scripts.</b><p class="muted">Try reloading, or <a href="${FULL}">open the TP-Link settings</a>.</p></div></div>`;
} else if (API.restore()) boot(); else showLogin();
