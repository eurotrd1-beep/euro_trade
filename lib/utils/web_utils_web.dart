import 'dart:js' as js;

void openBrowserTab(String url) {
  try {
    js.context.callMethod('open', [url]);
  } catch (e) {
    print('Failed to open tab in web: $e');
  }
}

void evalJs(String code) {
  try {
    js.context.callMethod('eval', [code]);
  } catch (e) {
    print('Failed to evaluate JS in web: $e');
  }
}

void setUserBroker(String broker) {
  try {
    js.context.callMethod('setUserBroker', [broker]);
  } catch (_) {}
}
