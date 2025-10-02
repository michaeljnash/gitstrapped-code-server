// codestrap-proxy.js — Reverse proxy + splash + optional live logs for code-server
// Env:
//   PROXY_PORT           (e.g. "8080")
//   CODE_SERVICE_NAME    (e.g. "code")  ← required
//   CODE_EXPOSED_PORT    (e.g. "8443")
// Optional:
//   UP_TIMEOUT_MS        (tcp connect timeout to upstream; default 2500)

const http = require('http');
const net  = require('net');
const url  = require('url');

// ---- Config
const PROXY_PORT        = +(process.env.PROXY_PORT || 8080);
const CODE_SERVICE_NAME = process.env.CODE_SERVICE_NAME; // required
const CODE_EXPOSED_PORT = +(process.env.CODE_EXPOSED_PORT || 8443);
const UPSTREAM_CONNECT_TIMEOUT_MS = +(process.env.UP_TIMEOUT_MS || 2500);

if (!CODE_SERVICE_NAME) {
  console.error('[codestrap-proxy][FATAL] CODE_SERVICE_NAME env must be set.');
  process.exit(2);
}

const UP_HOST = CODE_SERVICE_NAME;
const UP_PORT = CODE_EXPOSED_PORT;

// ---- Docker access (for live logs panel)
const DOCKER_SOCKET = '/var/run/docker.sock';

// Cache container id lookups for a few seconds
let _cidCache = { id: null, at: 0 };
const CID_TTL_MS = 10_000;

function dockerRequest(path, opts = {}, onRes) {
  const req = http.request({
    socketPath: DOCKER_SOCKET,
    path,
    method: opts.method || 'GET',
    headers: opts.headers || {}
  }, onRes);
  req.on('error', err => onRes?.({ statusCode: 500, headers: {}, on: (ev, cb)=> (ev==='data'?cb(Buffer.from(String(err))): ev==='end'?cb():null) }));
  if (opts.body) req.end(opts.body); else req.end();
}

function resolveCodeContainerId(cb) {
  const now = Date.now();
  if (_cidCache.id && (now - _cidCache.at) < CID_TTL_MS) return cb(null, _cidCache.id);

  // Prefer compose label match: com.docker.compose.service=CODE_SERVICE_NAME
  const filters = encodeURIComponent(JSON.stringify({
    label: [`com.docker.compose.service=${CODE_SERVICE_NAME}`]
  }));
  dockerRequest(`/containers/json?limit=50&filters=${filters}`, {}, res => {
    const bufs = [];
    res.on('data', c => bufs.push(c));
    res.on('end', () => {
      try {
        const arr = JSON.parse(Buffer.concat(bufs).toString('utf8'));
        let id = null;
        if (Array.isArray(arr) && arr.length) {
          // Pick the one actually running if multiple
          const running = arr.find(c => c.State === 'running') || arr[0];
          id = running.Id;
        }
        if (!id) {
          // Fallback: name match
          const filters2 = encodeURIComponent(JSON.stringify({ name: [CODE_SERVICE_NAME] }));
          dockerRequest(`/containers/json?limit=50&filters=${filters2}`, {}, res2 => {
            const bufs2 = [];
            res2.on('data', c => bufs2.push(c));
            res2.on('end', () => {
              try {
                const arr2 = JSON.parse(Buffer.concat(bufs2).toString('utf8'));
                let id2 = null;
                if (Array.isArray(arr2) && arr2.length) {
                  const running2 = arr2.find(c => c.State === 'running') || arr2[0];
                  id2 = running2.Id;
                }
                if (id2) {
                  _cidCache = { id: id2, at: Date.now() };
                  cb(null, id2);
                } else {
                  cb(new Error('container not found'));
                }
              } catch (e) { cb(e); }
            });
          });
          return;
        }
        _cidCache = { id, at: Date.now() };
        cb(null, id);
      } catch (e) { cb(e); }
    });
  });
}

// Docker logs framing demux (when TTY=false)
function demuxDockerFrames(stream, onLine) {
  let buf = Buffer.alloc(0);

  function emitText(b) {
    // Split by newlines, emit lines
    const txt = b.toString('utf8').replace(/\r\n/g, '\n');
    const parts = txt.split('\n');
    for (let i = 0; i < parts.length; i++) {
      if (i === parts.length - 1 && parts[i] === '') continue;
      onLine(parts[i]);
    }
  }

  stream.on('data', chunk => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 8) {
      // header: 8 bytes
      const msgLen = buf.readUInt32BE(4);
      if (buf.length < 8 + msgLen) break;
      const payload = buf.slice(8, 8 + msgLen);
      emitText(payload);
      buf = buf.slice(8 + msgLen);
    }
  });
  stream.on('end', () => {
    if (buf.length > 0) emitText(buf);
  });
}

