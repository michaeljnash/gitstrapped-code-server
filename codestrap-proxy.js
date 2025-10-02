// codestrap-proxy.js — HTTP-only reverse proxy to code-server on 8443
// Env: PROXY_PORT (8080 default), UP_HOST ("code"), UP_PORT (8443)
// Shows a splash that auto-polls /__up and reloads when code-server is ready.

const http = require('http');
const net  = require('net');

const PROXY_PORT = +(process.env.PROXY_PORT || 8080);
const UP_HOST    = process.env.UP_HOST || 'code';
const UP_PORT    = +(process.env.UP_PORT || 8443);

// How long to wait for a TCP connect to the upstream before declaring DOWN
const UPSTREAM_CONNECT_TIMEOUT_MS = +(process.env.UP_TIMEOUT_MS || 2500);

function upstreamAlive(cb){
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error',  ()=>finish(false));
  s.setTimeout(UPSTREAM_CONNECT_TIMEOUT_MS,()=>finish(false));
}

// Auto-polling splash (no-cache) that reloads original URL when /__up is OK.
function makeSplashHtml() {
  return `<!doctype html><meta charset="utf-8">
<title>code-server…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
.wrap{height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
.spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
@keyframes spin{to{transform:rotate(360deg)}}
.small{opacity:.7;font-size:13px;margin-top:8px}
.subtitle{margin-top: -15px; font-weight: 600;}
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Codestrap is connecting to code-server…</h1>
  <div class="small subtitle">This may take some time!</div>
  <br/>
  <div class="small" id="tip">Starting services…</div>
</div>
<script>
(function(){
  let delay = 600, maxDelay = 5000, tries = 0;
  const original = location.href;
  function setTip(t){ var el=document.getElementById('tip'); if(el) el.textContent=t; }
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

function noStoreHeaders(extra = {}) {
  return Object.assign({
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
    'pragma': 'no-cache',
    'expires': '0',
    'retry-after': '1'
  }, extra);
}

const server = http.createServer((req,res)=>{
  // Lightweight health endpoint used by the splash polling JS.
  if (req.url === '/__up' || req.url.startsWith('/__up?')) {
    return upstreamAlive(ok=>{
      res.writeHead(ok?200:503, {'content-type':'text/plain','cache-control':'no-store'}).end(ok?'OK':'DOWN');
    });
  }

  upstreamAlive(ok=>{
    if (!ok) {
      console.log('[proxy] upstream DOWN →', req.method, req.url);
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
      // Pass-through response; ensure no cache on 503 just in case
      if ((pr.statusCode||500) === 503) {
        Object.assign(pr.headers, noStoreHeaders());
      }
      res.writeHead(pr.statusCode || 502, pr.headers);
      pr.pipe(res);
      pr.on('end', ()=> {
        const sc = pr.statusCode || 0;
        console.log('[proxy]', req.method, req.url, '→', sc);
      });
    });

    p.on('error', (e)=>{
      console.log('[proxy] error piping to upstream:', e.message);
      res.writeHead(503, noStoreHeaders());
      res.end(makeSplashHtml());
    });

    req.pipe(p);
  });
});

// WebSocket proxy (ws → 8443)
server.on('upgrade', (req, client, head)=>{
  upstreamAlive(ok=>{
    if (!ok) {
      client.destroy();
      return;
    }
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
    upstream.on('error', ()=>client.destroy());
    client.on('error',  ()=>upstream.destroy());
  });
});

server.listen(PROXY_PORT, '0.0.0.0', ()=>{
  console.log(`[codestrap-proxy] listening on 0.0.0.0:${PROXY_PORT} → upstream http://${UP_HOST}:${UP_PORT}`);
});
