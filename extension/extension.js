const vscode = require('vscode');
const fs = require('fs');
const http = require('http');

let cliTerminal = null;
let outChan = null;
let reloadWatcher = null;
 
// Path the CLI will "touch" to request a window reload
const RELOAD_FLAG = '/run/codestrap/reload.flag';
const RELOAD_DIR  = '/run/codestrap';
let lastReloadNonce = 0;


function getActiveProfileInfo() {
  const api = vscode;
  const p = api?.profiles?.getCurrentProfile ? api.profiles.getCurrentProfile() : null;
  return {
    id:   (p && (p.id || '')) || '',
    name: (p && (p.name || '')) || ''
  };
}


// ----------------- PROFILES SUPPORT -----------------
function getTargetProfileName(){
  // Priority: env → query param (?profile=) → default
  const env = process.env.CODESTRAP_PROFILE;
  if (env && String(env).trim()) return String(env).trim();
  try {
    // code-server/web can expose a location with a query string; desktop won’t.
    const loc = globalThis && globalThis.location;
    if (loc && typeof loc.search === 'string') {
      const sp = new URLSearchParams(loc.search);
      const q = sp.get('profile');
      if (q && q.trim()) return q.trim();
    }
  } catch(_) {}
  return 'codestrap/default';
}

async function ensureCodestrapProfile(context){
  const api = vscode;
  const profiles = api && api.profiles;
  const targetName = getTargetProfileName();

  if (!profiles || !profiles.getAllProfiles || !profiles.createProfile || !profiles.switch) {
    // Not supported in this build — just log and continue without blocking.
    if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
    outChan.appendLine('[codestrap] Profiles API not available. Skipping profile create/switch.');
    return { supported:false, switched:false, created:false, name:targetName };
  }

  // Discover or create the target
  const all = profiles.getAllProfiles ? profiles.getAllProfiles() : [];
  let target = all.find(p => p && (p.name === targetName || p.id === targetName));
  let created = false;
  if (!target) {
    if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
    outChan.show(true);
    outChan.appendLine(`[codestrap] Creating VS Code profile: ${targetName}`);
    target = await profiles.createProfile(targetName, {
      settings: {},
      keybindings: [],
      tasks: undefined,
      snippets: undefined,
      extensions: { enabled: [], disabled: [] },
      globalState: {}
    });
    created = true;
  }

  // One-time switch guard per installation & per target
  const guardKey = `profile-switched:${target.name || targetName}`;
  let switched = false;
  if (!context.globalState.get(guardKey)) {
    if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
    outChan.appendLine(`[codestrap] Switching to profile: ${target.name || targetName}`);
    await profiles.switch(target);
    await context.globalState.update(guardKey, true);
    switched = true;
  } else {
    if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
    outChan.appendLine(`[codestrap] Profile already selected earlier: ${target.name || targetName}`);
  }

  return { supported:true, switched, created, name: target.name || targetName };
}

async function applyCodestrapInActiveProfile(){
  // Give the profile context a moment to settle
  await sleep(400);
  return new Promise((resolve) => {
    let done = 0; const mark = () => { done; if (done >= 2) resolve(); };
    runCodestrap('config', ['config','-s','true','-k','true','-t','true','-e','true'], {
      expectAck:true,
      postAck: () => mark()
    });
    runCodestrap('extensions', ['extensions','-u','missing','-i','all'], {
      expectAck:true,
      postAck: () => mark()
    });
  });
}
// ----------------------------------------------------

// Path the CLI will "touch" to request a VS Code profile switch
const PROFILE_SWITCH_FLAG = '/run/codestrap/profile.switch';
let lastProfileSwitchSeen = '';

// ---- helper: small sleep ----
function sleep(ms){ return new Promise(r => setTimeout(r, ms)); }

