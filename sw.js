// 원파이브 서비스 워커: 앱 설치(홈 화면 추가)만을 위한 거예요. 저장(캐시)은 하지 않아서 항상 최신 내용을 보여줘요.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
