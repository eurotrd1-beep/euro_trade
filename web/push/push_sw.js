/*
 * Euro Trade — Push Service Worker
 * Dedicated to Web Push. Registered at a distinct scope (/…/push/) so it never
 * collides with Flutter's own flutter_service_worker.js (offline caching).
 * Handles incoming push messages and notification clicks.
 */

self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

// Show a notification for each incoming push.
self.addEventListener('push', function (event) {
  var data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'Euro Trade', body: event.data ? event.data.text() : '' };
  }

  var title = data.title || 'Euro Trade';
  var options = {
    body: data.body || '',
    icon: data.icon || '../logo.jpg',
    badge: data.badge || '../logo.jpg',
    tag: data.tag || 'euro-signal',
    renotify: true,
    requireInteraction: false,
    vibrate: [200, 100, 200],
    dir: data.dir || 'auto',
    data: { url: data.url || '' }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

// Focus the existing app tab (or open it) on the signals page when tapped.
self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var targetUrl = (event.notification.data && event.notification.data.url) || '';

  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then(function (clientList) {
        for (var i = 0; i < clientList.length; i++) {
          var client = clientList[i];
          // Reuse an already-open app tab.
          if ('focus' in client) {
            client.focus();
            if (targetUrl && client.navigate) {
              try { client.navigate(targetUrl); } catch (e) {}
            }
            return;
          }
        }
        if (self.clients.openWindow) {
          return self.clients.openWindow(targetUrl || '../');
        }
      })
  );
});
