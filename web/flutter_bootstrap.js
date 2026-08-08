{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  onEntrypointLoaded: async function(engineInitializer) {
    // Firebase is fully removed from this app — do NOT gate engine startup behind
    // external gstatic imports (a slow/blocked/404 import there = permanent blank
    // page). Start the engine directly.
    const appRunner = await engineInitializer.initializeEngine({});
    await appRunner.runApp();
  }
});
