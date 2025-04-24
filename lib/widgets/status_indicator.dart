import 'package:flutter/material.dart';
import '../managers/payment_manager.dart'; // For PaymentState enum

/// A widget to display the current payment status as an icon in the AppBar.
class StatusIndicator extends StatelessWidget {
  final PaymentState state;

  const StatusIndicator({required this.state, super.key});

  @override
  Widget build(BuildContext context) {
    Widget icon;
    String semanticLabel;

    switch (state) {
      case PaymentState.creatingConsent:
      case PaymentState.awaitingRedirect:
      case PaymentState.verifying:
        icon = const Icon(Icons.hourglass_empty, color: Colors.yellow);
        semanticLabel = 'Payment Processing';
        break;
      case PaymentState.idle:
      // Fallthrough intended for default case
      default: // Handles idle and any potential future states gracefully
        icon = const Icon(Icons.payment, color: Colors.white);
        semanticLabel = 'Payment Idle';
        break;
      // Removed PaymentState.error case
    }

    // Add padding for visual spacing in the AppBar
    return Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: Tooltip(
        // Add tooltip for accessibility
        message: semanticLabel,
        child: icon,
      ),
    );
  }
}
