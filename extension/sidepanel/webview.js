/* global acquireVsCodeApi */
const vscode = acquireVsCodeApi();
const meta = document.getElementById('codestrap-initial');
const INITIAL = meta ? JSON.parse(meta.dataset.json || '{}') : {};

// helpers
const $ = (id) => document.getElementById(id);
const togglePw = (inputId) => { const el = $(inputId); el.type = (el.type === 'password') ? 'text' : 'password'; };

// --- Top buttons ---
$("btn-docs").onclick = () => vscode.postMessage({ type:"open:docs" });
$("btn-cli").onclick  = () => vscode.postMessage({ type:"open:cli" });

// Reboot with spinner-only; proper centered spin
(function setupReboot(){
  const btn = $("reboot");
  btn.onclick = () => {
    btn.classList.add("loading");
    btn.disabled = true;
    vscode.postMessage({ type:"reboot" });
  };
})();

// password toggles
$("login-pw-eye").onclick  = () => togglePw("login-pw");
$("login-pw2-eye").onclick = () => togglePw("login-pw2");
$("sudo-pw-eye").onclick   = () => togglePw("sudo-pw");
$("sudo-pw2-eye").onclick  = () => togglePw("sudo-pw2");
$("gh-token-eye").onclick = () => togglePw("gh-token");

// prefill GitHub fields from env if provided
(function prefill(){
  if (INITIAL.GITHUB_USERNAME) $("gh-user").value = INITIAL.GITHUB_USERNAME;
  if (INITIAL.GITHUB_TOKEN)    $("gh-token").value = INITIAL.GITHUB_TOKEN;
  if (INITIAL.GIT_NAME)        $("git-name").value = INITIAL.GIT_NAME;
  if (INITIAL.GIT_EMAIL)       $("git-email").value = INITIAL.GIT_EMAIL;
  if (INITIAL.GITHUB_REPOS)    $("gh-repos").value = INITIAL.GITHUB_REPOS;

  if (INITIAL.GITHUB_PULL) {
    const v = String(INITIAL.GITHUB_PULL).trim().toLowerCase();
    $("gh-pull").checked = ['1','y','yes','t','true','on'].includes(v);
  }
})();

// password actions
function setError(id, msg){
  const el = $(id);
  el.textContent = msg || "";
  el.style.display = msg ? "block" : "none";
}

// LOGIN change flow
$("login-run").onclick = () => {
  const a = $("login-pw").value || "";
  const b = $("login-pw2").value || "";

  // local validation + inline error
  if (a.length < 8) {
    setError("login-error", "Password must be at least 8 characters.");
    vscode.postMessage({ type: "host:error", message: "Password must be at least 8 characters." });
    return;
  }
  if (a !== b) {
    setError("login-error", "Passwords do not match.");
    vscode.postMessage({ type: "host:error", message: "Passwords do not match." });
    return;
  }

  // clear error & let the host do final validation + action
  setError("login-error", "");
  vscode.postMessage({ type:"passwd:set", password: a, confirm: b });
};

// Optional: live-clear the inline error while typing
+["login-pw","login-pw2"].forEach(id => {
  const el = $(id);
  el && el.addEventListener("input", () => setError("login-error",""));
});

// SUDO change flow
$("sudo-run").onclick = () => {
  const a = $("sudo-pw").value || "";
  const b = $("sudo-pw2").value || "";
  if (a.length < 8) {
    setError("sudo-error", "Password must be at least 8 characters.");
    vscode.postMessage({ type: "host:error", message: "Password must be at least 8 characters." });
    return;
  }
  if (a !== b) {
    setError("sudo-error", "Passwords do not match.");
    vscode.postMessage({ type: "host:error", message: "Passwords do not match." });
    return;
  }
  setError("sudo-error", "");
  vscode.postMessage({ type:"sudopasswd:set", password: a, confirm: b });
};
["sudo-pw","sudo-pw2"].forEach(id => {
  const el = $(id);
  el && el.addEventListener("input", () => setError("sudo-error",""));
});

// Tabs setup (and policy-gate the sudo tab)
(function tabs(){
  const tabLogin = $("tab-login");
  const tabSudo  = $("tab-sudo");
  const panelLogin = $("panel-login");
  const panelSudo  = $("panel-sudo");

  const allowSudo = !!INITIAL.ALLOW_SUDO_PASSWORD_CHANGE;
  if (!allowSudo) {
    tabSudo.setAttribute("aria-disabled","true");
    tabSudo.title = "Changing sudo password is disabled by policy.";
  }

  function activate(which){
    if (which === 'login') {
      tabLogin.classList.add('active'); tabLogin.setAttribute('aria-selected','true');
      tabSudo.classList.remove('active'); tabSudo.setAttribute('aria-selected','false');
      panelLogin.hidden = false; panelSudo.hidden = true;
    } else {
      tabSudo.classList.add('active'); tabSudo.setAttribute('aria-selected','true');
      tabLogin.classList.remove('active'); tabLogin.setAttribute('aria-selected','false');
      panelSudo.hidden = false; panelLogin.hidden = true;
    }
  }
  tabLogin.onclick = () => activate('login');
  tabSudo.onclick  = () => {
    if (tabSudo.getAttribute('aria-disabled') === 'true') return;
    activate('sudo');
  };
  activate('login');
})();

// config actions

$("cfg-run").onclick = () => {
  vscode.postMessage({
    type:"config:run",
    settings: $("cfg-settings").checked,
    keybindings: $("cfg-keyb").checked,
    tasks: $("cfg-tasks").checked,
    extensions: $("cfg-ext").checked
  });
};

//extension actions

$("ext-run").onclick = () => {
  vscode.postMessage({
    type:"ext:apply",
    uninstall: $("ext-un").value || "",
    install: $("ext-in").value || ""
  });
};

//gh actions

$("gh-auto").onchange = () => {
  $("gh-fields").style.display = $("gh-auto").checked ? "none" : "block";
};
$("gh-run").onclick = () => {
  const auto = $("gh-auto").checked;
  vscode.postMessage({
    type: "github:run",
    auto,
    username: auto ? "" : $("gh-user").value,
    token:    auto ? "" : $("gh-token").value,
    name:     auto ? "" : $("git-name").value,
    email:    auto ? "" : $("git-email").value,
    repos:    auto ? "" : $("gh-repos").value,
    pull:     auto ? undefined : $("gh-pull").checked
  });
};
