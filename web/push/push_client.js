/*
 * Euro Trade — Push client helper (window.euroPush)
 * Loaded from index.html. Registers the push service worker at its own scope
 * and exposes permission + subscription helpers to the Flutter/Dart layer.
 */
(function () {
  var SW_PATH = 'push/push_sw.js';   // relative to <base href>
  var SW_SCOPE = 'push/';            // distinct scope → no clash with Flutter's SW

  function urlBase64ToUint8Array(base64String) {
    var padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    var base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    var raw = atob(base64);
    var output = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i);
    return output;
  }

  function registration() {
    return navigator.serviceWorker.register(SW_PATH, { scope: SW_SCOPE });
  }

  window.euroPush = {
    isSupported: function () {
      return (
        'serviceWorker' in navigator &&
        'PushManager' in window &&
        'Notification' in window
      );
    },

    // Current app URL — passed into notifications so a click reopens the app.
    appUrl: function () {
      try {
        return location.href.split('#')[0];
      } catch (e) {
        return '';
      }
    },

    // Prompt for notification permission. Returns 'granted' | 'denied' | 'default'.
    requestPermission: async function () {
      if (!('Notification' in window)) return 'denied';
      try {
        return await Notification.requestPermission();
      } catch (e) {
        return 'denied';
      }
    },

    // Ensure a push subscription exists; returns the subscription JSON string
    // (endpoint + keys) ready to persist server-side, or null on failure.
    subscribe: async function (vapidPublicKey) {
      try {
        if (!this.isSupported() || !vapidPublicKey) return null;
        if (Notification.permission !== 'granted') {
          var perm = await this.requestPermission();
          if (perm !== 'granted') return null;
        }
        var reg = await registration();
        try { await navigator.serviceWorker.ready; } catch (e) {}
        var sub = await reg.pushManager.getSubscription();
        if (!sub) {
          sub = await reg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
          });
        }
        return JSON.stringify(sub);
      } catch (e) {
        console.warn('euroPush.subscribe failed', e);
        return null;
      }
    }
  };
})();
