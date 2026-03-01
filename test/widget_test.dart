import 'package:flutter_test/flutter_test.dart';
import 'package:beconnect/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const BeConnectApp());
    expect(find.text('BeConnect'), findsAny);
  });
}