function shellQ(s){
  if (s === undefined || s === null) return "''";
  s = String(s); if (s === '') return "''";
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

// Single resolver that returns raw cmd + base args (used by spawn())
function resolveCodestrapCmd() {
  if (process.env.CODESTRAP_BIN && fs.existsSync(process.env.CODESTRAP_BIN)) {
    return { cmd: process.env.CODESTRAP_BIN, baseArgs: [] };
  }
  const cands = ['/usr/local/bin/codestrap','/usr/bin/codestrap'];
  for (const p of cands) if (fs.existsSync(p)) return { cmd: p, baseArgs: [] };
  if (fs.existsSync('/custom-cont-init.d/10-codestrap.sh')) {
    return { cmd: 'sh', baseArgs: ['/custom-cont-init.d/10-codestrap.sh','cli'] };
  }
  return null;
}

function runCodestrap(op, args, { expectAck=false, postAck } = {}) {
  // Single spawn() path for ALL commands (no TTY; we ACK on process exit)
  const r = resolveCodestrapCmd();
  if (!r) {
    vscode.window.showErrorMessage('codestrap not found (set CODESTRAP_BIN or install /usr/local/bin/codestrap).');
    if (expectAck && postAck) postAck({ type:'ack', op, ok:false });
    return;
  }
  if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
  outChan.show(true);
  outChan.appendLine(`$ codestrap ${args.join(' ')}`);

  // Force non-TTY so the CLI won’t try to read /dev/tty.
  // (Password flows use --set, so no interactive prompts.)
  const env = { ...process.env, CODESTRAP_NO_TTY: '1' };
  // Pass the active VS Code profile to the CLI so it writes into User/profiles/<id>
  try {
    const ap = getActiveProfileInfo();
    if (ap && ap.id) {
      env.CODESTRAP_PROFILE_ID = ap.id;
      env.CODESTRAP_PROFILE_NAME = ap.name || '';
    }
  } catch (_) {}
  const { spawn } = require('child_process');
  const fullArgs = [...r.baseArgs, ...args];
  const proc = spawn(r.cmd, fullArgs, { env });

  proc.stdout.on('data', d => outChan.append(d.toString()));
  proc.stderr.on('data', d => outChan.append(d.toString()));
  proc.on('error', (err) => {
    outChan.appendLine(`\n[error] ${err && err.message ? err.message : String(err)}`);
  });
  proc.on('close', (code, signal) => {
    const ok = code === 0;
    outChan.appendLine(`\n[exit] ${ok ? 'success' : 'failed'} (code ${code}${signal ? `, sig ${signal}` : ''})`);
    if (!ok) vscode.window.showErrorMessage(`Codestrap ${op} failed (exit ${code}). See "Codestrap" output for details.`);
    if (expectAck && postAck) postAck({ type:'ack', op, ok });
  });
}

function openCLI(){
  let term = vscode.window.terminals.find(t => t.name === 'Codestrap');
  if (!term) term = vscode.window.createTerminal({ name: 'Codestrap' });
  term.show(true);
  term.sendText('\u0015', false);
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
  GITHUB_PULL:     (process.env.GITHUB_PULL || '').toString(),
  ALLOW_SUDO_PASSWORD_CHANGE: false
};

function registerTerminalWatcher(context){
  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((term) => {
      if (cliTerminal && term === cliTerminal) cliTerminal = null;
    })
  );
}

function ensureReloadDir(){
  try { fs.mkdirSync(RELOAD_DIR, { recursive: true }); } catch(_) {}
}

function setupReloadWatcher(context){
  ensureReloadDir();
  // Create file with a benign marker so the first mtime doesn't trigger
  try { if (!fs.existsSync(RELOAD_FLAG)) fs.writeFileSync(RELOAD_FLAG, 'IDLE\n', { flag: 'w' }); } catch(_) {}
  // Use watchFile (polling) — reliable across container fs / bind mounts
  let pending = false;
  fs.watchFile(RELOAD_FLAG, { interval: 500 }, async () => {
    if (pending) return;
    try {
      const buf = fs.readFileSync(RELOAD_FLAG, 'utf8');
      const m = /^RELOAD:(\d+)\s*$/m.exec(buf);
      if (!m) return;                        // not a valid command → ignore
      const nonce = Number(m[1] || 0);
      if (!(nonce > lastReloadNonce)) return; // only act on strictly newer nonce
      pending = true;
      lastReloadNonce = nonce;
      // Acknowledge before reloading to avoid repeated triggers
      try { fs.writeFileSync(RELOAD_FLAG, `ACK:${nonce}\n`); } catch(_) {}
      await vscode.commands.executeCommand('workbench.action.reloadWindow');
    } catch(_) {
      // ignore
    } finally {
      pending = false;
    }
  });
  // Clean up on deactivate
  context.subscriptions.push(new vscode.Disposable(() => {
    try { fs.unwatchFile(RELOAD_FLAG); } catch(_) {}
  }));
}

