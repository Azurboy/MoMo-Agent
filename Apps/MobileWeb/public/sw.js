'use strict';
const cacheName = 'momo-mobile-shell-1';
// Only public, identical-for-all assets are eligible. Navigation and API replies never enter this cache.
const publicAssets = new Set(['/offline.html', '/install', '/mobile.css', '/install.js', '/icons.svg', '/icons/180.png', '/assets/wordmark.svg']);
self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName);
    await cache.addAll([...publicAssets].map(path => new Request(path, {credentials: 'omit', cache: 'reload'})));
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(name => name.startsWith('momo-mobile-shell-') && name !== cacheName).map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  if (request.mode === 'navigate' && ['/', '/install'].includes(url.pathname)) {
    event.respondWith(fetch(request).catch(async () => {
      const cache = await caches.open(cacheName);
      return (await cache.match(url.pathname === '/install' ? '/install' : '/offline.html')) || Response.error();
    }));
  } else if (!url.search && publicAssets.has(url.pathname)) {
    event.respondWith(caches.open(cacheName).then(async cache => (await cache.match(url.pathname)) || fetch(request)));
  }
});
