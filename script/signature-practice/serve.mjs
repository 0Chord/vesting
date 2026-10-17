import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

// 저장소 전체 대신 실습에 필요한 네 파일만 127.0.0.1에서 제공한다.
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.mjs', ['app.mjs', 'text/javascript; charset=utf-8']],
  ['/wallet.mjs', ['wallet.mjs', 'text/javascript; charset=utf-8']],
  ['/typed-data.mjs', ['typed-data.mjs', 'text/javascript; charset=utf-8']]
]);
const server = createServer(async (request, response) => {
  const asset = assets.get(request.url);
  if (request.headers.host !== '127.0.0.1:4173' || !['GET', 'HEAD'].includes(request.method) || !asset) {
    response.writeHead(404).end('Not found');
    return;
  }
  try {
    const body = await readFile(new URL(asset[0], import.meta.url));
    response.writeHead(200, {
      'Content-Type': asset[1], 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    });
    response.end(request.method === 'HEAD' ? undefined : body);
  } catch {
    response.writeHead(500).end('Unable to read practice file');
  }
});
server.on('error', error => { console.error(error.message); process.exitCode = 1; });
server.listen(4173, '127.0.0.1', () => console.log('MetaMask가 설치된 Chrome에서 http://127.0.0.1:4173 을 여세요. 종료: Ctrl+C'));
