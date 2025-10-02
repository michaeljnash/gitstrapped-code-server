// codestrap-proxy.js — Reverse proxy + splash with LIVE code-server container logs
// Proxy: HTTP+WS to upstream (code-server) with auto-splash while DOWN.
// Logs: streams Docker container logs via UNIX socket (no extra deps).
//
// ENV:
//   PROXY_PORT         : public port to listen on (default 8080)
//   UP_HOST            : upstream host (default "code")
//   UP_PORT            : upstream port (default 8443)
//   UP_TIMEOUT_MS      : TCP connect timeout to upstream (default 2500)
//   LOG_CAP            : in-memory ring buffer for proxy messages (default 500)
//   DOCKER_SOCK        : path to Docker socket (default "/var/run/docker.sock")
//   CODE_CONTAINER     : exact container id/name to read logs from (preferred)
//   CODE_SERVICE       : compose service name to resolve a container (default "code")

const http = require('http');
const net  = require('net');
const url  = require('url');

const PROXY_PORT = +(process.env.PROXY_PORT || 8080);
const UP_HOST    = process.env.UP_HOST || 'code';
const UP_PORT    = +(process.env.UP_PORT || 8443);
const UPSTREAM_CONNECT_TIMEOUT_MS = +(process.env.UP_TIMEOUT_MS || 2500);

const LOG_CAP    = +(process.env.LOG_CAP || 500);
const DOCKER_SOCK= process.env.DOCKER_SOCK || '/var/run/docker.sock';
const CODE_CONTAINER = process.env.CODE_CONTAINER || '';
const CODE_SERVICE   = process.env.CODE_SERVICE || 'code';

/* --------------------- tiny logger (ring buffer + SSE) --------------------- */

let logBuf = [];
let sseClients = new Set();

function ts() { return new Date().toISOString().replace('T',' ').replace('Z','Z'); }
function pushLog(line) {
  const msg = `[proxy ${ts()}] ${line}`;
  logBuf.push(msg);
  if (logBuf.length > LOG_CAP) logBuf = logBuf.slice(-LOG_CAP);
  const payload = `data: ${msg.replace(/\r?\n/g,' ')}\n\n`;
  for (const res of sseClients) { try { res.write(payload); } catch(_){} }
}
function getLogsText() { return logBuf.join('\n') + (logBuf.length ? '\n' : ''); }

/* --------------------- upstream health check --------------------- */

function upstreamAlive(cb){
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error',  ()=>finish(false));
  s.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS,()=>finish(false));
}
let lastUp = null;
function probeAndNote(cb) {
  upstreamAlive(ok => {
    if (lastUp === null) pushLog(`upstream initial state: ${ok ? 'UP' : 'DOWN'} (${UP_HOST}:${UP_PORT})`);
    else if (ok !== lastUp) pushLog(`upstream state change: ${ok ? 'UP' : 'DOWN'}`);
    lastUp = ok;
    cb(ok);
  });
}

/* --------------------- Docker logs (snapshot + follow via SSE) -------------- */

const docker = {
  enabled: false,
  containerId: null,
  socketPath: DOCKER_SOCK
};

function dockerRequest(path, method='GET', headers={}, cb) {
  const req = http.request({ socketPath: docker.socketPath, path, method, headers }, res => cb(null, res));
  req.on('error', err => cb(err));
  req.end();
}

function jsonEncodeFilters(obj){
  return encodeURIComponent(JSON.stringify(obj));
}