// ===== Profile switch helper =====
async function execMaybe(cmd, ...args) {
  try { await vscode.commands.executeCommand(cmd, ...args); return true; }
  catch { return false; }
}

async function trySwitchProfile(profileName){
  if (!profileName || !profileName.trim()) return false;
  const name = profileName.trim();
  // Open output channel lazily so user can see what happened
  if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
  outChan.show(true);
  outChan.appendLine(`[codestrap] profile switch requested → "${name}"`);

  // Strategy:
  // 1) Try to switch (string → object → no-arg UI fallback avoided).
  // 2) If that likely didn’t work, try createswitch (string → object → no-arg).
  // 3) As a final fallback: create, then switch (various arg shapes).
  // NOTE: Some variants resolve without error even if they do nothing; we attempt several in sequence.
  let ok = false;
  const SWITCH = 'workbench.profiles.actions.switchProfile';
  const CREATE_SWITCH = 'workbench.profiles.actions.createAndSwitchProfile';
  const CREATE = 'workbench.profiles.actions.createProfile';

  // (1) Try switch first (existing profile)
  ok = await execMaybe(SWITCH, name)
    || await execMaybe(SWITCH, { profileName: name })
    || false; // avoid no-arg to prevent UI
  if (ok) outChan.appendLine(`[codestrap] executed: ${SWITCH} (switch attempt)`);

  // (2) If not ok yet, try create  switch in one go
  if (!ok) {
    ok = await execMaybe(CREATE_SWITCH, name)
      || await execMaybe(CREATE_SWITCH, { name })
      || false; // avoid no-arg UI
    if (ok) outChan.appendLine(`[codestrap] executed: ${CREATE_SWITCH} (createswitch)`);
  }

  // (3) If still not ok, try create then switch (two-step)
  if (!ok) {
    const created = await execMaybe(CREATE, name)
                 || await execMaybe(CREATE, { name })
                 || false; // avoid no-arg UI
    if (created) {
      outChan.appendLine(`[codestrap] executed: ${CREATE} (created)`);
      ok = await execMaybe(SWITCH, name)
        || await execMaybe(SWITCH, { profileName: name })
        || false;
      if (ok) outChan.appendLine(`[codestrap] executed: ${SWITCH} (switch after create)`);
    }
  }

  if (ok) {
    vscode.window.showInformationMessage(`Switched to profile: ${name}`);
  } else {
    vscode.window.showWarningMessage(`Could not switch to VS Code profile "${name}" automatically. You can switch it manually from the Profiles menu.`);
  }

  // Best-effort ACK so the initiator knows we acted
  try { fs.writeFileSync(PROFILE_SWITCH_FLAG, `ACK:${name}\n`, { flag: 'w' }); } catch(_) {}
  return ok;
}

async function afterProfileSwitchedApplyCodestrap(){
  // Give VS Code a short breath to settle profile context before applying ops
  await new Promise(r => setTimeout(r, 500));
  // Run config merge (all) and extension sync (uninstall missing, install/update all)
  // We ACK each to the UI output (not required by CLI sequencing).
  return new Promise(resolve => {
    let done = 0; const mark = () => { done; if (done >= 2) resolve(); };
    runCodestrap('config', ['config','-s','true','-k','true','-t','true','-e','true'], {
      expectAck: true,
      postAck: () => mark()
    });
    runCodestrap('extensions', ['extensions','-u','missing','-i','all'], {
      expectAck: true,
      postAck: () => mark()
    });
  });
}

