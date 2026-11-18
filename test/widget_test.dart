import 'package:flutter_test/flutter_test.dart';

import 'package:slideshow/main.dart';

void main() {
  testWidgets('Slideshow app renders initial prompt', (WidgetTester tester) async {
    await tester.pumpWidget(const SlideshowApp());

    expect(find.text('フォルダーを選択してスライドショーを開始'), findsOneWidget);
  });
}
