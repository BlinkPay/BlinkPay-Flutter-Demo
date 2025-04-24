import 'dart:math';
import 'package:flutter/material.dart';
import '../env.dart'; // Corrected import path for env.dart

/// Manages the state and logic for the shopping cart.
class ShoppingCartModel extends ChangeNotifier {
  int _quantity = 1;
  bool _imageLoaded = false;
  final double _unitPrice = double.tryParse(Environment.unitPrice) ?? 1.00;
  final TextEditingController _quantityController =
      TextEditingController(text: '1');

  int get quantity => _quantity;
  bool get imageLoaded => _imageLoaded;
  double get unitPrice => _unitPrice;
  TextEditingController get quantityController => _quantityController;
  double get total => _calculateTotal();

  ShoppingCartModel();

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  void setImageLoaded(bool loaded) {
    if (_imageLoaded != loaded) {
      _imageLoaded = loaded;
      notifyListeners();
    }
  }

  /// Calculates total cost
  double _calculateTotal() {
    return _unitPrice * _quantity;
  }

  /// Changes the quantity, ensuring a minimum of 1
  void changeQuantity(int change) {
    int currentVal = int.tryParse(_quantityController.text) ?? _quantity;
    int newValue = max(1, currentVal + change); // Ensure quantity is at least 1
    _quantity = newValue;
    _quantityController.text = _quantity.toString();
    // Move cursor to end after setting text programmatically
    _quantityController.selection = TextSelection.fromPosition(
        TextPosition(offset: _quantityController.text.length));
    notifyListeners(); // Notify UI about the change
  }

  /// Updates quantity based on text field input
  void updateQuantityFromTextField() {
    int? parsedValue = int.tryParse(_quantityController.text);
    if (parsedValue != null && parsedValue >= 1) {
      if (_quantity != parsedValue) {
        _quantity = parsedValue;
        notifyListeners();
      }
    } else {
      // Handle invalid input - maybe revert or show error? For now, just ignore.
      // Or reset to the last valid quantity:
      // _quantityController.text = _quantity.toString();
    }
  }

  /// Resets the quantity to 1
  void reset() {
    _quantity = 1;
    _quantityController.text = '1';
    notifyListeners();
  }
}
