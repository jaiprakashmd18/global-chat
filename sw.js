// =============================================================================
// GlobalChat — service worker
//
// Makes the site installable and lets the page shell open offline. Strategy:
// network first for our own files (so a new deploy is picked up right away),
// falling back to the cached copy when offline. Requests to other origins
// (Supabase, jsDelivr) are never touched: chat data is never cached here.
// =============================================================================
const CACHE = 'globalchat-shell-v1';
const SHELL = [
  './', 'index.html', 'styles.css', 'theme.js', 'app.js', 'config.js', 'favicon.svg',
  'manifest.webmanifest', 'icons/icon-192.png',
  'fonts/atkinson-hyperlegible-latin-400-normal.woff2',
  'fonts/atkinson-hyperlegible-latin-700-normal.woff2',
  'fonts/bricolage-grotesque-latin-600-normal.woff2',
  'fonts/bricolage-grotesque-latin-800-normal.woff2',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  if (url.pathname.endsWith('/admin.html') || url.pathname.endsWith('/admin.js')) return;

  event.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res.ok && res.type === 'basic') {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
      }
      return res;
    } catch (err) {
      const cached = await caches.match(req, { ignoreSearch: req.mode === 'navigate' });
      if (cached) return cached;
      if (req.mode === 'navigate') return (await caches.match('index.html')) ?? Response.error();
      throw err;
    }
  })());
});
