import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';

void main() {
  testWidgets('Shows disconnected UI on launch', (tester) async {
    await tester.pumpWidget(const BreakthroughApp());

    expect(find.text('Breakthrough'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
  });
}