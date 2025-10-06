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
  GITHUB_PULL:     (process.env.GITHUB_PULL || '').toString()
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
  constructor(context){ this.context = context; }
  resolveWebviewView(webviewView){
    this.webview = webviewView.webview;
    this.webview.options = { enableScripts: true };
    this.webview.html = loadWebviewHtml(this.webview, this.context, INITIALS);

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
