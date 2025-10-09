/* global acquireVsCodeApi */
const vscode = acquireVsCodeApi();
const meta = document.getElementById('codestrap-initial');
const INITIAL = meta ? JSON.parse(meta.dataset.json || '{}') : {};

// helpers
const $ = (id) => document.getElementById(id);
const togglePw = (inputId) => { const el = $(inputId); el.type = (el.type === 'password') ? 'text' : 'password'; };

function setButtonLoading(btnId, isLoading) {
  const btn = $(btnId);
  if (!btn) return;
  if (isLoading) {
    btn.classList.add('loading');
    btn.disabled = true;
  } else {
    btn.classList.remove('loading');
    btn.disabled = false;
  }
}

// --- small helpers for repo field ---
function csvToMultiline(s){
  return (s||"")
    .split(",")
    .map(x=>x.trim())
    .filter(Boolean)
    .join("\n");
}
function multilineToCSV(s){
  // accept commas OR newlines, collapse spaces, de-dupe empties
  return (s||"")
    .split(/\r?\n|,/)
    .map(x=>x.trim())
    .filter(Boolean)
    .join(",");
}
function autoResizeTextarea(el){
  if (!el) return;
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight, 320)  "px";
}


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

// --- GitHub env  manual snapshot handling ---
const ENV_GH = {
  user:  INITIAL.GITHUB_USERNAME || "",
  token: INITIAL.GITHUB_TOKEN    || "",
  name:  INITIAL.GIT_NAME        || "",
  email: INITIAL.GIT_EMAIL       || "",
  repos: INITIAL.GITHUB_REPOS    || "",
  pull:  (()=>{
    const v = String(INITIAL.GITHUB_PULL || "").trim().toLowerCase();
    return ['1','y','yes','t','true','on'].includes(v);
  })()
};

// If there’s nothing to fill from env, hide the "Use env vars" toggle entirely
(() => {
  const anyEnv =
    !!(ENV_GH.user || ENV_GH.token || ENV_GH.name || ENV_GH.email || ENV_GH.repos ||
       String(INITIAL.GITHUB_PULL || "").trim()); // presence of var, even if "false"
  const row = $("gh-env-row");
  if (row && !anyEnv) {
    row.style.display = "none";
    // also make sure inputs remain enabled
    ["gh-user","gh-token","git-name","git-email","gh-repos","gh-pull"].forEach(id=>{
      const el=$(id); if (el) el.disabled = false;
    });
  }
})();

// What the user has typed (persisted while "Use env vars" toggles on/off)
const MANUAL_GH = { user:"", token:"", name:"", email:"", repos:"", pull:$("gh-pull").checked };

function setGhFields({user, token, name, email, repos, pull}, {disable=false} = {}){
  $("gh-user").value  = user;
  $("gh-token").value = token;
  $("git-name").value = name;
  $("git-email").value= email;
  $("gh-repos").value = csvToMultiline(repos);
  autoResizeTextarea($("gh-repos"));
  if (typeof pull === "boolean") $("gh-pull").checked = pull;

  // lock/unlock while env is active
  ["gh-user","gh-token","git-name","git-email","gh-repos","gh-pull"].forEach(id=>{
    const el=$(id); if (!el) return;
    el.disabled = !!disable;
  });
}

// Track manual edits only when NOT using env vars
["gh-user","gh-token","git-name","git-email","gh-repos"].forEach(id=>{
  const el = $(id);
  el && el.addEventListener("input", () => {
    if ($("gh-fill-env").checked) return;
    MANUAL_GH.user  = $("gh-user").value;
    MANUAL_GH.token = $("gh-token").value;
    MANUAL_GH.name  = $("git-name").value;
    MANUAL_GH.email = $("git-email").value;
    MANUAL_GH.repos = $("gh-repos").value; // store as multiline
  });
});
$("gh-pull").addEventListener("change", () => {
  if ($("gh-fill-env").checked) return;
  MANUAL_GH.pull = $("gh-pull").checked;
});

// Repos textarea: live comma→newline & autoresize, normalize pasted CSV
(function wireReposTextarea(){
  const el = $("gh-repos");
  if (!el) return;
  const normalize = () => {
    const cur = el.selectionStart;
    let v = el.value;
    // turn any commas (with optional spaces) into newlines
    if (/,/.test(v)) v = v.replace(/,\s*/g, "\n");
    // collapse multiple blank lines
    v = v.replace(/\n{2,}/g, "\n");
    el.value = v;
    // keep caret position sensible
    const pos = Math.min(cur, v.length);
    el.selectionStart = el.selectionEnd = pos;
    autoResizeTextarea(el);
  };
  el.addEventListener("input", normalize);
  el.addEventListener("paste", (e) => {
    // allow normal paste; normalize on next tick
    setTimeout(normalize, 0);
  });
  // initial size
  autoResizeTextarea(el);
})();

