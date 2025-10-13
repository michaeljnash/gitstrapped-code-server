// codestrap-proxy.js — Reverse proxy + outage reload (root-only) + optional docker logs
//
// Behavior:
// - If upstream (code-server) is DOWN: serve splash (503) that auto-polls to return.
// - If upstream is UP: proxy normally, BUT we inject a watchdog only into the
//   MAIN APP SHELL HTML ("/" or "/login"), not into webviews/assets.
//   The watchdog polls /__up; on non-200 or network error → location.reload().
//
// This avoids breaking VS Code webviews (strict CSP) and any HTML that isn't the shell.
//
// ENV:
//   PROXY_PORT         (default 8080)
//   CODE_SERVICE_NAME  (compose service name, e.g. "code")
//   CODE_EXPOSED_PORT  (default 8443)
//   UP_TIMEOUT_MS      (default 2500)
//   LOG_CAP            (default 500)
//   DOCKER_SOCK        (default "/var/run/docker.sock")

const http = require('http');
const net  = require('net');
const url  = require('url');
const fs   = require('fs');
const zlib = require('zlib');
const crypto = require('crypto');

const AUTH_SECRET = 'CHANGEME-super-secret'; // >>> set this in prod
const AUTH_DIR = '/config/codestrap/profile_auth';
const SESSION_COOKIE = 'cs_profile_sess';
const SESSION_TTL_SEC = +(process.env.SESSION_TTL_SEC || 12*60*60); // 12h

// ADD: writable base for profile dirs (used by /__ensure_profile_dirs)
const PROFILE_DATA_BASE = '/config/codestrap/profile_data';


const PROXY_PORT        = +(process.env.PROXY_PORT || 8080);
const CODE_SERVICE_NAME = process.env.CODE_SERVICE_NAME || '';
const CODE_EXPOSED_PORT = +(process.env.CODE_EXPOSED_PORT || 8443);
const UPSTREAM_CONNECT_TIMEOUT_MS = +(process.env.UP_TIMEOUT_MS || 2500);

const PROFILES_DIR = '/config/codestrap/profiles';

const LOG_CAP     = +(process.env.LOG_CAP || 500);
const DOCKER_SOCK = process.env.DOCKER_SOCK || '/var/run/docker.sock';

function ts(){ return new Date().toISOString().replace('T',' ').replace('Z','Z'); }

/* --------------------- tiny logger (ring buffer + SSE) --------------------- */
let logBuf = [];
let sseClients = new Set();
function pushLog(line){
  const msg = `[proxy ${ts()}] ${line}`;
  logBuf.push(msg);
  if (logBuf.length > LOG_CAP) logBuf = logBuf.slice(-LOG_CAP);
  const payload = `data: ${msg.replace(/\r?\n/g,' ')}\n\n`;
  for (const res of sseClients) { try{res.write(payload);}catch(_){} }
}
function getLogsText(){ return logBuf.join('\n') + (logBuf.length?'\n':''); }

