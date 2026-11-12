/* ------------------------------------------------------------------ login */
function showLogin(msg) {
  clearInterval(timer);
  $id("app").innerHTML = `<div class="login"><form id="lf" autocomplete="on">
    <div class="brand"><span class="mark">${ic("wifi")}</span><div>${esc(OWNER)}'s network<small>Archer AX10</small></div></div><p>Sign in with the router password.</p>
    <input type="text" name="username" value="admin" autocomplete="username" hidden>
    <div class="input"><input id="pw" type="password" placeholder="Router password" autocomplete="current-password" required>
      <button type="button" class="iconbtn" id="pwv" aria-label="Show password">${ic("eye")}</button></div>
    <button class="btn primary" id="lb">Log in</button>
    <div class="err" id="le">${esc(msg || "")}</div>
    <div class="alt">Need everything? <a href="${FULL}">Open the TP-Link settings</a></div>
  </form></div>`;
  const pw = $id("pw"); pw.focus();
  $id("pwv").onclick = () => { pw.type = pw.type === "password" ? "text" : "password"; };
  $id("lf").onsubmit = async ev => {
    ev.preventDefault();
    const b = $id("lb"); b.disabled = true; b.innerHTML = '<span class="spin"></span>'; $id("le").textContent = "";
    try { await API.login(pw.value); boot(); }
    catch (e) {
      b.disabled = false; b.textContent = "Log in";
      if (e instanceof ApiError) {
        const d = e.data || {}, left = d.attemptsAllowed != null && d.failureCount != null ? d.attemptsAllowed - d.failureCount : null;
        $id("le").textContent = "Wrong password." + (left != null && left >= 0 ? ` ${left} attempt${left === 1 ? "" : "s"} left.` : "");
      } else if (e instanceof TypeError) $id("le").textContent = "Can't reach the router.";
      else $id("le").textContent = "Login failed. Try again.";
      pw.select();
    }
  };
}

