// codestrap-proxy.js
// Splash + reverse proxy that works with HTTPS (self-signed) on LSIO code-server (8443).
// Env:
//   PROXY_PORT  (default 8080)
//   UP_HOST     (default "127.0.0.1")
//   UP_PORT     (default 8443)
//   UP_TLS      (default: true if port == 8443; otherwise false) — accepts "1|true|yes"

const http  = require('http');
const https = require('https');
const net   = require('net');
const tls   = require('tls');
const { URL } = require('url');

const PROXY_PORT = parseInt(process.env.PROXY_PORT || '8080', 10);
const UP_HOST    = process.env.UP_HOST || '127.0.0.1';
const UP_PORT    = parseInt(process.env.UP_PORT || '8443', 10);
const UP_TLS     = (() => {
  const raw = process.env.UP_TLS;
  if (raw == null) return UP_PORT === 8443;           // sane default for lsio
  return /^(1|true|yes)$/i.test(String(raw));
})();

const H = UP_TLS ? https : http;

const restartingHtml = `<!doctype html>
<meta charset="utf-8">
<title>Code server restarting…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  html,body{height:100%;margin:0;font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,sans-serif;background:#0f172a;color:#e5e7eb}
  .wrap{display:flex;align-items:center;justify-content:center;height:100%;flex-direction:column;text-align:center;padding:24px}
  .spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
  @keyframes spin{to{transform:rotate(360deg)}}
  .sub{opacity:.75}
  button{margin-top:16px;padding:8px 14px;border-radius:10px;border:1px solid #334155;background:#111827;color:#e5e7eb;cursor:pointer}
  button:disabled{opacity:.6;cursor:default}
</style>
<div class="wrap">
  <div class="spinner"></div>
  <h1>Restarting code server…</h1>
  <div class="sub">We’ll reconnect automatically.</div>
  <button id="reload" disabled>Reload now</button>
</div>
<script>
  const btn = document.getElementById('reload');
  btn.onclick = () => location.reload();
  async function ping(){
    try{
      const r = await fetch('/__up', {cache:'no-store'});
      if(r.ok){ btn.disabled = false; setTimeout(()=>location.reload(), 400); return; }
    }catch(e){}
    setTimeout(ping, 800);
  }
  ping();
</script>`;

function upstreamAlive(cb){
  const s = UP_TLS
    ? tls.connect({ host: UP_HOST, port: UP_PORT, servername: UP_HOST, rejectUnauthorized: false })
    : net.connect({ host: UP_HOST, port: UP_PORT });

  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('secureConnect', ()=>finish(true)); // fires only for TLS
  s.once('connect',       ()=>finish(true));
  s.once('error',         ()=>finish(false));
  s.setTimeout(500,       ()=>finish(false));
}

const server = http.createServer((req,res)=>{
  if (req.url === '/__up') {
    return upstreamAlive(ok=>{
      if (ok) res.writeHead(200, {'content-type':'text/plain'}).end('OK');
      else     res.writeHead(503, {'content-type':'text/plain','retry-after':'1'}).end('DOWN');
    });
  }

  upstreamAlive(ok=>{
    if (!ok) {
      res.writeHead(503, {'content-type':'text/html; charset=utf-8','cache-control':'no-store','retry-after':'1'});
      return res.end(restartingHtml);
    }

    // Proxy HTTP(S)
    const target = new URL(`${UP_TLS ? 'https' : 'http'}://${UP_HOST}:${UP_PORT}${req.url}`);
    const headers = { ...req.headers };

    // strip hop-by-hop
    delete headers['connection'];
    delete headers['upgrade'];
    delete headers['proxy-connection'];
    delete headers['keep-alive'];
    delete headers['transfer-encoding'];

    // forward addr info
    headers['x-forwarded-proto'] = headers['x-forwarded-proto'] || (UP_TLS ? 'https' : 'http');
    if (req.socket && req.socket.remoteAddress) {
      const prior = headers['x-forwarded-for'];
      headers['x-forwarded-for'] = prior ? `${prior}, ${req.socket.remoteAddress}` : req.socket.remoteAddress;
    }
    headers['x-forwarded-host'] = headers['x-forwarded-host'] || req.headers['host'];

    const p = H.request({
      hostname: target.hostname,
      port: target.port,
      path: target.pathname + (target.search || ''),
      method: req.method,
      headers,
      rejectUnauthorized: false, // accept lsio self-signed
      servername: UP_HOST
    }, pr => {
      res.writeHead(pr.statusCode || 502, pr.headers);
      pr.pipe(res);
    });

    p.on('error', ()=>{
      res.writeHead(503, {'content-type':'text/html; charset=utf-8','cache-control':'no-store','retry-after':'1'});
      res.end(restartingHtml);
    });

    req.pipe(p);
  });
});

// WebSocket tunneling (wss when UP_TLS=true)
server.on('upgrade', (req, client, head)=>{
  upstreamAlive(ok=>{
    if (!ok) { client.destroy(); return; }
    const upstream = UP_TLS
      ? tls.connect({ host: UP_HOST, port: UP_PORT, servername: UP_HOST, rejectUnauthorized: false })
      : net.connect(UP_PORT, UP_HOST);

    upstream.on('connect', () => send());
    upstream.on('secureConnect', () => send());

    function send(){
      const lines = [];
      lines.push(`${req.method} ${req.url} HTTP/${req.httpVersion}`);
      for (const [k, v] of Object.entries(req.headers)) lines.push(`${k}: ${v}`);
      lines.push('', '');
      upstream.write(lines.join('\r\n'));
      if (head && head.length) upstream.write(head);
      upstream.pipe(client);
      client.pipe(upstream);
    }

    upstream.on('error', ()=> client.destroy());
    client.on('error',  ()=> upstream.destroy());
  });
});

server.listen(PROXY_PORT, '0.0.0.0', ()=>{
  console.log(`[codestrap-proxy] listening on 0.0.0.0:${PROXY_PORT} → upstream ${UP_TLS?'https':'http'}://${UP_HOST}:${UP_PORT}`);
});