/* --------------------- upstream health check --------------------- */
let lastUp = null;
function upstreamAlive(cb){
  const s = net.connect({ host: CODE_SERVICE_NAME || '127.0.0.1', port: CODE_EXPOSED_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error',  ()=>finish(false));
  s.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS, ()=>finish(false));
}
function probeAndNote(cb){
  upstreamAlive(ok=>{
    if (lastUp === null) pushLog(`upstream initial state: ${ok ? 'UP' : 'DOWN'} (${CODE_SERVICE_NAME}:${CODE_EXPOSED_PORT})`);
    else if (ok !== lastUp) pushLog(`upstream state change: ${ok ? 'UP' : 'DOWN'}`);
    lastUp = ok;
    cb(ok);
  });
}

/* --------------------- Docker logs (via socket) ---------------------------- */
const docker = { enabled:false, socketPath: DOCKER_SOCK, containerId:null, wantLogs:false };
try { fs.accessSync(DOCKER_SOCK); docker.enabled=true; } catch(_) { docker.enabled=false; }
docker.wantLogs = docker.enabled && !!CODE_SERVICE_NAME;

function dockerRequest(path, method='GET', headers={}, cb){
  const req = http.request({ socketPath: docker.socketPath, path, method, headers }, res=>cb(null,res));
  req.on('error', err=>cb(err)); req.end();
}
function jsonEncodeFilters(obj){ return encodeURIComponent(JSON.stringify(obj)); }

function resolveContainerId(cb){
  if (!docker.wantLogs) return cb(new Error('logs disabled'), null);
  if (docker.containerId) return cb(null, docker.containerId);
  const filters = { label: [`com.docker.compose.service=${CODE_SERVICE_NAME}`] };
  const path = `/v1.41/containers/json?all=0&filters=${jsonEncodeFilters(filters)}`;
  dockerRequest(path, 'GET', {}, (err, res)=>{
    if (err) return cb(err);
    let body=''; res.setEncoding('utf8');
    res.on('data', c=>body+=c);
    res.on('end', ()=>{
      try{
        let arr = JSON.parse(body);
        if (!Array.isArray(arr) || arr.length===0) {
          dockerRequest(`/v1.41/containers/json?all=0`, 'GET', {}, (e2, r2)=>{
            if (e2) return cb(e2);
            let b2=''; r2.setEncoding('utf8'); r2.on('data',c=>b2+=c);
            r2.on('end', ()=>{
              try{
                const all = JSON.parse(b2);
                const hit = all.find(c =>
                  (c.Labels && c.Labels['com.docker.compose.service'] === CODE_SERVICE_NAME) ||
                  (Array.isArray(c.Names) && c.Names.some(n=>n.includes(`/${CODE_SERVICE_NAME}`)))
                );
                if (hit){ docker.containerId = hit.Id; cb(null, docker.containerId); }
                else cb(new Error('no container matched service'), null);
              }catch(e){ cb(e); }
            });
          });
          return;
        }
        docker.containerId = arr[0].Id; cb(null, docker.containerId);
      }catch(e){ cb(e); }
    });
  });
}
function createDockerDemux(onLine){
  let buf = Buffer.alloc(0), assumeTTY=false, badHeaders=0;
  function emitText(b){ b.toString('utf8').split(/\r?\n/).forEach(l=>{ if(l.length) onLine(l); }); }
  return function onChunk(chunk){
    if (assumeTTY){ emitText(chunk); return; }
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 8) {
      const stream = buf.readUInt8(0);
      const length = buf.readUInt32BE(4);
      if (length > 10*1024*1024){ badHeaders++; if (badHeaders>=2){ assumeTTY=true; emitText(buf); buf=Buffer.alloc(0);} break; }
      if (buf.length < 8 + length) break;
      const payload = buf.subarray(8, 8+length);
      const prefix = stream===2 ? '[stderr] ' : '';
      payload.toString('utf8').split(/\r?\n/).forEach(l=>{ if(l.length) onLine(prefix+l); });
      buf = buf.subarray(8+length);
    }
  };
}
function fetchDockerLogsTail(containerId, tail, cb){
  const p = `/v1.41/containers/${encodeURIComponent(containerId)}/logs?stdout=1&stderr=1&tail=${tail||200}`;
  dockerRequest(p, 'GET', {}, (err, res)=>{
    if (err) return cb(err);
    const chunks=[]; const demux=createDockerDemux(line=>chunks.push(line));
    res.on('data', chunk=>demux(chunk));
    res.on('end', ()=> cb(null, chunks.join('\n') + (chunks.length?'\n':'')));
  });
}
function streamDockerLogs(containerId, res, sinceSec){
  const since = Math.max(0, sinceSec|0);
  const path = `/v1.41/containers/${encodeURIComponent(containerId)}/logs?stdout=1&stderr=1&follow=1&since=${since}`;
  dockerRequest(path, 'GET', {}, (err, dres)=>{
    if (err || dres.statusCode >= 400) { res.write(`data: [codelogs] error starting stream\n\n`); return; }
    const demux=createDockerDemux(line=>{ res.write(`data: ${line.replace(/\r?\n/g,' ')}\n\n`); });
    dres.on('data', chunk=>demux(chunk));
    dres.on('end',  ()=>{ try{res.write(`data: [codelogs] ended\n\n`);}catch(_){ } });
  });
}

