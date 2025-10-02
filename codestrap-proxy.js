// codestrap-proxy.js — HTTP-only reverse proxy to code-server on 8443
// Env: PROXY_PORT (8093 default), UP_HOST ("code"), UP_PORT (8443)
const http = require('http');
const net  = require('net');

const PROXY_PORT = +process.env.PROXY_PORT || 8093;
const UP_HOST    = process.env.UP_HOST || 'code';
const UP_PORT    = +process.env.UP_PORT || 8443;

function upstreamAlive(cb){
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
  let done = false;
  const finish = ok => { if (done) return; done = true; try{s.destroy();}catch(_){ } cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error',  ()=>finish(false));
  s.setTimeout(700,()=>finish(false));
}

const restartingHtml = `<!doctype html><meta charset="utf-8">
<title>code-server…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
.wrap{height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
.spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
@keyframes spin{to{transform:rotate(360deg)}}</style>
<div class="wrap"><div class="spinner"></div><h1>Connecting to code-server…</h1></div>`;

const server = http.createServer((req,res)=>{
  if (req.url === '/__up') {
    return upstreamAlive(ok=>{
      res.writeHead(ok?200:503, {'content-type':'text/plain'}).end(ok?'OK':'DOWN');
    });
  }

  upstreamAlive(ok=>{
    if (!ok) {
      res.writeHead(503, {'content-type':'text/html; charset=utf-8','cache-control':'no-store','retry-after':'1'});
      return res.end(restartingHtml);
    }

    // strip hop-by-hop
    const headers = { ...req.headers };
    delete headers.connection;
    delete headers.upgrade;
    delete headers['proxy-connection'];
    delete headers['keep-alive'];
    delete headers['transfer-encoding'];

    // forward info
    headers['x-forwarded-proto'] = 'http';
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

// WebSocket proxy (ws → 8443)
server.on('upgrade', (req, client, head)=>{
  upstreamAlive(ok=>{
    if (!ok) return client.destroy();

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