function resolveContainerId(cb) {
  if (!docker.enabled) return cb(null, null);
  if (docker.containerId) return cb(null, docker.containerId);

  if (CODE_CONTAINER) {
    // Try to inspect by the provided name/ID; if it works, use it.
    dockerRequest(`/v1.41/containers/${encodeURIComponent(CODE_CONTAINER)}/json`, 'GET', {}, (err, res)=>{
      if (err || res.statusCode !== 200) return cb(new Error('CODE_CONTAINER not found'));
      let body=''; res.setEncoding('utf8');
      res.on('data', c=>body+=c);
      res.on('end', ()=>{
        try { const j = JSON.parse(body); docker.containerId = j.Id; cb(null, docker.containerId); }
        catch(e){ cb(e); }
      });
    });
    return;
  }

  // Resolve by service name (compose label or partial name match)
  const filters = { label: [`com.docker.compose.service=${CODE_SERVICE}`] };
  const path = `/v1.41/containers/json?all=0&filters=${jsonEncodeFilters(filters)}`;
  dockerRequest(path, 'GET', {}, (err, res)=>{
    if (err) return cb(err);
    let body=''; res.setEncoding('utf8');
    res.on('data', c=>body+=c);
    res.on('end', ()=>{
      try {
        let arr = JSON.parse(body);
        if (!Array.isArray(arr) || arr.length === 0) {
          // fallback: list all and try name contains
          dockerRequest(`/v1.41/containers/json?all=0`, 'GET', {}, (e2, r2)=>{
            if (e2) return cb(e2);
            let b2=''; r2.setEncoding('utf8'); r2.on('data',c=>b2+=c);
            r2.on('end', ()=>{
              try {
                const all = JSON.parse(b2);
                const hit = all.find(c =>
                  (c.Labels && c.Labels['com.docker.compose.service'] === CODE_SERVICE) ||
                  (Array.isArray(c.Names) && c.Names.some(n => n.includes(`/${CODE_SERVICE}`)))
                );
                if (hit) { docker.containerId = hit.Id; cb(null, docker.containerId); }
                else cb(new Error('No container matched CODE_SERVICE'));
              } catch(e){ cb(e); }
            });
          });
          return;
        }
        docker.containerId = arr[0].Id;
        cb(null, docker.containerId);
      } catch(e){ cb(e); }
    });
  });
}

// Demux Docker log stream if not TTY (8-byte headers), else passthrough.
function createDockerDemux(onLine) {
  let buf = Buffer.alloc(0);
  let assumeTTY = false; // flip to true if headers look invalid repeatedly
  let badHeaders = 0;

  function emitText(b) {
    // Split on newlines and emit lines
    const s = b.toString('utf8');
    s.split(/\r?\n/).forEach(line => { if (line.length) onLine(line); });
  }

  return function onChunk(chunk) {
    if (assumeTTY) { emitText(chunk); return; }

    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 8) {
      const stream = buf.readUInt8(0);        // 0,1,2
      const length = buf.readUInt32BE(4);     // payload len
      if (length > 10 * 1024 * 1024) { // sanity check
        badHeaders++;
        if (badHeaders >= 2) { assumeTTY = true; emitText(buf); buf = Buffer.alloc(0); }
        break;
      }
      if (buf.length < 8 + length) break;
      const payload = buf.subarray(8, 8 + length);
      // prefix stream marker
      const prefix = stream === 2 ? '[stderr] ' : '';
      payload.toString('utf8').split(/\r?\n/).forEach(line=>{
        if (line.length) onLine(prefix + line);
      });
      buf = buf.subarray(8 + length);
    }
  };
}

// Snapshot logs (tail=N)
function fetchDockerLogsTail(containerId, tail, cb) {
  const p = `/v1.41/containers/${encodeURIComponent(containerId)}/logs?stdout=1&stderr=1&tail=${tail||200}`;
  dockerRequest(p, 'GET', {}, (err, res)=>{
    if (err) return cb(err);
    const chunks = [];
    const demux = createDockerDemux(line => chunks.push(line));
    res.on('data', chunk => demux(chunk));
    res.on('end', ()=> cb(null, chunks.join('\n') + (chunks.length?'\n':'')));
  });
}

// Follow logs via SSE (since=seconds)
function streamDockerLogs(containerId, res, sinceSec) {
  const since = Math.max(0, sinceSec|0);
  const path = `/v1.41/containers/${encodeURIComponent(containerId)}/logs?stdout=1&stderr=1&follow=1&since=${since}`;
  dockerRequest(path, 'GET', {}, (err, dres)=>{
    if (err || dres.statusCode >= 400) {
      res.write(`data: [codelogs] error starting stream\n\n`);
      return;
    }
    const demux = createDockerDemux(line=>{
      res.write(`data: ${line.replace(/\r?\n/g,' ')}\n\n`);
    });
    dres.on('data', chunk => demux(chunk));
    dres.on('end',  ()=> { try{res.write(`data: [codelogs] ended\n\n`);}catch(_){} });
  });
}