function setupProfileSwitchWatcher(context){
  ensureReloadDir();
  // Ensure the file exists so the first poll baseline is stable
  try { if (!fs.existsSync(PROFILE_SWITCH_FLAG)) fs.writeFileSync(PROFILE_SWITCH_FLAG, 'IDLE\n', { flag: 'w' }); } catch(_) {}

  let busy = false;
  fs.watchFile(PROFILE_SWITCH_FLAG, { interval: 500 }, async () => {
    if (busy) return;
    busy = true;
    try {
      const txt = fs.readFileSync(PROFILE_SWITCH_FLAG, 'utf8').trim();
      // Expect a plain profile name, ignore ACK lines and empty/IDLE content
      if (!txt || txt === 'IDLE' || txt.startsWith('ACK:')) { busy = false; return; }
      if (txt === lastProfileSwitchSeen) { busy = false; return; }
      lastProfileSwitchSeen = txt;
      const switched = await trySwitchProfile(txt);
      if (switched) {
        // Once we’re in the target profile, apply codestrap flow here
        await afterProfileSwitchedApplyCodestrap();
      }
    } catch(_) {
      // ignore
    } finally {
      busy = false;
    }
  });

  context.subscriptions.push(new vscode.Disposable(() => {
    try { fs.unwatchFile(PROFILE_SWITCH_FLAG); } catch(_) {}
  }));
}

function getNonce(){ return Math.random().toString(36).slice(2); }

function buildCSP(cspSource, nonce){
  return [
    "default-src 'none'",
    `img-src ${cspSource} https: data:`,
    `font-src ${cspSource} data:`,
    `style-src ${cspSource} 'unsafe-inline'`,
    // allow external script from the webview origin AND inline by nonce
    `script-src ${cspSource} 'nonce-${nonce}'`
  ].join('; ');
}

function loadWebviewHtml(webview, context, initialJSON){
  const htmlUri = vscode.Uri.joinPath(context.extensionUri, 'sidepanel', 'webview.html');
  const jsUri   = webview.asWebviewUri(vscode.Uri.joinPath(context.extensionUri, 'sidepanel', 'webview.js'));
  const cssUri  = webview.asWebviewUri(vscode.Uri.joinPath(context.extensionUri, 'sidepanel', 'webview.css'));

  let raw = fs.readFileSync(htmlUri.fsPath, 'utf8');

  const nonce = getNonce();
  const csp   = buildCSP(webview.cspSource, nonce);
  const safeInitial = JSON.stringify(initialJSON).replace(/</g, '\\u003c');

  raw = raw
    .replace(/__CSP__/, csp)
    .replace(/__NONCE__/g, nonce)
    .replace(/__JS_URI__/g, jsUri.toString())
    .replace(/__CSS_URI__/g, cssUri.toString());

  // inject the INITIAL payload as a meta tag right after <head>
  raw = raw.replace(
    '<head>',
    `<head>\n  <meta id="codestrap-initial" data-json='${safeInitial}' />`
  );

  return raw;
}

