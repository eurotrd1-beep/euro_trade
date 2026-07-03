/*
 * Euro Trade — Push client helper (window.euroPush)
 * Loaded from index.html. Registers the push service worker at its own scope
 * and exposes permission + subscription helpers to the Flutter/Dart layer.
 *
 * Subscription is exposed as a poll-based API (startSubscribe / isDone /
 * getResult) rather than a returned Promise — this avoids fragile dart:js
 * Promise bridging and is reliable across browsers.
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

  // Wait until the registration has an active service worker (or time out).
  function waitForActive(reg) {
    return new Promise(function (resolve) {
      if (reg.active) { resolve(); return; }
      var sw = reg.installing || reg.waiting;
      if (!sw) { resolve(); return; }
      sw.addEventListener('statechange', function () {
        if (sw.state === 'activated') resolve();
      });
      setTimeout(resolve, 6000); // safety net
    });
  }

  window.euroPush = {
    _done: false,
    _result: null,

    isSupported: function () {
      return (
        'serviceWorker' in navigator &&
        'PushManager' in window &&
        'Notification' in window
      );
    },

    // Current app URL — passed into notifications so a click reopens the app.
    appUrl: function () {
      try { return location.href.split('#')[0]; } catch (e) { return ''; }
    },

    // Fire the native permission prompt (result not needed by the caller).
    requestPermission: function () {
      try {
        if ('Notification' in window) Notification.requestPermission();
      } catch (e) {}
    },

    // Kick off subscription. Poll isDone(); when true, getResult() returns the
    // subscription JSON string (endpoint + keys) or null.
    startSubscribe: function (vapidPublicKey) {
      var self = this;
      self._done = false;
      self._result = null;
      (async function () {
        try {
          if (!self.isSupported() || !vapidPublicKey) return;
          if (Notification.permission !== 'granted') {
            var perm = await Notification.requestPermission();
            if (perm !== 'granted') return;
          }
          var reg = await navigator.serviceWorker.register(SW_PATH, { scope: SW_SCOPE });
          await waitForActive(reg);
          var sub = await reg.pushManager.getSubscription();
          if (!sub) {
            sub = await reg.pushManager.subscribe({
              userVisibleOnly: true,
              applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
            });
          }
          self._result = JSON.stringify(sub);
        } catch (e) {
          console.warn('euroPush subscribe failed:', e);
          self._result = null;
        } finally {
          self._done = true;
        }
      })();
    },

    isDone: function () { return this._done === true; },
    getResult: function () { return this._result; }
  };
})();
