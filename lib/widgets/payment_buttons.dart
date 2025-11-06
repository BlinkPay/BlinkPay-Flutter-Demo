import 'package:flutter/material.dart';

/// Displays the PayNow and AutoPay buttons.
class PaymentButtons extends StatelessWidget {
  final bool isDisabled;
  final Function(String type) onButtonClick;

  const PaymentButtons({
    super.key,
    required this.isDisabled,
    required this.onButtonClick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: [
        // PayNow button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            textStyle: const TextStyle(fontSize: 14),
          ),
          onPressed: isDisabled ? null : () => onButtonClick('single'),
          icon: const Icon(Icons.shopping_cart),
          label: const Text('PayNow'),
        ),

        // AutoPay button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            textStyle: const TextStyle(fontSize: 14),
          ),
          onPressed: isDisabled ? null : () => onButtonClick('enduring'),
          icon: const Icon(Icons.shopping_cart),
          label: const Text('AutoPay'),
        ),
      ],
    );
  }
}