class ViewProvider {
  constructor(context){
    this.context = context;
    // Parse policies.yml once (best-effort, no external deps)
    try {
      const p = '/config/.codestrap/policies.yml';
      if (fs.existsSync(p)) {
        const text = fs.readFileSync(p, 'utf8');
        // look for: allow-sudo-password-change: true (ignores whitespace & case)
        const m = /(^|\n)\s*allow-sudo-password-change\s*:\s*true\s*($|\n)/i.test(text);
        INITIALS.ALLOW_SUDO_PASSWORD_CHANGE = !!m;
      }
    } catch (_) {
      INITIALS.ALLOW_SUDO_PASSWORD_CHANGE = false;
    }
  }
  resolveWebviewView(webviewView){
    this.webview = webviewView.webview;
    this.webview.options = { enableScripts: true };
    this.webview.html = loadWebviewHtml(this.webview, this.context, INITIALS);

    this.webview.onDidReceiveMessage((msg) => {
      const postAck = (payload) => { try { this.webview?.postMessage(payload); } catch(_){} };
      switch (msg.type) {
        case 'open:docs': openDocs(); break;
        case 'open:cli':  openCLI();  break;
        case 'passwd:set': {
          const pw = msg.password || '';
          const cf = msg.confirm  || '';
          if (pw.length < 8) { vscode.window.showErrorMessage('Password must be at least 8 characters.'); return; }
          if (pw !== cf)     { vscode.window.showErrorMessage('Passwords do not match.'); return; }
          // Keep spinner until reboot; run (no ack)
          // Keep spinner until reboot; run (no ack)
          runCodestrap('passwd', ['passwd','--set', pw, cf], { expectAck:false });
          break; // no ack (spinner continues)
        }
        case 'sudopasswd:set': {
          if (!INITIALS.ALLOW_SUDO_PASSWORD_CHANGE) {
            vscode.window.showWarningMessage('Changing sudo password is disabled by policy.');
            return;
          }
          const pw = msg.password || '';
          const cf = msg.confirm  || '';
          if (pw.length < 8) { vscode.window.showErrorMessage('Password must be at least 8 characters.'); return; }
          if (pw !== cf)     { vscode.window.showErrorMessage('Passwords do not match.'); return; }
          // Keep spinner until reboot; run (no ack)
          runCodestrap('sudopasswd', ['sudopasswd','--set', pw, cf], { expectAck:false });
          break; // no ack (spinner continues)
        }
        case 'config:run': {
          const tf=(b)=> b?'true':'false';
          const args=['config'];
          if ('settings' in msg)   args.push('-s', tf(!!msg.settings));
          if ('keybindings' in msg)args.push('-k', tf(!!msg.keybindings));
          if ('tasks' in msg)      args.push('-t', tf(!!msg.tasks));
          if ('extensions' in msg) args.push('-e', tf(!!msg.extensions));
          // Run; ack when finished
          runCodestrap('config', args, { expectAck:true, postAck });
          break;
        }
        case 'ext:apply': {
          const args = ['extensions'];
          const un = (msg.uninstall || '').trim();
          const ins = (msg.install   || '').trim();

          if (un === '' && ins === '') {
            vscode.window.showWarningMessage('Select an Install or Uninstall scope first.');
            // If the webview started a spinner somehow, stop it.
            postAck && postAck({ type: 'ack', op: 'extensions', ok: false });
            break;
          }

          if (un === 'all' || un === 'missing') args.push('-u', un);
          if (ins === 'all' || ins === 'missing') args.push('-i', ins);

          // Run with NO TTY; ack when finished
          runCodestrap('extensions', args, { expectAck: true, postAck });
          break;
        }
        case 'github:run': {
          const args=['github'];
          if (msg.fill_env || msg.auto) {
            args.push('--auto');
          } else {
            if (msg.username) args.push('-u', msg.username);
            if (msg.token)    args.push('-t', msg.token);
            if (msg.name)     args.push('-n', msg.name);
            if (msg.email)    args.push('-e', msg.email);
            if (msg.repos)    args.push('-r', msg.repos);
            if ('pull' in msg)args.push('-p', String(!!msg.pull));
          }
          // Run; ack when finished
          runCodestrap('github', args, { expectAck:true, postAck });
          break;
        }
        //case 'host:error': {
        //    if (msg && msg.message) vscode.window.showErrorMessage(String(msg.message));
        //    break;
        //}
        case 'reboot': callRestartGate(); break;
      }
    });
  }
}

function activate(context){
  // 1) Ensure we’re in the right profile (create if missing, switch once)
  ensureCodestrapProfile(context)
    .then(async (res) => {
      if (res.supported && (res.switched || res.created)) {
        // Apply Codestrap after profile is set/created
        await applyCodestrapInActiveProfile();
      }
    })
    .catch((e) => {
      if (!outChan) outChan = vscode.window.createOutputChannel('Codestrap');
      outChan.appendLine(`[codestrap] Profile init error: ${e && e.message ? e.message : String(e)}`);
    });

  const provider = new ViewProvider(context);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('codestrap.view', provider, { webviewOptions: { retainContextWhenHidden: true } })
  );
  context.subscriptions.push(vscode.commands.registerCommand('codestrap.open', () =>
    vscode.commands.executeCommand('workbench.view.extension.codestrap')
  ));
  context.subscriptions.push(vscode.commands.registerCommand('codestrap.refresh', () => {}));
  registerTerminalWatcher(context);
  setupReloadWatcher(context);
  setupProfileSwitchWatcher(context);
}
function deactivate(){}

module.exports = { activate, deactivate };