/* --------------------- splash (503) --------------------- */
function makeSplashHtml() {
  return `<!doctype html><meta charset="utf-8">
<title>Codestrap — connecting…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
.wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
.spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
@keyframes spin{to{transform:rotate(360deg)}}
.small{opacity:.8;font-size:13px;margin-top:8px}
.subtitle{margin-top:-12.5px;font-weight:750}
.container{width:100%;max-width:1024px;margin-top:18px}
.card{background:#111827;border:1px solid #374151;border-radius:12px;overflow:hidden}
.head{display:flex;align-items:center;justify-content:space-between;padding:10px 14px}
summary{cursor:pointer;list-style:none}
summary::-webkit-details-marker{display:none}
summary{display:flex;align-items:center;gap:.5rem}
.badge{font-size:11px;opacity:.8;border:1px solid #374151;border-radius:999px;padding:2px 8px}
pre{margin:0;padding:12px 14px;border-top:1px solid #374151;max-height:300px;overflow:auto;font-size:12px;line-height:1.35;background:#0b1220}
kbd{background:#111827;border:1px solid #374151;border-radius:6px;padding:2px 6px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.chev{display:inline-block;transition:transform .15s ease}
details[open] .chev{transform:rotate(90deg)}

/* --- dot animation that does NOT reflow --- */
.tip-line{display:inline-flex;align-items:baseline;gap:.15rem}
.dots{
  display:inline-grid;
  grid-auto-flow:column;
  grid-template-columns:repeat(3,1ch);
  width:3ch;               /* fixed width so the line never shifts */
}
.dots span{
  display:inline-block;
  width:1ch; text-align:left;
  opacity:0;
  animation: steps(1,end) 1.2s infinite dotReset;
}
/* 1st dot visible the whole cycle */
.dots span:nth-child(1){ animation-name: dot1; }
/* 2nd dot becomes visible after 1/3 */
.dots span:nth-child(2){ animation-name: dot2; }
/* 3rd dot becomes visible after 2/3 */
.dots span:nth-child(3){ animation-name: dot3; }

@keyframes dot1 { 0%,100% { opacity:1 } }
@keyframes dot2 { 0%,33% { opacity:0 } 34%,100% { opacity:1 } }
@keyframes dot3 { 0%,66% { opacity:0 } 67%,100% { opacity:1 } }
/* Just a placeholder so we can set defaults above; not used directly */
@keyframes dotReset { 0% {opacity:0} 100% {opacity:0} }
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Codestrap is connecting to code-server…</h1>
  <div class="small subtitle">This may take some time.</div>

  <div class="small tip-line" id="tip">
    <span id="tip-base">Starting services</span>
    <span class="dots" aria-hidden="true"><span>.</span><span>.</span><span>.</span></span>
  </div>

  <div class="container">
    <details class="card" id="logsbox">
      <summary class="head">
        <span><span class="chev">▶</span> Show live logs</span>
        <span class="badge" id="log-status">hidden</span>
      </summary>
      <pre id="log"></pre>
    </details>
    <div class="small" style="opacity:.65;margin-top:10px">
      This page auto-reloads when code-server is ready. You can also press <kbd>⌘/Ctrl</kbd>+<kbd>R</kbd>.
    </div>
  </div>
</div>
<script>
(function(){
  let delay = 600, maxDelay = 5000, tries = 0;
  const original = location.href;
  const tipBaseEl = document.getElementById('tip-base');
  const logEl = document.getElementById('log');
  const statusEl = document.getElementById('log-status');
  const logsBox = document.getElementById('logsbox');

  function setTipBase(t){ if(tipBaseEl) tipBaseEl.textContent = t; }
  function setStatus(t){ if(statusEl) statusEl.textContent=t; }
  function addLines(t){
    if (!logEl || !t) return;
    logEl.textContent += t.replace(/\\r?\\n/g,'\\n');
    logEl.scrollTop = logEl.scrollHeight;
  }

  // Live logs: initialize only when opened
  let logsInit = false;
  logsBox?.addEventListener('toggle', ()=>{
    if (!logsBox.open || logsInit) { setStatus(logsBox.open ? 'opening…' : 'hidden'); return; }
    logsInit = true;
    setStatus('initializing…');
    fetch('/__code_logs?ts='+Date.now(), {cache:'no-store'}).then(r=>{
      if (r.ok) return r.text();
      throw new Error('snapshot unavailable');
    }).then(t=>{
      if (t) addLines(t);
      setStatus('live');
    }).catch(()=>{ setStatus('unavailable'); });

    try {
      const es = new EventSource('/__code_events');
      es.addEventListener('message', ev => { addLines(ev.data + "\\n"); });
      es.onopen = ()=> setStatus('live');
      es.onerror = ()=> setStatus('disconnected (retrying…)');
    } catch (_) { setStatus('unavailable'); }
  });

  // Start polling immediately (dots are CSS-driven and already running)
  async function ping(){
    tries++;
    try{
      const res = await fetch('/__up?ts=' + Date.now(), {cache:'no-store', credentials:'same-origin'});
      if (res.ok) {
        setTipBase('Ready! Loading…');
        location.replace(original);
        return;
      }
    }catch(e){}
    const jitter = Math.random() * 150;
    delay = Math.min(maxDelay, Math.round(delay * 1.6) + jitter);
    setTimeout(ping, delay);
  }
  setTimeout(ping, delay);
})();
</script>`;
}


/* --------------------- helpers --------------------- */

function authPath(name){ return `${PROFILE_DATA_BASE}/${name}/auth/${name}.auth.json`; }

// ADD — cookie/signing helpers
function b64url(b){ return Buffer.from(b).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''); }
function ub64url(s){ s=s.replace(/-/g,'+').replace(/_/g,'/'); while(s.length%4) s+='='; return Buffer.from(s,'base64'); }

function sign(obj){
  const payload = b64url(JSON.stringify(obj));
  const h = crypto.createHmac('sha256', AUTH_SECRET).update(payload).digest('base64url');
  return `${payload}.${h}`;
}
function verify(token){
  if (!token || typeof token !== 'string' || !token.includes('.')) return null;
  const [payload, mac] = token.split('.');
  const good = crypto.createHmac('sha256', AUTH_SECRET).update(payload).digest('base64url');
  if (!crypto.timingSafeEqual(Buffer.from(mac), Buffer.from(good))) return null;
  const obj = JSON.parse(ub64url(payload));
  if (!obj || !obj.profile) return null;
  if (obj.exp && Date.now() > obj.exp) return null;
  return obj;
}

function setCookie(res, name, val, opts={}){
  const parts = [`${name}=${val}; Path=/; HttpOnly; SameSite=Lax`];
  if (opts.maxAge) parts.push(`Max-Age=${opts.maxAge|0}`);
  if (opts.secure) parts.push('Secure'); // only when explicitly true
  res.setHeader('Set-Cookie', parts.join('; '));
}
function clearCookie(res, name){ res.setHeader('Set-Cookie', `${name}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax`); }
function readCookie(req, name){
  const c = req.headers.cookie || '';
  const m = c.match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? decodeURIComponent(m[1]) : null;
}

