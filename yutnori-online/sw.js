/* 윷놀이 온라인 — 오프라인 지원
   인터넷이 없어도 화면이 뜨고 '혼자 연습'을 할 수 있게 앱 파일을 저장해 둔다.
   항상 네트워크를 먼저 시도하므로 새로 배포한 내용이 바로 반영된다. */
const CACHE = 'yut-v1';
const SHELL = [
  './', './index.html', './config.js', './manifest.webmanifest',
  './icon-32.png', './icon-180.png', './icon-192.png', './icon-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(SHELL).catch(() => {}))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  // 서버(Supabase)와 글꼴은 손대지 않는다 — 늘 네트워크로
  if (url.origin !== self.location.origin) return;

  e.respondWith(
    fetch(req)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() =>
        caches.match(req).then(hit => hit || caches.match('./index.html'))
      )
  );
});
