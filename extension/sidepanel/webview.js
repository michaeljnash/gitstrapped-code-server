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
$("pw-eye").onclick  = () => togglePw("pw");
$("pw2-eye").onclick = () => togglePw("pw2");
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

// actions
$("pw-run").onclick = () => {
  const a = $("pw").value || "";
  const b = $("pw2").value || "";
  if (a.length < 8) {
    vscode.postMessage({ type: "host:error", message: "Password must be at least 8 characters." });
    return;
  }
  if (a !== b) {
    vscode.postMessage({ type: "host:error", message: "Passwords do not match." });
    return;
  }
  vscode.postMessage({ type:"passwd:set", password: a, confirm: b });
};

$("cfg-run").onclick = () => {
  vscode.postMessage({
    type:"config:run",
    settings: $("cfg-settings").checked,
    keybindings: $("cfg-keyb").checked,
    tasks: $("cfg-tasks").checked,
    extensions: $("cfg-ext").checked
  });
};

$("ext-run").onclick = () => {
  vscode.postMessage({
    type:"ext:apply",
    uninstall: $("ext-un").value || "",
    install: $("ext-in").value || ""
  });
};

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