// ---- Upstream availability probe
function upstreamAlive(cb) {
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try { s.destroy(); } catch(_){} cb(ok); };
  s.once('connect', () => finish(true));
  s.once('error',   () => finish(false));
  s.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS, () => finish(false));
}

function noStoreHeaders(extra = {}) {
  return Object.assign({
    'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
    'pragma': 'no-cache',
    'expires': '0',
    'retry-after': '1'
  }, extra);
}

// ---- Splash HTML (auto polls /__up; has collapsible live logs)
function makeSplashHtml() {
  const escService = String(CODE_SERVICE_NAME);
  return `<!doctype html><meta charset="utf-8">
<title>code-server…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  :root { color-scheme: dark; }
  html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
  .wrap{height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
  .spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
  @keyframes spin{to{transform:rotate(360deg)}}
  .small{opacity:.75;font-size:13px;margin-top:8px}
  .subtitle{margin-top:-12px;font-weight:700}
  .tipline{display:inline-flex;align-items:baseline;gap:.25rem}
  .dots{display:inline-block; width:1.5em; text-align:left}
  details{margin-top:18px; max-width: 900px; width: 90%;}
  details > summary { cursor: pointer; list-style: none; }
  details > summary::-webkit-details-marker { display: none; }
  details > summary::after {
    content: '▸';
    display: inline-block;
    margin-left: .5ch;
    transform: translateY(-.05em);
  }
  details[open] > summary::after { content: '▾'; }
  .logbox {
    box-sizing: border-box;
    margin-top:10px; padding:10px 12px;
    background:#0b1220;border:1px solid #1f2a44;border-radius:10px;
    font:12px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    height: 320px; overflow:auto; text-align:left; white-space:pre-wrap;
  }
  .badge{display:inline-block;background:#1f2a44;border:1px solid #334155;color:#cbd5e1;border-radius:999px;padding:2px 8px;font:12px/18px system-ui}
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Codestrap is connecting to code-server…</h1>
  <div class="small subtitle">This may take some time.</div>
  <br/>
  <div class="small tipline">
    <span>Starting services</span><span id="dots" class="dots">&nbsp;&nbsp;&nbsp;</span>
    <span class="badge">${escService} logs</span>
  </div>

  <details id="logsPanel">
    <summary>Show live logs</summary>
    <div id="logbox" class="logbox" aria-live="polite"></div>
  </details>
</div>
<script>
(function(){
  // --- dots animation (fixed-width, no layout shift)
  const NBSP = '\\u00A0';
  const dotsEl = document.getElementById('dots');
  const frames = [NBSP+NBSP+NBSP, '.'+NBSP+NBSP, '..'+NBSP, '...'];
  let fi = 0;
  function tickDots(){ dotsEl.textContent = frames[fi = (fi+1) % frames.length]; }
  setInterval(tickDots, 350); // start immediately
  tickDots();

  // --- health polling
  let delay = 600, maxDelay = 5000;
  const original = location.href;
  async function ping(){
    try{
      const res = await fetch('/__up?ts=' + Date.now(), {cache:'no-store', credentials:'same-origin'});
      if (res.ok) { location.replace(original); return; }
    }catch(e){}
    const jitter = Math.random()*150;
    delay = Math.min(maxDelay, Math.round(delay*1.6) + jitter);
    setTimeout(ping, delay);
  }
  setTimeout(ping, delay);

  // --- live logs (hidden by default; start when panel opens)
  const panel = document.getElementById('logsPanel');
  const box   = document.getElementById('logbox');
  let es = null;
  function startLogs(){
    if (es) return;
    es = new EventSource('/__logs?ts='+Date.now());
    es.onmessage = (e)=>{
      if (!e.data) return;
      box.textContent += e.data + '\\n';
      const lines = box.textContent.split('\\n');
      if (lines.length > 800) box.textContent = lines.slice(-500).join('\\n');
      box.scrollTop = box.scrollHeight;
    };
    es.onerror = ()=>{ /* keep alive; reconnect handled by browser */ };
  }
  function stopLogs(){ if (es) { es.close(); es=null; } }
  panel.addEventListener('toggle', ()=>{ if (panel.open) startLogs(); else stopLogs(); });
})();
</script>`;
}

