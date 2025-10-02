// codestrap-proxy.js (auto-detect TLS/HTTP upstream + noisy diagnostics)
//
// Env:
//   PROXY_PORT         default: 8080
//   UP_HOST            default: "127.0.0.1"
//   UP_PORT            default: 8443            (first TLS probe target)
//   UP_FALLBACK_PORT   default: 8080            (HTTP fallback target)
//   FORCE_MODE         optional: "https" | "http" (skip autodetect)
//   PROBE_INTERVAL_MS  default: 2000
//
// Endpoints:
//   /__up              200 OK when upstream reachable; 503 otherwise
//   /__mode            plain text: "https://host:port" or "http://host:port"

const http  = require('http');
const https = require('https');
const net   = require('net');
const tls   = require('tls');

const PROXY_PORT       = +process.env.PROXY_PORT || 8080;
const UP_HOST          = process.env.UP_HOST || '127.0.0.1';
const UP_PORT          = +(process.env.UP_PORT || 8443);
const UP_FALLBACK_PORT = +(process.env.UP_FALLBACK_PORT || 8080);
const FORCE_MODE       = (process.env.FORCE_MODE || '').toLowerCase(); // "", "https", "http"
const PROBE_INTERVAL_MS= +(process.env.PROBE_INTERVAL_MS || 2000);

let mode = FORCE_MODE === 'https' ? 'https'
         : FORCE_MODE === 'http'  ? 'http'
         : 'auto';

let current = { proto: 'https', port: UP_PORT, alive: false };
let lastLog = '';

function log(s){ console.log(s); lastLog = s; }
function info(){ return `${current.proto}://${UP_HOST}:${current.port}`; }

function probeOnce(cb){
  if (mode === 'http') return tcpProbe('http', UP_FALLBACK_PORT, cb);
  if (mode === 'https') return tlsProbe(UP_PORT, cb);

  // auto: try TLS first, then HTTP fallback
  tlsProbe(UP_PORT, ok=>{
    if (ok) return cb({ proto:'https', port:UP_PORT, alive:true });
    tcpProbe('http', UP_FALLBACK_PORT, ok2=>{
      if (ok2) return cb({ proto:'http', port:UP_FALLBACK_PORT, alive:true });
      cb({ proto:'https', port:UP_PORT, alive:false }); // default display
    });
  });
}

function tlsProbe(port, cb){
  const s = tls.connect({host:UP_HOST, port, servername:UP_HOST, rejectUnauthorized:false});
  let done=false;
  const finish = ok => { if (done) return; done=true; try{s.destroy();}catch{} cb(ok); };
  s.once('secureConnect', ()=>finish(true));
  s.once('error', ()=>finish(false));
  s.setTimeout(700, ()=>finish(false));
}
function tcpProbe(proto, port, cb){
  const s = net.connect({host:UP_HOST, port});
  let done=false;
  const finish = ok => { if (done) return; done=true; try{s.destroy();}catch{} cb(ok); };
  s.once('connect', ()=>finish(true));
  s.once('error', ()=>finish(false));
  s.setTimeout(700, ()=>finish(false));
}

function scheduleProbe(){
  probeOnce(next=>{
    const prev = `${current.proto}:${current.port}:${current.alive}`;
    current = next;
    const now  = `${current.proto}:${current.port}:${current.alive}`;
    if (now !== prev) {
      log(`[codestrap-proxy] upstream probe → ${current.alive?'UP':'DOWN'} @ ${info()} (mode=${mode||'auto'})`);
    }
  });
}
setInterval(scheduleProbe, PROBE_INTERVAL_MS);
scheduleProbe();

function h() { return current.proto === 'https' ? https : http; }

const restartingHtml = `<!doctype html><meta charset="utf-8"><title>Code server…</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{height:100%;margin:0;font:16px system-ui;background:#0f172a;color:#e5e7eb}
.wrap{height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;text-align:center;padding:24px}
.spinner{width:56px;height:56px;border-radius:50%;border:6px solid #334155;border-top-color:#e5e7eb;animation:spin 1s linear infinite;margin-bottom:16px}
@keyframes spin{to{transform:rotate(360deg)}}</style>
<div class="wrap"><div class="spinner"></div>
<h1>Connecting to code-server…</h1>
<div>Upstream: <code id="u"></code></div>
<pre style="opacity:.8">${lastLog || ''}</pre>
</div>
<script>document.getElementById('u').textContent = location.origin + '/__mode'; fetch('/__up',{cache:'no-store'}).then(r=>{if(r.ok)location.reload()}).catch(()=>{}); setTimeout(()=>location.reload(),1500)</script>`;

const server = http.createServer((req,res)=>{
  if (req.url === '/__up') {
    return probeOnce(next=>{
      res.writeHead(next.alive?200:503, {'content-type':'text/plain'}).end(next.alive?'OK':'DOWN');
    });
  }
  if (req.url === '/__mode') {
    return res.writeHead(200, {'content-type':'text/plain'}).end(info());
  }

  if (!current.alive) {
    res.writeHead(503, {'content-type':'text/html; charset=utf-8','cache-control':'no-store','retry-after':'1'});
    return res.end(restartingHtml);
  }

  // proxy request
  const headers = { ...req.headers };
  // hop-by-hop
  delete headers.connection; delete headers.upgrade; delete headers['proxy-connection'];
  delete headers['keep-alive']; delete headers['transfer-encoding'];
  // x-forwarded
  headers['x-forwarded-proto'] = current.proto;
  headers['x-forwarded-host']  = headers['x-forwarded-host'] || req.headers['host'];
  if (req.socket?.remoteAddress) {
    headers['x-forwarded-for'] = headers['x-forwarded-for']
      ? `${headers['x-forwarded-for']}, ${req.socket.remoteAddress}`
      : req.socket.remoteAddress;
  }

  const p = h().request({
    hostname: UP_HOST,
    port: current.port,
    path: req.url,
    method: req.method,
    headers,
    rejectUnauthorized: false,
    servername: UP_HOST
  }, pr=>{
    res.writeHead(pr.statusCode || 502, pr.headers);
    pr.pipe(res);
  });

  p.on('error', (e)=>{
    log(`[codestrap-proxy] proxy error → ${e.code || e.message} while contacting ${info()}`);
    res.writeHead(503, {'content-type':'text/html; charset=utf-8','cache-control':'no-store','retry-after':'1'});
    res.end(restartingHtml);
  });

  req.pipe(p);
});

server.on('upgrade', (req, client, head)=>{
  if (!current.alive) return client.destroy();
  const upstream = current.proto === 'https'
    ? tls.connect({host:UP_HOST, port:current.port, servername:UP_HOST, rejectUnauthorized:false})
    : net.connect(current.port, UP_HOST);

  upstream.on('connect', send);
  upstream.on('secureConnect', send);

  function send(){
    const lines = [];
    lines.push(`${req.method} ${req.url} HTTP/${req.httpVersion}`);
    for (const [k,v] of Object.entries(req.headers)) lines.push(`${k}: ${v}`);
    lines.push('', '');
    upstream.write(lines.join('\r\n'));
    if (head?.length) upstream.write(head);
    upstream.pipe(client); client.pipe(upstream);
  }

  upstream.on('error', ()=>client.destroy());
  client.on('error',  ()=>upstream.destroy());
});

server.listen(PROXY_PORT, '0.0.0.0', ()=>{
  log(`[codestrap-proxy] listening on 0.0.0.0:${PROXY_PORT} (mode=${mode||'auto'}) — probing upstream…`);
});
