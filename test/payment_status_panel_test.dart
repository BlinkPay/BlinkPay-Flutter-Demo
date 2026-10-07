import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blinkpay_flutter_demo/managers/payment_manager.dart';
import 'package:blinkpay_flutter_demo/widgets/payment_status_panel.dart';

void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    required PaymentState state,
    String? message = 'message',
    bool canCancel = false,
    VoidCallback? onCancel,
    VoidCallback? onDismiss,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PaymentStatusPanel(
          state: state,
          message: message,
          canCancel: canCancel,
          onCancel: onCancel ?? () {},
          onDismiss: onDismiss ?? () {},
        ),
      ),
    ),
  );

  testWidgets('shows nothing when idle', (tester) async {
    await pumpPanel(tester, state: PaymentState.idle);

    expect(find.text('message'), findsNothing);
  });

  testWidgets('offers Cancel while waiting for the bank', (tester) async {
    var cancelled = false;
    await pumpPanel(
      tester,
      state: PaymentState.awaitingAuthorisation,
      canCancel: true,
      onCancel: () => cancelled = true,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    await tester.tap(find.text('Cancel payment'));
    expect(cancelled, isTrue);
  });

  testWidgets('an unresolved payment is acknowledged, not retried', (
    tester,
  ) async {
    var dismissed = false;
    await pumpPanel(
      tester,
      state: PaymentState.unresolved,
      message: 'Your bank is still processing the payment.',
      onDismiss: () => dismissed = true,
    );

    expect(
      find.text('Your bank is still processing the payment.'),
      findsOneWidget,
    );
    expect(find.text('Cancel payment'), findsNothing);
    await tester.tap(find.text('OK'));
    expect(dismissed, isTrue);
  });
}
