import 'package:flutter/material.dart';

import '../managers/payment_manager.dart';

/// Shows where the payment is, with Cancel while the customer has not yet
/// approved it and OK once the app has stopped checking.
class PaymentStatusPanel extends StatelessWidget {
  final PaymentState state;
  final String? message;
  final bool canCancel;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  const PaymentStatusPanel({
    super.key,
    required this.state,
    required this.message,
    required this.canCancel,
    required this.onCancel,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final text = message;
    if (state == PaymentState.idle ||
        state == PaymentState.starting ||
        text == null) {
      return const SizedBox.shrink();
    }
    final checking =
        state == PaymentState.awaitingAuthorisation ||
        state == PaymentState.paymentProcessing;

    return Card(
      color: _colour(state),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (checking) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Text(text, textAlign: TextAlign.center),
            if (canCancel)
              TextButton(
                onPressed: onCancel,
                child: const Text('Cancel payment'),
              ),
            if (!checking)
              TextButton(onPressed: onDismiss, child: const Text('OK')),
          ],
        ),
      ),
    );
  }

  Color _colour(PaymentState state) {
    switch (state) {
      case PaymentState.succeeded:
        return Colors.green.shade800;
      case PaymentState.failed:
        return Colors.red.shade900;
      default:
        return const Color(0xFF233994);
    }
  }
}
