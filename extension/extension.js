const vscode = require('vscode');
const fs = require('fs');
const http = require('http');

let cliTerminal = null;

function shellQ(s){
  if (s === undefined || s === null) return "''";
  s = String(s); if (s === '') return "''";
  return `'${s.replace(/'/g, `'\\''`)}'`;
}
function resolveCodestrapString(){
  if (process.env.CODESTRAP_BIN && fs.existsSync(process.env.CODESTRAP_BIN)) return shellQ(process.env.CODESTRAP_BIN);
  const cands = ['/usr/local/bin/codestrap','/usr/bin/codestrap'];
  for (const p of cands) if (fs.existsSync(p)) return shellQ(p);
  if (fs.existsSync('/custom-cont-init.d/10-codestrap.sh')) return `sh ${shellQ('/custom-cont-init.d/10-codestrap.sh')} cli`;
  return null;
}
function buildAndRun(args){
  const runner = resolveCodestrapString();
  if (!runner) { vscode.window.showErrorMessage('codestrap not found (set CODESTRAP_BIN or install /usr/local/bin/codestrap).'); return; }
  const t = vscode.window.createTerminal({ name: 'Codestrap' });
  t.sendText(`${runner} ${args.join(' ')}`, true);
  t.show(true);
}

// Open/reuse a "Codestrap" terminal and ensure "codestrap" is freshly typed at the prompt
function openCLI(){
  // Reuse existing terminal if present, else create it
  let term = vscode.window.terminals.find(t => t.name === 'Codestrap');
  if (!term) {
    term = vscode.window.createTerminal({ name: 'Codestrap' });
  }
  term.show(true);

  // Clear any unsubmitted input on the current line (Ctrl+U in bash/zsh/readline)
  term.sendText('\u0015', false);

  // Type the command without executing it
  term.sendText('codestrap', false);

  cliTerminal = term;
}

function openDocs(){
  const url = process.env.CODESTRAP_DOCS_URL || 'https://REPLACEME.com';
  vscode.env.openExternal(vscode.Uri.parse(url));
}

function callRestartGate(){
  const req = http.request({ hostname:'127.0.0.1', port:9000, path:'/restart', method:'GET', timeout:2000 }, () => {});
  req.on('error', () => {});
  req.end();
  vscode.window.showInformationMessage('Reboot requested.');
}

const INITIALS = {
  GITHUB_USERNAME: process.env.GITHUB_USERNAME || '',
  GITHUB_TOKEN:    process.env.GITHUB_TOKEN    || '',
  GIT_NAME:        (process.env.GIT_NAME || process.env.GITHUB_USERNAME || ''),
  GIT_EMAIL:       process.env.GIT_EMAIL       || '',
  GITHUB_REPOS:    process.env.GITHUB_REPOS    || '',
  GITHUB_PULL:     (process.env.GITHUB_PULL || '').toString()
};

function registerTerminalWatcher(context){
  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((term) => {
      if (cliTerminal && term === cliTerminal) {
        cliTerminal = null;
      }
    })
  );
}

class ViewProvider {
  resolveWebviewView(webviewView){
    this.webview = webviewView.webview;
    this.webview.options = { enableScripts: true };
    const nonce = String(Math.random()).slice(2);
    const src = this.webview.cspSource;
    const initialJSON = JSON.stringify(INITIALS).replace(/</g, '\\u003c');

    this.webview.html = this.html(nonce, src, initialJSON);
    this.webview.onDidReceiveMessage((msg) => {
      switch (msg.type) {
        case 'open:docs': openDocs(); break;
        case 'open:cli':  openCLI();  break;
        case 'passwd:set': {
          const pw = msg.password || '';
          const cf = msg.confirm  || '';
          if (pw.length < 8) { vscode.window.showErrorMessage('Password must be at least 8 characters.'); return; }
          if (pw !== cf)     { vscode.window.showErrorMessage('Passwords do not match.'); return; }
          buildAndRun(['passwd','--set', shellQ(pw), shellQ(cf)]);
          break;
        }
        case 'config:run': {
          const tf=(b)=> b?'true':'false';
          const args=['config'];
          if ('settings' in msg)   args.push('-s', tf(!!msg.settings));
          if ('keybindings' in msg)args.push('-k', tf(!!msg.keybindings));
          if ('tasks' in msg)      args.push('-t', tf(!!msg.tasks));
          if ('extensions' in msg) args.push('-e', tf(!!msg.extensions));
          buildAndRun(args.map(a => a.startsWith('-')? a : shellQ(a)));
          break;
        }
        case 'ext:apply': {
          const args=['extensions'];
          if (msg.uninstall==='all' || msg.uninstall==='missing') args.push('-u', msg.uninstall);
          if (msg.install==='all'   || msg.install==='missing')   args.push('-i', msg.install);
          buildAndRun(args.map(a => a.startsWith('-')? a : shellQ(a)));
          break;
        }
        case 'github:run': {
          const args=['github'];
          if (msg.auto) {
            args.push('--auto');
          } else {
            if (msg.username) args.push('-u', msg.username);
            if (msg.token)    args.push('-t', msg.token);
            if (msg.name)     args.push('-n', msg.name);
            if (msg.email)    args.push('-e', msg.email);
            if (msg.repos)    args.push('-r', msg.repos);
            if ('pull' in msg)args.push('-p', String(!!msg.pull));
          }
          buildAndRun(args.map(a => a.startsWith('-')? a : shellQ(a)));
          break;
        }
        case 'reboot': callRestartGate(); break;
      }
    });
  }

  html(nonce, cspSource, initialJSON){
    const csp = [
      "default-src 'none'",
      `img-src ${cspSource} https: data:`,
      `font-src ${cspSource} data:`,
      `style-src ${cspSource} 'unsafe-inline'`,
      `script-src 'nonce-${nonce}'`
    ].join('; ');
    return `<!doctype html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="${csp}" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Codestrap</title>
  <style>
    :root{
      --bg: var(--vscode-sideBar-background);
      --fg: var(--vscode-foreground);
      --muted: var(--vscode-descriptionForeground);
      --btn: var(--vscode-button-background);
      --btnText: var(--vscode-button-foreground);
      --border: var(--vscode-panel-border);
      --input: var(--vscode-input-background);
      --eyeGrey: #8a8a8a;
    }
    *, *::before, *::after { box-sizing: border-box; }
    html, body { height: 100%; }
    /* eliminate double scrollbars: only #app scrolls */
    body{ margin:0; padding:0; overflow:hidden; font-family: var(--vscode-font-family); color: var(--fg); background: var(--bg); }
    #app{ height:100vh; overflow:auto; padding:12px; }

    h3{ margin:12px 0 8px; font-size:13px; }
    .section{ border:1px solid var(--border); border-radius:12px; padding:12px; margin-bottom:10px; }
    label{ font-size:12px; display:block; margin:6px 0 2px; color: var(--muted); }
    input[type="text"], input[type="password"], select{
      width:100%; max-width:100%; display:block; padding:8px 10px; background:var(--input); color:var(--fg);
      border:1px solid var(--border); border-radius:8px;
    }
    .row{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; }

    /* Top buttons: either all inline OR all stacked (never 2/1 wrap) */
    .toprow{
      display:flex; gap:8px; margin-bottom:8px; justify-content:center;
      flex-direction: row;
    }
    .toprow button{ min-width:120px; }
    /* Stack only when VERY narrow (tighter breakpoint) */
    @media (max-width: 400px){
      .toprow{ flex-direction: column; }
      .toprow button{ width:100%; }
    }

    button{
      border:0; border-radius:8px; background:var(--btn); color:var(--btnText);
      padding:6px 12px; cursor:pointer; position:relative;
    }

    /* Proper centered spinner when .loading is set (no text shown) */
    @keyframes spin { from { transform: rotate(0deg);} to { transform: rotate(360deg);} }
    .loading{ color: transparent !important; }
    .loading::before{
      content:"";
      position:absolute; left:50%; top:50%;
      margin-left:-8px; margin-top:-8px;
      width:16px; height:16px; border-radius:50%;
      border:2px solid rgba(255,255,255,0.25);
      border-top-color: rgba(255,255,255,0.95);
      animation: spin 0.8s linear infinite;
    }

    /* Eye icon controls (fixed right alignment and color) */
    .input-with-eye{ position:relative; }
    .eye-btn{
      position:absolute; top:50%; right:8px; transform:translateY(-50%);
      display:inline-flex; align-items:center; justify-content:center;
      width:22px; height:22px; background:transparent; border:0; cursor:pointer; padding:0; margin:0;
      color: var(--eyeGrey) !important; -webkit-text-fill-color: var(--eyeGrey); outline: none;
    }
    .eye-btn svg { width:16px; height:16px; stroke: currentColor; fill: none; }
    .pad-right-eye{ padding-right:44px; }

    .small{ font-size:11px; color: var(--muted); }
    .center-row{ justify-content:center; }
  </style>
</head>
<body>
  <div id="app">
    <div class="toprow">
      <button id="btn-docs">Docs</button>
      <button id="btn-cli">CLI</button>
      <button id="reboot">Reboot</button>
    </div>

    <div class="section" id="sec-passwd">
      <h3>Change password (<code>\`codestrap passwd\`</code>)</h3>

      <label>New password</label>
      <div class="input-with-eye">
        <input id="pw" type="password" class="pad-right-eye" placeholder="at least 8 characters" />
        <button class="eye-btn" type="button" id="pw-eye" title="Show/Hide" aria-label="Show/Hide">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7Z"/><circle cx="12" cy="12" r="3"/></svg>
        </button>
      </div>

      <label style="margin-top:6px;">Confirm password</label>
      <div class="input-with-eye">
        <input id="pw2" type="password" class="pad-right-eye" placeholder="re-enter password" />
        <button class="eye-btn" type="button" id="pw2-eye" title="Show/Hide" aria-label="Show/Hide">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7Z"/><circle cx="12" cy="12" r="3"/></svg>
        </button>
      </div>

      <div class="row center-row" style="margin-top:8px;">
        <button id="pw-run">Change</button>
      </div>
    </div>

    <div class="section" id="sec-config">
      <h3>Bootstrap config (\`<code>codestrap config</code>\`)</h3>
      <div class="row"><label><input type="checkbox" id="cfg-settings" checked /> Merge <code>settings.json</code></label></div>
      <div class="row"><label><input type="checkbox" id="cfg-keyb" checked /> Merge <code>keybindings.json</code></label></div>
      <div class="row"><label><input type="checkbox" id="cfg-tasks" checked /> Merge <code>tasks.json</code></label></div>
      <div class="row"><label><input type="checkbox" id="cfg-ext" checked /> Merge <code>extensions.json</code></label></div>
      <div class="row center-row" style="margin-top:8px;">
        <button id="cfg-run">Merge</button>
        <span class="small">Merge codestrap config files into user config files</span>
      </div>
    </div>

    <div class="section" id="sec-ext">
      <h3>Manage extensions (codestrap <code>extensions</code>)</h3>
      <label>Uninstall scope</label>
      <select id="ext-un">
        <option value="">(none)</option>
        <option value="missing">missing (cleanup)</option>
        <option value="all">all (remove everything)</option>
      </select>
      <label style="margin-top:6px;">Install scope</label>
      <select id="ext-in">
        <option value="">(none)</option>
        <option value="missing">missing</option>
        <option value="all">all (update to latest)</option>
      </select>
      <div class="row center-row" style="margin-top:8px;">
        <button id="ext-run">Apply</button>
      </div>
    </div>

    <div class="section" id="sec-github">
      <h3>Bootstrap GitHub (codestrap <code>github</code>)</h3>
      <div class="row"><label><input type="checkbox" id="gh-auto" /> Use <code>--auto</code> (env vars)</label></div>
      <div id="gh-fields">
        <label>Username</label>
        <input id="gh-user" type="text" placeholder="GITHUB_USERNAME" />
        <label>Token (classic)</label>
        <div class="input-with-eye">
          <input id="gh-token" type="password" class="pad-right-eye" placeholder="GITHUB_TOKEN" />
          <button class="eye-btn" type="button" id="gh-token-eye" title="Show/Hide" aria-label="Show/Hide">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7Z"/><circle cx="12" cy="12" r="3"/></svg>
          </button>
        </div>
        <label>Name (blank=use GitHub username)</label>
        <input id="git-name" type="text" placeholder="GIT_NAME" />
        <label>Email (blank=use GitHub account email)</label>
        <input id="git-email" type="text" placeholder="GIT_EMAIL" />
        <label>Repos (comma-separated owner/repo or owner/repo#branch or URLs)</label>
        <input id="gh-repos" type="text" placeholder="GITHUB_REPOS" />
        <div class="row"><label><input type="checkbox" id="gh-pull" checked /> Pull existing repos (fast-forward)</label></div>
      </div>
      <div class="row center-row" style="margin-top:8px;">
        <button id="gh-run">Run</button>
      </div>
    </div>
  </div><!-- /#app -->

<script nonce="${nonce}">
const vscode = acquireVsCodeApi();
const INITIAL = ${initialJSON};

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
    // webview should be torn down by restart
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
  if (INITIAL.GIT_NAME)        $("git-name").value = INITIAL_GIT_NAME;
  if (INITIAL.GIT_EMAIL)       $("git-email").value = INITIAL.GIT_EMAIL;
  if (INITIAL.GITHUB_REPOS)    $("gh-repos").value = INITIAL_GITHUB_REPOS;

  if (INITIAL.GITHUB_PULL) {
    const v = String(INITIAL.GITHUB_PULL).trim().toLowerCase();
    $("gh-pull").checked = ['1','y','yes','t','true','on'].includes(v);
  }
})();

// actions
$("pw-run").onclick = () => {
  const a = $("pw").value || "";
  const b = $("pw2").value || "";
  if (a.length < 8) { vscode.window.showErrorMessage('Password must be at least 8 characters.'); return; }
  if (a !== b)      { vscode.window.showErrorMessage('Passwords do not match.'); return; }
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
</script>
</body>
</html>`;
  }
}

function activate(context){
  const provider = new ViewProvider();
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('codestrap.view', provider, { webviewOptions: { retainContextWhenHidden: true } })
  );
  context.subscriptions.push(vscode.commands.registerCommand('codestrap.open', () =>
    vscode.commands.executeCommand('workbench.view.extension.codestrap')
  ));
  context.subscriptions.push(vscode.commands.registerCommand('codestrap.refresh', () => {}));

  registerTerminalWatcher(context);
}
function deactivate(){}
module.exports = { activate, deactivate };