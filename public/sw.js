// Service worker: turns a stream of chunks pushed by the page (received over a
// WebRTC DataChannel) into a regular browser download, so that a direct
// transfer never has to hold the whole file in memory.
//
// The page sends {type: 'dl-open', id, name, size} with a MessagePort, then
// pushes ArrayBuffers on that port, then {type: 'dl-end'} (or 'dl-abort').
// Navigating to /dl/<id> is answered with a streaming attachment response.

const streams = new Map();

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'dl-open' || !event.ports[0]) return;
  const port = event.ports[0];
  let controller = null;
  const stream = new ReadableStream({
    start(c) { controller = c; },
    cancel() {
      streams.delete(data.id);
      port.postMessage({ type: 'dl-cancel' });
    }
  });
  port.onmessage = (e) => {
    const msg = e.data;
    try {
      if (msg instanceof ArrayBuffer) {
        controller.enqueue(new Uint8Array(msg));
      } else if (msg && msg.type === 'dl-end') {
        controller.close();
      } else if (msg && msg.type === 'dl-abort') {
        streams.delete(data.id);
        controller.error(new Error('transfer aborted'));
      }
    } catch (err) {
      // Stream already closed or errored (e.g. download cancelled).
    }
  };
  streams.set(data.id, { name: String(data.name || 'download'), size: data.size, stream });
  port.postMessage({ type: 'dl-ready' });
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const match = url.pathname.match(/^\/dl\/([a-f0-9-]{36})$/i);
  if (!match) return;
  const entry = streams.get(match[1]);
  if (!entry) return;
  streams.delete(match[1]);
  const asciiName = entry.name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const headers = {
    'Content-Type': 'application/octet-stream',
    'Content-Disposition': `attachment; filename="${asciiName}"; filename*=UTF-8''${encodeURIComponent(entry.name)}`,
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'no-store'
  };
  if (typeof entry.size === 'number') headers['Content-Length'] = String(entry.size);
  event.respondWith(new Response(entry.stream, { headers }));
});