// Detect whether we can use Docker logs
try {
  require('fs').accessSync(DOCKER_SOCK);
  docker.enabled = true;
} catch(_) {
  docker.enabled = false;
}

/* --------------------- splash HTML (with live code logs) -------------------- */

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
h3{margin:0;font-size:14px;font-weight:600}
pre{margin:0;padding:12px 14px;border-top:1px solid #374151;max-height:300px;overflow:auto;font-size:12px;line-height:1.35;background:#0b1220}
kbd{background:#111827;border:1px solid #374151;border-radius:6px;padding:2px 6px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.badge{font-size:11px;opacity:.8}
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Codestrap is connecting to code-server…</h1>
  <div class="small subtitle">This may take some time.</div>
  <div class="small" id="tip">Starting services…</div>

  <div class="container">
    <div class="card">
      <div class="head">
        <h3>Live logs: code-server container</h3>
        <span class="badge" id="log-status">initializing…</span>
      </div>
      <pre id="log"></pre>
    </div>
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
  const statusEl = document.getElementById('log-status');

  function setTip(t){ if(tipEl) tipEl.textContent=t; }
  function setStatus(t){ if(statusEl) statusEl.textContent=t; }
  function addLines(t){
    if (!logEl || !t) return;
    logEl.textContent += t.replace(/\\r?\\n/g,'\\n');
    logEl.scrollTop = logEl.scrollHeight;
  }

  // Seed recent lines (snapshot), then follow via SSE.
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
  const u = url.parse(req.url || '/', true);

  // Health endpoint
  if (u.pathname === '/__up') {
    return probeAndNote(ok=>{
      res.writeHead(ok?200:503, {'content-type':'text/plain','cache-control':'no-store'}).end(ok?'OK':'DOWN');
    });
  }

  // Proxy ring-buffer logs (snapshot) — not shown in UI now, but handy for debug
  if (u.pathname === '/__logs') {
    res.writeHead(200, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
    return res.end(getLogsText());
  }

  // Proxy SSE (internal)
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

  // Code container logs (snapshot)
  if (u.pathname === '/__code_logs') {
    if (!docker.enabled) {
      res.writeHead(503, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
      return res.end('[codelogs] docker socket not available\n');
    }
    resolveContainerId((err, id)=>{
      if (err || !id) {
        res.writeHead(503, {'content-type':'text/plain; charset=utf-8','cache-control':'no-store'});
        return res.end('[codelogs] container not found\n');
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

  // Code container logs (follow via SSE)
  if (u.pathname === '/__code_events') {
    if (!docker.enabled) {
      res.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no'
      });
      res.write(`data: [codelogs] docker socket not available\n\n`);
      return;
    }
    resolveContainerId((err, id)=>{
      res.writeHead(200, {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-store, no-cache, max-age=0',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no'
      });
      if (err || !id) {
        res.write(`data: [codelogs] container not found\n\n`);
        return;
      }
      // since now-20s so a little context on connect
      const since = Math.floor(Date.now()/1000) - 20;
      streamDockerLogs(id, res, since);
      req.on('close', ()=>{ try{res.end();}catch(_){ } });
    });
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
      if ((pr.statusCode||500) === 503) Object.assign(pr.headers, noStoreHeaders());
      res.writeHead(pr.statusCode || 502, pr.headers);
      pr.pipe(res);
      pr.on('end', ()=> pushLog(`${req.method} ${req.url} → ${pr.statusCode||0}`));
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
  if (docker.enabled) {
    pushLog(`docker logs enabled (sock: ${DOCKER_SOCK}) — container: ${CODE_CONTAINER||'(resolve via service ' + CODE_SERVICE + ')'}`);
  } else {
    pushLog(`docker logs disabled (socket not mounted at ${DOCKER_SOCK})`);
  }
});
