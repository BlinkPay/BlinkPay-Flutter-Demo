import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/shopping_cart_model.dart';
import '../constants.dart';

/// Displays the product details and quantity controls.
class ProductCard extends StatelessWidget {
  final ShoppingCartModel cartModel;

  const ProductCard({super.key, required this.cartModel});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Product image and details row
            Row(
              children: [
                // Product image container
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[200],
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: cartModel.imageLoaded
                      ? Image.asset(
                          'assets/lolly.webp',
                          fit: BoxFit.cover,
                        )
                      : const Center(
                          child: CircularProgressIndicator(),
                        ),
                ),
                const SizedBox(width: 16),

                // Product details column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        AppConstants.productName + ', unwrapped',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.black),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '\$${cartModel.unitPrice.toStringAsFixed(2)} each',
                        style: const TextStyle(
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Quantity controls row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 60,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    controller: cartModel.quantityController,
                    style: const TextStyle(color: Colors.black),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (value) {
                      cartModel.updateQuantityFromTextField();
                    },
                  ),
                ),
                IconButton(
                  onPressed: () => cartModel.changeQuantity(-1),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  onPressed: () => cartModel.changeQuantity(1),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Total display text
            Text(
              'Total: \$${cartModel.total.toStringAsFixed(2)}',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black),
            ),
          ],
        ),
      ),
    );
  }
}
