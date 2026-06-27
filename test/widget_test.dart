import 'package:flutter_test/flutter_test.dart';
import 'package:euro_trade/main.dart';

void main() {
  testWidgets('Euro Trade App Smoke Test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const EuroTradeApp());

    // Verify that the app mounts successfully
    expect(find.byType(EuroTradeApp), findsOneWidget);
  });
}
