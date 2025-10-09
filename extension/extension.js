const vscode = require('vscode');
const fs = require('fs');
const http = require('http');

let cliTerminal = null;
let outChan = null;

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
  const provider = new ViewProvider(context);
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
