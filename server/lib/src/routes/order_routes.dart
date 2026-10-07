import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../blinkpay_client.dart';
import '../config.dart';
import '../orders.dart';

/// Order-scoped routes: the app says what is in the cart and which consent
/// type the customer chose; this server sets the amount, the PCR and the
/// redirect URI, and only lets the app reach the consent and payments of an
/// order it created.
class OrderRoutes {
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final BlinkPayClient _client;
  final OrderStore _orders;
  final ServerConfig _config;
  final DateTime Function() _now;

  OrderRoutes(
    this._client,
    this._orders,
    this._config, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Registers the routes on [router], relative to its mount point (`/api/`).
  void addTo(Router router) {
    router.post('/orders', _createOrder);
    router.post('/orders/<orderId>/consent', _createConsent);
    router.get('/orders/<orderId>/consent', _getConsent);
    router.delete('/orders/<orderId>/consent', _revokeConsent);
    router.post('/orders/<orderId>/payments', _createPayment);
    router.get('/orders/<orderId>/payments/<paymentId>', _getPayment);
  }

  Future<Response> _createOrder(Request request) async {
    final body = await _readJson(request);
    final order = _orders.create(body?['quantity']);
    if (order == null) {
      return _error(
        400,
        'invalid_quantity',
        'quantity must be a whole number from 1 to ${OrderStore.maxQuantity}',
      );
    }
    return _json(201, {
      'order_id': order.id,
      'reference': order.reference,
      'amount': order.amount,
    });
  }

  Future<Response> _createConsent(Request request, String orderId) async {
    final order = _orders.find(orderId);
    if (order == null) return _orderNotFound();

    final key = request.headers['idempotency-key'];
    if (key == null || !_uuid.hasMatch(key)) return _missingIdempotencyKey();
    final type = (await _readJson(request))?['type'];
    if (type != 'single' && type != 'enduring') {
      return _error(400, 'invalid_type', 'type must be "single" or "enduring"');
    }

    // Nothing awaits from here until the upstream call is shared, so
    // concurrent requests for this order always see each other's claim.
    if ((order.consentIdempotencyKey ?? key) != key ||
        (order.consentType ?? type) != type) {
      return _error(
        409,
        'consent_exists',
        'This order already has a consent. Create a new order to start again.',
      );
    }
    if (order.consentId != null) return _consentCreated(order);

    order.consentType = type as String;
    order.consentIdempotencyKey = key;
    order.consentRequest ??= _consentRequest(order, type);
    // A retry or double tap while the first request is in flight waits for
    // that call instead of creating a second consent.
    final call = order.consentCall ??= _send(
      method: 'POST',
      path: '/payments/v1/${_consentPath(order)}',
      body: jsonEncode(order.consentRequest),
      idempotencyKey: key,
    );
    final response = await call;
    if (response == null || response.statusCode >= 300) {
      if (identical(order.consentCall, call)) order.consentCall = null;
      return response == null ? _proxyError() : _relay(response);
    }
    final json = _decode(response.body);
    order.consentId ??= json?['consent_id'] as String?;
    order.gatewayRedirectUri ??= json?['redirect_uri'] as String?;
    return _consentCreated(order);
  }

  Response _consentCreated(Order order) => _json(201, {
    'consent_id': order.consentId,
    'redirect_uri': order.gatewayRedirectUri,
  });

  Future<Response> _getConsent(Request request, String orderId) async {
    final order = _orders.find(orderId);
    if (order?.consentId == null) return _orderNotFound();
    return _forward(
      method: 'GET',
      path: '/payments/v1/${_consentPath(order!)}/${order.consentId}',
    );
  }

  Future<Response> _revokeConsent(Request request, String orderId) async {
    final order = _orders.find(orderId);
    if (order?.consentId == null) return _orderNotFound();
    return _forward(
      method: 'DELETE',
      path: '/payments/v1/${_consentPath(order!)}/${order.consentId}',
    );
  }

  Future<Response> _createPayment(Request request, String orderId) async {
    final order = _orders.find(orderId);
    if (order?.consentId == null) return _orderNotFound();

    final key = request.headers['idempotency-key'];
    if (key == null || !_uuid.hasMatch(key)) return _missingIdempotencyKey();

    // A single consent already fixes the amount and PCR; an enduring consent
    // only caps them, so each payment states its own.
    return _forward(
      method: 'POST',
      path: '/payments/v1/payments',
      body: {
        'consent_id': order!.consentId,
        if (order.consentType == 'enduring') ...{
          'amount': order.amount,
          'pcr': order.pcr,
        },
      },
      idempotencyKey: key,
    );
  }

  Future<Response> _getPayment(
    Request request,
    String orderId,
    String paymentId,
  ) async {
    final order = _orders.find(orderId);
    if (order?.consentId == null) return _orderNotFound();
    if (!_uuid.hasMatch(paymentId)) return _paymentNotFound();
    final response = await _send(
      method: 'GET',
      path: '/payments/v1/payments/$paymentId',
    );
    if (response == null) return _proxyError();
    if (response.statusCode == 200 &&
        _decode(response.body)?['detail']?['consent_id'] != order!.consentId) {
      return _paymentNotFound();
    }
    return _relay(response);
  }

  Map<String, dynamic> _consentRequest(Order order, String type) {
    final flow = {
      'detail': {'type': 'gateway', 'redirect_uri': _config.redirectUri},
    };
    if (type == 'single') {
      return {'flow': flow, 'pcr': order.pcr, 'amount': order.amount};
    }
    // AutoPay: the customer authorises up to this order's total per payment
    // and per fortnight, and the first payment is taken straight away.
    return {
      'flow': flow,
      'period': 'fortnightly',
      'from_timestamp': _now().toUtc().toIso8601String(),
      'maximum_amount_period': order.amount,
      'maximum_amount_payment': order.amount,
    };
  }

  String _consentPath(Order order) =>
      order.consentType == 'enduring' ? 'enduring-consents' : 'single-consents';

  /// Sends to Blink Payments and relays the response.
  Future<Response> _forward({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? idempotencyKey,
  }) async {
    final response = await _send(
      method: method,
      path: path,
      body: body == null ? null : jsonEncode(body),
      idempotencyKey: idempotencyKey,
    );
    return response == null ? _proxyError() : _relay(response);
  }

  Future<http.Response?> _send({
    required String method,
    required String path,
    String? body,
    String? idempotencyKey,
  }) async {
    try {
      return await _client.forward(
        method: method,
        path: path,
        body: body,
        idempotencyKey: idempotencyKey,
      );
    } catch (e) {
      print('[OrderRoutes] $method $path failed: $e');
      return null;
    }
  }

  /// Passes the status, body and `Retry-After` through, so the app can branch
  /// on the Blink Payments error code and honour rate limiting.
  Response _relay(http.Response response) {
    final retryAfter = response.headers['retry-after'];
    final hasBody = response.body.isNotEmpty;
    return Response(
      response.statusCode,
      body: hasBody ? response.body : null,
      headers: {
        if (hasBody) 'content-type': 'application/json',
        'retry-after': ?retryAfter,
      },
    );
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readJson(Request request) async =>
      _decode(await request.readAsString());

  Response _json(int status, Map<String, dynamic> body) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  Response _error(int status, String code, String message) =>
      _json(status, {'code': code, 'message': message});

  Response _orderNotFound() =>
      _error(404, 'order_not_found', 'No such order, or it has no consent yet');

  Response _paymentNotFound() =>
      _error(404, 'payment_not_found', 'No such payment on this order');

  Response _missingIdempotencyKey() => _error(
    400,
    'missing_idempotency_key',
    'Send a UUID idempotency-key header, and reuse it when retrying',
  );

  Response _proxyError() => _error(
    502,
    'proxy_error',
    'Could not reach Blink Payments. Please try again.',
  );
}