// ---- HTTP server
const server = http.createServer((req, res) => {
  const u = url.parse(req.url, true);

  // Health endpoint for splash polling
  if (u.pathname === '/__up') {
    return upstreamAlive(ok => {
      res.writeHead(ok ? 200 : 503, { 'content-type':'text/plain', 'cache-control':'no-store' });
      res.end(ok ? 'OK' : 'DOWN');
    });
  }

  // Live logs via Server-Sent Events
  if (u.pathname === '/__logs') {
    // SSE headers
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no'
    });

    let closed = false;
    req.on('close', () => { closed = true; });

    const send = (line) => {
      if (closed) return;
      const safe = String(line).replace(/\u0000/g, '');
      res.write('data: ' + safe + '\n\n');
    };

    resolveCodeContainerId((err, cid) => {
      if (err || !cid) {
        send('[logs] unable to resolve container for service: ' + CODE_SERVICE_NAME);
        return;
      }

      // Tail last ~200 lines, then follow
      const q = new url.URLSearchParams({
        stdout: '1', stderr: '1', follow: '1', tail: '200'
      }).toString();

      const path = `/containers/${cid}/logs?${q}`;
      const r = http.request({ socketPath: DOCKER_SOCKET, path, method: 'GET' }, (dr) => {
        const ct = (dr.headers['content-type'] || '').toLowerCase();
        const isRaw = ct.includes('application/vnd.docker.raw-stream');

        if (isRaw) {
          dr.setEncoding('utf8');
          dr.on('data', chunk => {
            chunk.split(/\r?\n/).forEach(line => { if (line) send(line); });
          });
        } else {
          demuxDockerFrames(dr, send);
        }
        dr.on('end', () => { /* stream ended */ });
      });

      r.on('error', e => send('[logs] error: ' + e.message));
      r.end();
    });

    return;
  }

  // Proxy flow
  upstreamAlive(ok => {
    if (!ok) {
      console.log('[proxy] upstream DOWN →', req.method, req.url);
      res.writeHead(503, noStoreHeaders({ 'content-type': 'text/html; charset=utf-8' }));
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
      const sc = pr.statusCode || 502;
      const ct = (pr.headers['content-type'] || '').toLowerCase();

      // Force-dark login page only
      const isLoginHtml = req.method === 'GET'
        && req.url.split('?')[0] === '/login'
        && ct.includes('text/html');

      if (!isLoginHtml) {
        if (sc === 503) Object.assign(pr.headers, noStoreHeaders());
        res.writeHead(sc, pr.headers);
        pr.pipe(res);
        pr.on('end', () => console.log('[proxy]', req.method, req.url, '→', sc));
        return;
      }

      // Rewrite login HTML to force dark
      const chunks = [];
      pr.on('data', c => chunks.push(c));
      pr.on('end', () => {
        let html = Buffer.concat(chunks).toString('utf8');
        const inject = `
<style id="codestrap-force-dark">
  html { background:#0f172a !important; }
  html, body { color-scheme: dark !important; }
  html { filter: invert(1) hue-rotate(180deg); }
  img, video, svg, canvas, [style*="background-image"] { filter: invert(1) hue-rotate(180deg) !important; }
</style>`.trim();

        if (html.includes('</head>')) {
          html = html.replace('</head>', inject + '\n</head>');
        } else if (html.includes('<body')) {
          html = html.replace(/<body([^>]*)>/i, `<body$1>${inject}`);
        } else {
          html = inject + html;
        }

        const outHeaders = {
          ...pr.headers,
          ...noStoreHeaders({ 'content-type': 'text/html; charset=utf-8' }),
          'content-length': Buffer.byteLength(html, 'utf8')
        };
        res.writeHead(sc, outHeaders);
        res.end(html);
        console.log('[proxy]', req.method, req.url, '→', sc, '(forced dark)');
      });

      pr.on('error', () => {
        res.writeHead(503, noStoreHeaders({ 'content-type': 'text/html; charset=utf-8' }));
        res.end(makeSplashHtml());
      });
    });

    p.on('error', (e) => {
      console.log('[proxy] error piping to upstream:', e.message);
      res.writeHead(503, noStoreHeaders({ 'content-type': 'text/html; charset=utf-8' }));
      res.end(makeSplashHtml());
    });

    req.pipe(p);
  });
});

// WebSocket proxy (ws → upstream)
server.on('upgrade', (req, client, head) => {
  upstreamAlive(ok => {
    if (!ok) { client.destroy(); return; }
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
    upstream.on('error', () => client.destroy());
    client.on('error',  () => upstream.destroy());
  });
});

server.listen(PROXY_PORT, '0.0.0.0', () => {
  console.log(`[codestrap-proxy] listening on 0.0.0.0:${PROXY_PORT} → upstream http://${UP_HOST}:${UP_PORT}`);
});
