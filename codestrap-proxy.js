// codestrap-proxy.js — Reverse proxy + splash with live logs
// Env: PROXY_PORT (default 8080), UP_HOST ("code"), UP_PORT (8443), UP_TIMEOUT_MS (2500)

const http = require('http');
const net  = require('net');

const PROXY_PORT = +(process.env.PROXY_PORT || 8080);
const UP_HOST    = process.env.UP_HOST || 'code';
const UP_PORT    = +(process.env.UP_PORT || 8443);
const UPSTREAM_CONNECT_TIMEOUT_MS = +(process.env.UP_TIMEOUT_MS || 2500);

/* --------------------- tiny logger (ring buffer + SSE) --------------------- */

const LOG_CAP = +(process.env.LOG_CAP || 500);
let logBuf = [];
let sseClients = new Set();

function ts() {
  const d = new Date();
  return d.toISOString().replace('T', ' ').replace('Z', 'Z');
}

function pushLog(line) {
  const msg = `[proxy ${ts()}] ${line}`;
  logBuf.push(msg);
  if (logBuf.length > LOG_CAP) logBuf = logBuf.slice(-LOG_CAP);
  // broadcast to SSE clients
  const payload = `data: ${msg.replace(/\r?\n/g, ' ')}\n\n`;
  for (const res of sseClients) {
    try { res.write(payload); } catch (_) {}
  }
}

function getLogsText() {
  return logBuf.join('\n') + (logBuf.length ? '\n' : '');
}

/* --------------------- upstream health check --------------------- */

function upstreamAlive(cb){
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error',  ()=>finish(false));
  s.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS,()=>finish(false));
}

// Track last seen state to emit UP/DOWN transitions
let lastUp = null;
function probeAndNote(cb) {
  upstreamAlive(ok => {
    if (lastUp === null) {
      pushLog(`upstream initial state: ${ok ? 'UP' : 'DOWN'} (${UP_HOST}:${UP_PORT})`);
    } else if (ok !== lastUp) {
      pushLog(`upstream state change: ${ok ? 'UP' : 'DOWN'}`);
    }
    lastUp = ok;
    cb(ok);
  });
}

/* --------------------- splash HTML (with live log panel) --------------------- */

function makeSplashHtml() {
  return `<!doctype html><meta charset="utf-8">
<title>Codestrap — connecting…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
.wrap{height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
.spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
@keyframes spin{to{transform:rotate(360deg)}}
.small{opacity:.8;font-size:13px;margin-top:8px}
.subtitle{margin-top:-12.5px;font-weight:750}
.panel{max-width:920px;width:100%;margin-top:18px}
details{background:#111827;border:1px solid #374151;border-radius:12px}
summary{cursor:pointer;padding:10px 14px;outline:none;user-select:none}
pre{margin:0;padding:12px 14px;border-top:1px solid #374151;max-height:260px;overflow:auto;font-size:12px;line-height:1.3;background:#0b1220}
kbd{background:#111827;border:1px solid #374151;border-radius:6px;padding:2px 6px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
a { color:#93c5fd; }
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Codestrap is connecting to code-server…</h1>
  <div class="small subtitle">This may take some time.</div>
  <div class="small" id="tip">Starting services…</div>

  <div class="panel">
    <details id="logs">
      <summary>Live logs</summary>
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
  const tipEl = document.getElementById('tip');
  const logEl = document.getElementById('log');

  function setTip(t){ if(tipEl) tipEl.textContent=t; }
  function appendLog(line) {
    if (!logEl) return;
    logEl.textContent += line + "\\n";
    logEl.scrollTop = logEl.scrollHeight;
  }

  // Seed logs (snapshot), then live updates via SSE
  fetch('/__logs?ts='+Date.now(), {cache:'no-store'}).then(r=>r.text()).then(t=>{
    if (t) { logEl.textContent = t; logEl.scrollTop = logEl.scrollHeight; }
  }).catch(()=>{});
  try {
    const es = new EventSource('/__events');
    es.addEventListener('message', ev => { appendLog(ev.data); });
    es.onerror = () => { /* silent; will reconnect automatically */ };
  } catch (_) {}

  async function ping(){
    tries++;
    try{
      const res = await fetch('/__up?ts=' + Date.now(), {cache:'no-store', credentials:'same-origin'});
      if (res.ok) {
        setTip('Ready! Loading…');
        location.replace(original);
        return;
      }
    }catch(e){}
    if (tries === 10) setTip('Still starting…');
    const jitter = Math.random() * 150;
    delay = Math.min(maxDelay, Math.round(delay * 1.6) + jitter);
    setTimeout(ping, delay);
  }
  setTimeout(ping, delay);
})();
</script>`;
}

/* --------------------- helpers --------------------- */

function noStoreHeaders(extra = {}) {
  return Object.assign({
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
    'pragma': 'no-cache',
    'expires': '0',
    'retry-after': '1'
  }, extra);
}

/* --------------------- HTTP server --------------------- */

const server = http.createServer((req,res)=>{
  // Health endpoint (used by splash polling)
  if (req.url === '/__up' || req.url.startsWith('/__up?')) {
    return probeAndNote(ok=>{
      res.writeHead(ok?200:503, {'content-type':'text/plain','cache-control':'no-store'}).end(ok?'OK':'DOWN');
    });
  }

  // Snapshot logs (plain text)
  if (req.url.startsWith('/__logs')) {
    res.writeHead(200, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
    return res.end(getLogsText());
  }

  // Live events (SSE)
  if (req.url.startsWith('/__events')) {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
      'connection': 'keep-alive',
      'x-accel-buffering': 'no'
    });
    sseClients.add(res);
    // send a hello + current state hint
    res.write(`data: [sse] connected ${new Date().toISOString()}\n\n`);
    if (lastUp !== null) {
      res.write(`data: upstream=${lastUp ? 'UP' : 'DOWN'}\n\n`);
    }
    req.on('close', ()=>{ try{sseClients.delete(res);}catch(_){ } });
    return;
  }

  // Normal proxy flow
  probeAndNote(ok=>{
    if (!ok) {
      pushLog(`upstream DOWN → ${req.method} ${req.url}`);
      res.writeHead(503, noStoreHeaders());
      return res.end(makeSplashHtml());
    }

    // strip hop-by-hop
    const headers = { ...req.headers };
    delete headers.connection;
    delete headers.upgrade;
    delete headers['proxy-connection'];
    delete headers['keep-alive'];
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
      hostname: UP_HOST,
      port: UP_PORT,
      path: req.url,
      method: req.method,
      headers
    }, pr => {
      // ensure no cache on 503 just in case
      if ((pr.statusCode||500) === 503) {
        Object.assign(pr.headers, noStoreHeaders());
      }
      res.writeHead(pr.statusCode || 502, pr.headers);
      pr.pipe(res);
      pr.on('end', ()=> {
        const sc = pr.statusCode || 0;
        pushLog(`${req.method} ${req.url} → ${sc}`);
      });
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
  probeAndNote(ok=>{
    if (!ok) { try{client.destroy();}catch(_){ } return; }
    const upstream = net.connect(UP_PORT, UP_HOST);
    upstream.on('connect', () => {
      const lines = [];
      lines.push(`${req.method} ${req.url} HTTP/${req.httpVersion}`);
      for (const [k,v] of Object.entries(req.headers)) lines.push(`${k}: ${v}`);
      lines.push('', '');
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
  pushLog(`listening on 0.0.0.0:${PROXY_PORT} → upstream http://${UP_HOST}:${UP_PORT}`);
});