// ADD — per-profile auth files (scrypt)
function loadAuthForProfile(name){
  try{
    const p = authPath(name);
    const raw = fs.readFileSync(p, 'utf8');
    const j = JSON.parse(raw);
    if (!j || j.algo!=='scrypt' || !j.salt || !j.hash) return null;
    // normalize flags
    j.requiresChange = !!j.requiresChange;
    return j;
  }catch(_){ return null; }
}

function saveAuthForProfile(name, conf){
  const p = authPath(name);
  fs.mkdirSync(require('path').dirname(p), { recursive: true, mode: 0o755 });
  fs.writeFileSync(p, JSON.stringify(conf, null, 2));
}
function makeHashRecord(user, password){
  const salt = crypto.randomBytes(16).toString('hex');
  const N=16384,r=8,p=1,dkLen=64;
  const hash = crypto.scryptSync(password, Buffer.from(salt,'hex'), dkLen,{N,r,p}).toString('hex');
  return { user, algo:'scrypt', salt, hash, N, r, p, dkLen, requiresChange:false, defaultSeed:false };
}

function scryptHex(password, saltHex, N=16384,r=8,p=1,dkLen=64){
  return crypto.scryptSync(password, Buffer.from(saltHex,'hex'), dkLen,{N,r,p}).toString('hex');
}

// ADD — payload helpers
function parseProfileFromPayload(u){
  if (!u || !u.query || !u.query.payload) return null;
  try{
    const raw = Array.isArray(u.query.payload) ? u.query.payload[0] : u.query.payload;
    const decoded = decodeURIComponent(raw);
    const a = JSON.parse(decoded);
    if (Array.isArray(a) && Array.isArray(a[0]) && a[0][0]==='profile') return String(a[0][1]||'');
  }catch(_){}
  return null;
}
function makePayloadFor(profile){
  return encodeURIComponent(JSON.stringify([["profile", profile]]));
}

function noStoreHeaders(extra = {}) {
  return Object.assign({
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
    'pragma': 'no-cache',
    'expires': '0',
    'retry-after': '1'
  }, extra);
}


/* --------------------- helpers --------------------- */
function noStoreHeaders(extra = {}){
  return Object.assign({
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
    'pragma': 'no-cache',
    'expires': '0',
    'retry-after': '1'
  }, extra);
}

/* --------------------- path guard for injection --------------------- */
function shouldInjectWatchdog(reqUrl){
  const u = url.parse(reqUrl || '/', true);
  const p = u.pathname || '/';
  // Allow only the main shell or login HTML.
  if (p === '/' || p === '' ) return true;
  if (p === '/index.html' || p === '/login') return true;
  // Explicitly avoid anything that might be a VS Code webview or asset route.
  if (p.startsWith('/vscode') || p.startsWith('/vscode-') || p.startsWith('/static') ||
      p.startsWith('/webview') || p.startsWith('/vscode-webview') || p.startsWith('/workbench')) return false;
  return false;
}

