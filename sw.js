/* 煎福 PWA Service Worker：App Shell 快取 + 離線備援 */
const CACHE = 'jianfu-v4';
const SHELL = ['./', './index.html', './manifest.webmanifest',
  './icons/icon-192.png', './icons/icon-512.png', './icons/icon-maskable-512.png', './icons/apple-touch-icon.png', './icons/favicon-32.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // 頁面：網路優先，離線時回退快取
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(res => { caches.open(CACHE).then(c => c.put(req, res.clone())); return res; })
      .catch(() => caches.match(req).then(h => h || caches.match('./index.html'))));
    return;
  }
  // 其他資源（CDN、圖片、字型）：快取優先，同時背景更新
  e.respondWith(caches.match(req).then(hit => {
    const net = fetch(req).then(res => {
      if (res && (res.ok || res.type === 'opaque')) caches.open(CACHE).then(c => c.put(req, res.clone()));
      return res;
    }).catch(() => hit);
    return hit || net;
  }));
});
