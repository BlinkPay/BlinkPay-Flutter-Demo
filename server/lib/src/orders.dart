import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'config.dart';

/// A customer's order. The server decides what it costs and how it appears on
/// bank statements; the app only says what is in the cart.
class Order {
  final String id;

  /// Opaque, statement-safe identifier used as the PCR reference.
  final String reference;
  final int quantity;
  final int totalCents;

  /// `single` or `enduring`.
  String? consentType;

  /// The consent request is built once and stored with its idempotency key,
  /// so a retry sends an identical payload and Blink Payments replays the
  /// original response instead of rejecting the key (BP702).
  String? consentIdempotencyKey;
  Map<String, dynamic>? consentRequest;
  Future<http.Response?>? consentCall;
  String? consentId;
  String? gatewayRedirectUri;

  Order({
    required this.id,
    required this.reference,
    required this.quantity,
    required this.totalCents,
  });

  String get total => Money.format(totalCents);

  /// Particulars, code and reference: at most 12 characters each, and never
  /// customer personal data, because they appear on both bank statements.
  Map<String, String> get pcr => {
    'particulars': 'Lollipops',
    'code': 'DEMO',
    'reference': reference,
  };

  Map<String, String> get amount => {'total': total, 'currency': 'NZD'};
}

/// In-memory order store.
///
/// DEMO ONLY: orders are lost on restart. A real backend keeps orders, consent
/// IDs and payment IDs in its database so it can finish tracking a payment
/// after the app has gone away.
class OrderStore {
  static const int maxQuantity = 99;

  final int unitPriceCents;
  final Map<String, Order> _orders = {};

  OrderStore({required this.unitPriceCents});

  /// Prices and stores a new order, or returns null if [quantity] is invalid.
  Order? create(Object? quantity) {
    if (quantity is! int || quantity < 1 || quantity > maxQuantity) {
      return null;
    }
    final id = const Uuid().v4();
    final order = Order(
      id: id,
      reference: 'ORD-${id.substring(0, 8)}',
      quantity: quantity,
      totalCents: unitPriceCents * quantity,
    );
    _orders[id] = order;
    return order;
  }

  Order? find(String id) => _orders[id];
}