/* --------------------- HTTP server --------------------- */
const server = http.createServer((req,res)=>{
  const u = url.parse(req.url || '/', true);

  // ADD — public paths and "asset" detection
  const PUBLIC_PATHS = new Set([
    '/__up','/__logs','/__events','/__code_logs','/__code_events',
    '/__profiles','/__seed_profiles.js','/__watchdog.js',
    '/__login','/__logout','/__ensure_profile_dirs','/favicon.ico'
  ]);
  const ASSET_PREFIXES = ['/vscode','/vscode-','/static','/workbench','/webview','/vscode-webview'];
  function isAssetPath(p){
    p = p || '';
    for (const pref of ASSET_PREFIXES) if (p.startsWith(pref)) return true;
    if (p.endsWith('.js') || p.endsWith('.css') || p.endsWith('.ico') || p.endsWith('.map')) return true;
    return false;
  }


  // Health
  if (u.pathname === '/__up') {
    return probeAndNote(ok=>{
      res.writeHead(ok?200:503, {'content-type':'text/plain','cache-control':'no-store'}).end(ok?'OK':'DOWN');
    });
  }

  // Watchdog JS (external script)
  if (u.pathname === '/__watchdog.js') {
    res.writeHead(200, {
      'content-type': 'application/javascript; charset=utf-8',
      'cache-control': 'no-store, no-cache, must-revalidate, max-age=0'
    });
    return res.end(`(function(){
      var delay=1500, max=6000;
      function next(){ delay=Math.min(max, Math.round(delay*1.4)); setTimeout(ping, delay); }
      async function ping(){
        try{
          var r = await fetch('/__up?ts='+Date.now(), {cache:'no-store', credentials:'same-origin'});
          if (r.status !== 200) { location.reload(); return; }
        }catch(e){ location.reload(); return; }
        next();
      }
      setTimeout(ping, delay);
    })();`);
  }

  // Logs (ring buffer)
  if (u.pathname === '/__logs') {
    res.writeHead(200, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
    return res.end(getLogsText());
  }

  // Debug events
  if (u.pathname === '/__events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
      'connection': 'keep-alive',
      'x-accel-buffering': 'no'
    });
    sseClients.add(res);
    res.write(`data: [sse] connected ${new Date().toISOString()}\n\n`);
    if (lastUp !== null) res.write(`data: upstream=${lastUp ? 'UP' : 'DOWN'}\n\n`);
    req.on('close', ()=>{ try{sseClients.delete(res);}catch(_){ } });
    return;
  }

  // Code logs snapshot
  if (u.pathname === '/__code_logs') {
    if (!docker.wantLogs) {
      res.writeHead(503, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
      return res.end('[codelogs] unavailable (docker socket or CODE_SERVICE_NAME)\n');
    }
    resolveContainerId((err, id)=>{
      if (err || !id) {
        res.writeHead(503, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
        return res.end('[codelogs] container not found for CODE_SERVICE_NAME\n');
      }
      fetchDockerLogsTail(id, 200, (e, text)=>{
        if (e) {
          res.writeHead(500, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
          return res.end('[codelogs] error reading logs\n');
        }
        res.writeHead(200, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
        res.end(text);
      });
    });
    return;
  }

  // Code logs streaming (SSE)
  if (u.pathname === '/__code_events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store, no-cache, max-age=0',
      'connection': 'keep-alive',
      'x-accel-buffering': 'no'
    });
    if (!docker.wantLogs) {
      res.write(`data: [codelogs] unavailable (docker socket or CODE_SERVICE_NAME)\n\n`);
      return;
    }
    resolveContainerId((err, id)=>{
      if (err || !id) {
        res.write(`data: [codelogs] container not found for CODE_SERVICE_NAME\n\n`);
        return;
      }
      const since = Math.floor(Date.now()/1000) - 20; // include a bit of recent history
      streamDockerLogs(id, res, since);
      req.on('close', ()=>{ try { res.end(); } catch(_){} });
    });
    return;
  }

  // inside createServer handler, near other special routes:
  if (u.pathname === '/__profiles') {
    try {
      const entries = fs.readdirSync(PROFILES_DIR, { withFileTypes: true });
      const names = entries
        .filter(e => e.isFile())
        .map(e => e.name)
        .filter(n => /\.profile\.json$/i.test(n))
        .map(n => n.replace(/\.profile\.json$/i, ''));

      const authRequired = {};
      const requiresChange = {};

      for (const n of names) {
        // Read profile.json to check "auth": true
        let wantAuth = false;
        try {
          const pj = JSON.parse(fs.readFileSync(`${PROFILES_DIR}/${n}.profile.json`, 'utf8'));
          wantAuth = !!(pj && pj.auth === true);
        } catch (_){}

        const conf = loadAuthForProfile(n);
        if (wantAuth && !conf) {
          // No file yet; UI should treat as password required (we expect init script to create it).
          authRequired[n] = true;
          requiresChange[n] = true; // until created, show change prompt after default creation
        } else if (conf) {
          authRequired[n] = true;
          requiresChange[n] = !!conf.requiresChange;
        } else {
          authRequired[n] = false;
          requiresChange[n] = false;
        }
      }

      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(JSON.stringify({ names, auth: authRequired, requiresChange }));
    } catch (e) {
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      return res.end(JSON.stringify({ names: [], auth: {}, requiresChange: {}, error: 'PROFILES_DIR_unreadable' }));
    }
  }

  if (u.pathname === '/__seed_profiles.js') {
    res.writeHead(200, {
      'content-type': 'application/javascript; charset=utf-8',
      'cache-control': 'no-store, no-cache, must-revalidate, max-age=0'
    });
    return res.end(`(function(){
      const BASE = '/config/codestrap/profile_data/'; // used for localStorage paths

      function readProfiles(){
        try{
          const raw = localStorage.getItem('userDataProfiles');
          if (!raw) return [];
          const v = JSON.parse(raw);
          if (Array.isArray(v)) return v;
          if (v && Array.isArray(v.profiles)) return v.profiles;
          return [];
        }catch{return [];}
      }
      function writeProfiles(arr){
        try{ localStorage.setItem('userDataProfiles', JSON.stringify(arr||[])); }
        catch(e){ console.warn('[codestrap] cannot write userDataProfiles:', e); }
      }

      function seedAndEnsure(names){
        try{
          let arr = readProfiles();
          const have = new Set(arr.map(x => (x && x.name) || ''));
          const created = [];
          for (const name of names || []) {
            if (!name || have.has(name)) continue;
            arr.push({
              location: {
                "$mid": 1, // per your requirement: always 1
                "external": "vscode-remote:" + BASE + name,
                "path": BASE + name,
                "scheme": "vscode-remote"
              },
              "name": name
            });
            created.push(name);
          }
          if (created.length) writeProfiles(arr);

          // Ask proxy to mkdir for any newly-added names
          if (created.length) {
            fetch('/__ensure_profile_dirs', {
              method: 'POST',
              headers: {'content-type': 'application/json'},
              body: JSON.stringify({ names: created }),
              credentials: 'same-origin',
              cache: 'no-store'
            }).then(r=>r.json()).then(j=>{
              console.log('[codestrap] ensure dirs:', j);
            }).catch(e=>console.warn('[codestrap] ensure dirs failed:', e));
          }

          console.log('[codestrap] seeded profiles:', { added: created.length, total: arr.length, created });
        }catch(e){
          console.warn('[codestrap] seed profiles failed:', e);
        }
      }

      try{
        fetch('/__profiles?ts='+Date.now(), { cache: 'no-store', credentials: 'same-origin' })
          .then(r => r.ok ? r.json() : {names:[]})
          .then(j => seedAndEnsure((j && j.names) || []))
          .catch(e => console.warn('[codestrap] /__profiles fetch failed:', e));
      }catch(e){
        console.warn('[codestrap] seed bootstrap failed:', e);
      }
    })();`);
  }

  if (u.pathname === '/__ensure_profile_dirs' && req.method === 'POST') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', ()=>{
      try {
        const { names } = JSON.parse(body||'{}');
        if (!Array.isArray(names)) throw new Error('names must be an array');
        let made = 0;
        for (const name of names) {
          if (!name || /[\\/]/.test(name)) continue; // simple safety
          const p = `${PROFILE_DATA_BASE}/${name}`;
          try {
            fs.mkdirSync(p, { recursive: true, mode: 0o755 });
            made++;
          } catch (e) {
            pushLog(`[profiles] mkdir failed for ${p}: ${e.message}`);
          }
        }
        res.writeHead(200, {'content-type':'application/json; charset=utf-8','cache-control':'no-store'});
        return res.end(JSON.stringify({ ok:true, made, base: PROFILE_DATA_BASE }));
      } catch (e) {
        res.writeHead(400, {'content-type':'application/json; charset=utf-8','cache-control':'no-store'});
        return res.end(JSON.stringify({ ok:false, error: e.message }));
      }
    });
    return;
  }

  // Login page
  if (u.pathname === '/__login' && req.method === 'GET') {
    const next = u.query.next || '/';
    res.writeHead(200, {'content-type':'text/html; charset=utf-8','cache-control':'no-store'});
    return res.end(`<!doctype html><meta charset="utf-8"><title>Codestrap Login</title>
  <style>
    body{font:14px system-ui;background:#0f172a;color:#e5e7eb;display:grid;place-items:center;height:100vh;margin:0}
    form{background:#111827;border:1px solid #374151;border-radius:12px;padding:20px;min-width:340px}
    h1{margin:0 0 10px 0;font-size:18px}
    label{display:block;margin:8px 0 4px 0}
    input,select{width:100%;padding:8px;border-radius:8px;border:1px solid #374151;background:#0b1220;color:#e5e7eb}
    button{margin-top:12px;padding:10px 12px;border-radius:8px;border:1px solid #374151;background:#1f2937;color:#e5e7eb;cursor:pointer}
    .msg{opacity:.8;margin-bottom:8px}
    .warn{background:#3b1d1d;border:1px solid #7f1d1d;padding:8px;border-radius:8px;margin:8px 0}
  </style>
  <div>
    <form method="POST" action="/__login" id="f">
      <h1>Sign in to a profile</h1>
      <div class="msg">Choose a profile. If it requires a password, you’ll be prompted.</div>

      <label>Profile</label>
      <select name="profile" id="profile"></select>

      <div id="pw-req" style="display:none">
        <label>Current password</label>
        <input type="password" id="password" name="password" autocomplete="current-password"/>
      </div>

      <div id="pw-change" class="warn" style="display:none">
        <div><strong>First login:</strong> this profile is using a default password. Please set a new password now.</div>
        <label style="margin-top:8px">New password</label>
        <input type="password" id="new_password" name="new_password" autocomplete="new-password"/>
        <label>Confirm new password</label>
        <input type="password" id="new_password2" name="new_password2" autocomplete="new-password"/>
      </div>

      <input type="hidden" name="next" value="${String(next).replace(/"/g,'&quot;')}"/>
      <button type="submit">Continue</button>
    </form>
  </div>
  <script>
  (async function(){
    const r = await fetch('/__profiles',{cache:'no-store'});
    const j = await r.json();
    const sel = document.getElementById('profile');
    const pwReq = document.getElementById('pw-req');
    const pwChg = document.getElementById('pw-change');
    const needs = j.auth || {}, chg = j.requiresChange || {};
    (j.names||[]).forEach(n=>{ const o=document.createElement('option'); o.value=n; o.textContent=n; sel.appendChild(o); });
    function update(){
      const name = sel.value;
      const requirePw = !!needs[name];
      const mustChange = !!chg[name];
      pwReq.style.display = requirePw ? '' : 'none';
      pwChg.style.display = (requirePw && mustChange) ? '' : 'none';
      // HTML-level required toggles
      const pw = document.getElementById('password');
      const npw = document.getElementById('new_password');
      const npw2 = document.getElementById('new_password2');
      if (requirePw) pw.setAttribute('required','required'); else { pw.removeAttribute('required'); pw.value=''; }
      if (requirePw && mustChange) { npw.setAttribute('required','required'); npw2.setAttribute('required','required'); }
      else { npw.removeAttribute('required'); npw2.removeAttribute('required'); npw.value=''; npw2.value=''; }
    }
    sel.addEventListener('change', update);
    update();
  })();
  </script>`);
  }

  // ADD — login POST
  if (u.pathname === '/__login' && req.method === 'POST') {
    let body=''; req.on('data', c=> body+=c);
    req.on('end', ()=>{
      const m = new URLSearchParams(body);
      const profile = (m.get('profile')||'').trim();
      const password = m.get('password')||'';
      const next = m.get('next') || '/';
      const conf = loadAuthForProfile(profile);
      if (!profile) {
        res.writeHead(302, {'Location':'/__login?e=badprofile'});
        return res.end();
      }

      try{
        let user = profile;

        if (conf) {
          // Must supply current password
          const derived = scryptHex(password, conf.salt, conf.N||16384, conf.r||8, conf.p||1, conf.dkLen||64);
          const ok = crypto.timingSafeEqual(Buffer.from(derived,'hex'), Buffer.from(conf.hash,'hex'));
          if (!ok) throw new Error('bad pw');

          // If the auth file indicates default seed / first login, require new password now
          if (conf.requiresChange) {
            const npw = (m.get('new_password')||'').trim();
            const npw2 = (m.get('new_password2')||'').trim();
            if (!npw || npw !== npw2) {
              res.writeHead(302, {'Location':'/__login?e=needchange'});
              return res.end();
            }
            const newRec = makeHashRecord(conf.user||profile, npw);
            saveAuthForProfile(profile, newRec); // overwrites with fresh salt/hash; requiresChange=false
          }

          user = conf.user || profile;
        } // else passwordless

        const sess = { profile, user, iat: Date.now(), exp: Date.now()+SESSION_TTL_SEC*1000 };
        const token = sign(sess);

        const xfproto = (req.headers['x-forwarded-proto']||'').split(',')[0].trim();
        const isHttps = xfproto === 'https' || req.connection?.encrypted;
        setCookie(res, SESSION_COOKIE, token, {maxAge: SESSION_TTL_SEC, secure: isHttps});

        // Ensure payload matches session profile
        let target = next || '/';
        try {
          const parsed = url.parse(target, true);
          const p = parseProfileFromPayload(parsed);
          if (p !== profile) {
            parsed.query = parsed.query || {};
            parsed.query.payload = `[["profile","${profile}"]]`;
            delete parsed.search;
            target = url.format(parsed);
          }
        } catch(_){}
        res.writeHead(302, {'Location': target});
        return res.end();
      }catch(_){
        res.writeHead(302, {'Location':'/__login?e=badpass'});
        return res.end();
      }
    });
    return;
  }

  // ADD — logout
  if (u.pathname === '/__logout') {
    clearCookie(res, SESSION_COOKIE);
    res.writeHead(302, {'Location':'/__login'});
    return res.end();
  }

  // ADD — auth gate for everything except internal endpoints
  if (!PUBLIC_PATHS.has(u.pathname)) {
    const tok = readCookie(req, SESSION_COOKIE);
    const sess = verify(tok);

    if (!sess || !sess.profile) {
      res.writeHead(302, {'Location': `/__login?next=${encodeURIComponent(req.url||'/')}`});
      return res.end();
    }

    // Enforce payload only for app pages (not static assets)
    if (!isAssetPath(u.pathname)) {
      const gotProfile = parseProfileFromPayload(u);
      if (!gotProfile || gotProfile !== sess.profile) {
        const parsed = url.parse(req.url||'/', true);
        parsed.query = parsed.query || {};
        parsed.query.payload = `[["profile","${sess.profile}"]]`;
        delete parsed.search;
        const fixed = url.format(parsed);
        res.writeHead(302, {'Location': fixed});
        return res.end();
      }
    }
  }

  // ---------- Normal proxy flow ----------
  probeAndNote(ok=>{
    if (!ok) {
      pushLog(`upstream DOWN → ${req.method} ${req.url}`);
      res.writeHead(503, noStoreHeaders());
      return res.end(makeSplashHtml());
    }

    // strip hop-by-hop
    const headers = { ...req.headers };
    delete headers.connection; delete headers.upgrade;
    delete headers['proxy-connection']; delete headers['keep-alive'];
    delete headers['transfer-encoding'];

    // forward info
    headers['x-forwarded-proto'] = req.headers['x-forwarded-proto'] || 'http';
    headers['x-forwarded-host']  = headers['x-forwarded-host'] || req.headers['host'];
    if (req.socket?.remoteAddress) {
      headers['x-forwarded-for'] = headers['x-forwarded-for']
        ? `${headers['x-forwarded-for']}, ${req.socket.remoteAddress}`
        : req.socket.remoteAddress;
    }

    const p = http.request({
      hostname: CODE_SERVICE_NAME || '127.0.0.1',
      port: CODE_EXPOSED_PORT,
      path: req.url,
      method: req.method,
      headers
    }, pr => {
      const status = pr.statusCode || 502;
      const hdrs = { ...pr.headers };

      const ct = String(hdrs['content-type'] || hdrs['Content-Type'] || '').toLowerCase();
      const isHtml = ct.includes('text/html');
      const allowInjectHere = shouldInjectWatchdog(req.url);

      if (!(isHtml && allowInjectHere)) {
        if (status === 503) {
          hdrs['cache-control'] = 'no-store, no-cache, must-revalidate, max-age=0';
          hdrs['pragma'] = 'no-cache'; hdrs['expires'] = '0';
        }
        res.writeHead(status, hdrs);
        pr.pipe(res);
        pr.on('end', ()=> pushLog(`${req.method} ${req.url} → ${status}`));
        return;
      }

      // Mutate HTML for main shell only → decode if compressed, drop length/encoding, set no-store.
      hdrs['cache-control'] = 'no-store, no-cache, must-revalidate, max-age=0';
      delete hdrs['content-length']; delete hdrs['Content-Length'];
      const enc = String(hdrs['content-encoding'] || hdrs['Content-Encoding'] || '').toLowerCase();
      delete hdrs['content-encoding']; delete hdrs['Content-Encoding'];
      res.writeHead(status, hdrs);

      let sourceStream = pr;
      try {
        if (enc.includes('br')) { const bro = zlib.createBrotliDecompress(); pr.pipe(bro); sourceStream = bro; }
        else if (enc.includes('gzip') || enc.includes('x-gzip')) { const gun = zlib.createGunzip(); pr.pipe(gun); sourceStream = gun; }
        else if (enc.includes('deflate')) { const inf = zlib.createInflate(); pr.pipe(inf); sourceStream = inf; }
      } catch (e) {
        pushLog(`warn: decoder init failed enc='${enc}': ${e.message}`); sourceStream = pr;
      }

      // in the HTML-mutation branch, before streaming out:
      const TAG = `<script src="/__watchdog.js" defer></script><script src="/__seed_profiles.js" defer></script>`;
      let injected = false;
      let buffer = '';
      sourceStream.setEncoding('utf8');

      sourceStream.on('data', chunk=>{
        buffer += chunk;
        if (!injected) {
          const i = buffer.toLowerCase().indexOf('</head>');
          if (i !== -1) {
            injected = true;
            const out = buffer.slice(0, i) + TAG + buffer.slice(i);
            res.write(out); buffer = '';
          } else if (buffer.length > 128 * 1024) {
            res.write(buffer); buffer='';
          }
        } else {
          res.write(chunk);
        }
      });
      sourceStream.on('end', ()=>{
        if (!injected) {
          const j = buffer.toLowerCase().lastIndexOf('</body>');
          if (j !== -1) res.write(buffer.slice(0, j) + TAG + buffer.slice(j));
          else res.write(buffer);
        } else if (buffer) res.write(buffer);
        res.end();
        pushLog(`${req.method} ${req.url} → ${status} [watchdog=on enc=${enc||'identity'}]`);
      });
      sourceStream.on('error', e=>{ pushLog(`error in injection stream: ${e.message}`); try{res.end();}catch(_){} });
    });

    p.on('error', (e)=>{
      pushLog(`error piping to upstream: ${e.message}`);
      res.writeHead(503, noStoreHeaders());
      res.end(makeSplashHtml());
    });

    req.pipe(p);
  });
});

