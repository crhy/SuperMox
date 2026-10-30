import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';
const args = process.argv.slice(2);
const value = (flag, fallback) => args.includes(flag) ? args[args.indexOf(flag) + 1] : fallback;
const port = Number(value('--port', '3000'));
const host = value('--host', '127.0.0.1');
const root = resolve(import.meta.dirname);
const types = { '.html':'text/html; charset=utf-8', '.css':'text/css', '.js':'text/javascript', '.svg':'image/svg+xml', '.pdf':'application/pdf' };
http.createServer(async (req, res) => {
 try {
  const path = resolve(root, '.' + decodeURIComponent(new URL(req.url, 'http://local').pathname));
  if (path !== root && !path.startsWith(root + sep)) { res.writeHead(403).end(); return; }
  const file = path === root ? resolve(root, 'index.html') : path;
  const bytes = await readFile(file);
  res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream' }); res.end(bytes);
 } catch { res.writeHead(404).end('Not found'); }
}).listen(port, host, () => console.log(`Local: http://${host}:${port}`));
