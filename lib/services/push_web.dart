// Web implementation: bridges to window.euroPush (see web/push/push_client.js)
// via dart:js interop. JS Promises are turned into Dart Futures with a Completer
// (keeps this file dependency-free / consistent with the rest of the project).
import 'dart:async';
import 'dart:js' as js;

js.JsObject? get _ep {
  try {
    return js.context['euroPush'] as js.JsObject?;
  } catch (_) {
    return null;
  }
}

Future<dynamic> _promiseToFuture(dynamic promise) {
  final completer = Completer<dynamic>();
  try {
    final p = promise as js.JsObject;
    p.callMethod('then', [
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      }
    ]);
    p.callMethod('catch', [
      (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
    ]);
  } catch (_) {
    if (!completer.isCompleted) completer.complete(null);
  }
  return completer.future;
}

bool isSupported() {
  try {
    final ep = _ep;
    if (ep == null) return false;
    return ep.callMethod('isSupported', const []) == true;
  } catch (_) {
    return false;
  }
}

Future<String> requestPermission() async {
  try {
    final ep = _ep;
    if (ep == null) return 'denied';
    final result = await _promiseToFuture(ep.callMethod('requestPermission', const []));
    return (result as String?) ?? 'denied';
  } catch (_) {
    return 'denied';
  }
}

Future<String?> subscribe(String vapidPublicKey) async {
  try {
    final ep = _ep;
    if (ep == null) return null;
    final result = await _promiseToFuture(ep.callMethod('subscribe', [vapidPublicKey]));
    return result as String?;
  } catch (_) {
    return null;
  }
}

String appUrl() {
  try {
    final ep = _ep;
    if (ep == null) return '';
    return (ep.callMethod('appUrl', const []) as String?) ?? '';
  } catch (_) {
    return '';
  }
}