/* --------------------- WebSocket proxy --------------------- */
server.on('upgrade', (req, client, head)=>{
  // REQUIRE valid session; don't force payload for WS
  const m = (req.headers.cookie||'').match(new RegExp(`(?:^|;\\s*)${SESSION_COOKIE}=([^;]+)`));
  const sess = m ? verify(decodeURIComponent(m[1])) : null;
  if (!sess || !sess.profile) { try{client.destroy();}catch(_){ } return; }

  // If payload present, it must match; but we don't force-add it here
  try {
    const uWS = url.parse(req.url||'/', true);
    const pName = parseProfileFromPayload(uWS);
    if (pName && pName !== sess.profile) { try{client.destroy();}catch(_){ } return; }
  } catch(_){}

  probeAndNote(ok=>{
    if (!ok) { try{client.destroy();}catch(_){ } return; }
    const upstream = net.connect(CODE_EXPOSED_PORT, CODE_SERVICE_NAME || '127.0.0.1');
    upstream.on('connect', ()=>{
      const lines=[];
      lines.push(`${req.method} ${req.url} HTTP/${req.httpVersion}`);
      for (const [k,v] of Object.entries(req.headers)) lines.push(`${k}: ${v}`);
      lines.push('','');
      upstream.write(lines.join('\r\n'));
      if (head?.length) upstream.write(head);
      upstream.pipe(client); client.pipe(upstream);
    });
    upstream.on('error', ()=>{ try{client.destroy();}catch(_){ } });
    client.on('error',  ()=>{ try{upstream.destroy();}catch(_){ } });
  });
});


/* --------------------- boot --------------------- */
server.listen(PROXY_PORT, '0.0.0.0', ()=>{
  pushLog(`listening on 0.0.0.0:${PROXY_PORT} → upstream http://${CODE_SERVICE_NAME}:${CODE_EXPOSED_PORT}`);
  if (!CODE_SERVICE_NAME) pushLog(`WARNING: CODE_SERVICE_NAME not set — upstream+logs may not work`);
  if (docker.wantLogs) {
    pushLog(`docker logs enabled (sock: ${DOCKER_SOCK}) — service: ${CODE_SERVICE_NAME}`);
  } else if (docker.enabled) {
    pushLog(`docker socket present, but CODE_SERVICE_NAME not set → logs disabled`);
  } else {
    pushLog(`docker logs disabled (socket not mounted at ${DOCKER_SOCK})`);
  }
});
//WORKING MARKER!!!