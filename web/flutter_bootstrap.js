{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  onEntrypointLoaded: async function(engineInitializer) {
    // Pre-load Firebase JS SDK modules before Flutter starts.
    // This sets window.firebase_core / firebase_firestore / firebase_messaging
    // so that firebase_core_web's _initializeCore() finds them already set
    // and skips its own CDN dynamic import (which can race or fail).
    await Promise.all([
      import('https://www.gstatic.com/firebasejs/12.15.0/firebase-app.js')
        .then(function(m) { window.firebase_core = m; }),
      import('https://www.gstatic.com/firebasejs/12.15.0/firebase-firestore-pipelines.js')
        .then(function(m) { window.firebase_firestore = m; }),
      import('https://www.gstatic.com/firebasejs/12.15.0/firebase-messaging.js')
        .then(function(m) { window.firebase_messaging = m; }),
    ]);
    const appRunner = await engineInitializer.initializeEngine({});
    await appRunner.runApp();
  }
});