// submit on enter
function setupEnterToSubmit(sectionId, buttonId) {
  const sec = $(sectionId);
  const btn = $(buttonId);
  if (!sec || !btn) return;

  sec.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;

    // Don’t hijack Enter for actual buttons (let them click themselves)
    const tag = e.target && e.target.tagName ? e.target.tagName.toLowerCase() : '';
    if (tag === 'button') return;

    // Prevent default so it doesn't trigger other unintended behaviors
    e.preventDefault();
    btn.click();
  });
}

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
  // spinner continues until reboot (no ack expected)
  setButtonLoading("login-run", true);
  vscode.postMessage({ type:"passwd:set", password: a, confirm: b });
};

// Optional: live-clear the inline error while typing
["login-pw","login-pw2"].forEach(id => {
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
  // spinner continues until reboot (no ack expected)
  setButtonLoading("sudo-run", true);
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
    tabSudo.tabIndex = -1;
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
  setButtonLoading("cfg-run", true);
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
  const uninstall = ($("ext-un").value || "").trim();
  const install   = ($("ext-in").value || "").trim();

  // Require at least one scope
  if (!uninstall && !install) {
    setError("ext-error", "Choose an Install or Uninstall scope first.");
    return; // do NOT start spinner
  }

  // clear any previous error
  setError("ext-error", "");

  setButtonLoading("ext-run", true);
  vscode.postMessage({
    type: "ext:apply",
    uninstall,
    install
  });
};

// Clear the error whenever the user picks a scope
["ext-un","ext-in"].forEach(id => {
  const el = $(id);
  el && el.addEventListener("change", () => {
    const un = ($("ext-un").value || "").trim();
    const ins = ($("ext-in").value || "").trim();
    if (un || ins) setError("ext-error", "");
  });
});


// gh actions
// Toggle: when ON → fill with env  disable; when OFF → restore manual  enable
$("gh-fill-env").onchange = () => {
  if ($("gh-fill-env").checked) {
    // snapshot what user had before locking (only take if fields are enabled)
    if (!$("gh-user").disabled) {
      MANUAL_GH.user  = $("gh-user").value;
      MANUAL_GH.token = $("gh-token").value;
      MANUAL_GH.name  = $("git-name").value;
      MANUAL_GH.email = $("git-email").value;
      MANUAL_GH.repos = $("gh-repos").value; // keep multiline snapshot
      MANUAL_GH.pull  = $("gh-pull").checked;
    }
    setGhFields({
      user:  ENV_GH.user,
      token: ENV_GH.token,
      name:  ENV_GH.name,
      email: ENV_GH.email,
      repos: ENV_GH.repos, // converted to multiline inside setGhFields
      pull:  ENV_GH.pull
    }, { disable:true });
  } else {
    setGhFields(MANUAL_GH, { disable:false });
  }
};
$("gh-run").onclick = () => {
  setButtonLoading("gh-run", true);
  const fill_env = $("gh-fill-env").checked;
  vscode.postMessage({
    type: "github:run",
    fill_env,
    username: fill_env ? "" : $("gh-user").value,
    token:    fill_env ? "" : $("gh-token").value,
    name:     fill_env ? "" : $("git-name").value,
    email:    fill_env ? "" : $("git-email").value,
    // CLI expects comma-separated specs
    repos:    fill_env ? "" : multilineToCSV($("gh-repos").value),
    pull:     fill_env ? undefined : $("gh-pull").checked
  });
};

// Enter submits current panel/section
setupEnterToSubmit('panel-login', 'login-run');
setupEnterToSubmit('panel-sudo', 'sudo-run');
setupEnterToSubmit('sec-config', 'cfg-run');
setupEnterToSubmit('sec-ext',    'ext-run');
setupEnterToSubmit('sec-github', 'gh-run');

// Stop spinners when host ACKs completion (non-reboot ops only)
window.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type !== 'ack') return;
  switch (data.op) {
    case 'config':
      setButtonLoading('cfg-run', false);
      if (data.ok === false) alert('Config merge failed. Check "Codestrap" output.');
      break;
    case 'extensions':
      setButtonLoading('ext-run', false);
      if (data.ok === false) alert('Extensions operation failed. Check "Codestrap" output.');
      break;
    case 'github':
      setButtonLoading('gh-run', false);
      if (data.ok === false) alert('GitHub bootstrap failed. Check "Codestrap" output.');
      break;
    // passwd/sudopasswd: no ack => spinner keeps spinning until reboot refreshes the webview
  }
});