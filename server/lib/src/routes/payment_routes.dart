import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../blinkpay_client.dart';

/// Proxy routes for BlinkPay payment endpoints.
class PaymentRoutes {
  final BlinkPayClient _client;

  PaymentRoutes(this._client);

  /// Registers payment routes on the given [router].
  void addTo(Router router) {
    router.post('/payments', _createPayment);
  }

  Future<Response> _createPayment(Request request) async {
    try {
      final body = await request.readAsString();
      final blinkPayResponse = await _client.forward(
        method: 'POST',
        path: '/payments/v1/payments',
        body: body,
      );
      return Response(
        blinkPayResponse.statusCode,
        body: blinkPayResponse.body,
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      print('[PaymentRoutes] Error proxying POST /payments: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'proxy_error', 'message': 'An internal error occurred. Please try again.'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }
}
