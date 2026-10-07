import 'dart:async';
import 'dart:convert';

import 'package:blinkpay_proxy_server/src/blinkpay_client.dart';
import 'package:blinkpay_proxy_server/src/config.dart';
import 'package:blinkpay_proxy_server/src/orders.dart';
import 'package:blinkpay_proxy_server/src/routes/order_routes.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

const _key1 = '11111111-1111-4111-8111-111111111111';
const _key2 = '22222222-2222-4222-8222-222222222222';

/// Records what the routes send to Blink Payments and answers from a script.
class FakeBlinkPay {
  final List<http.Request> calls = [];
  http.Response Function(http.Request request)? respond;
  Completer<void>? hold;

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path == '/oauth2/token') {
      return http.Response(
        jsonEncode({'access_token': 't', 'expires_in': 3600}),
        200,
      );
    }
    calls.add(request);
    await hold?.future;
    final scripted = respond?.call(request);
    if (scripted != null) return scripted;
    if (request.url.path.endsWith('-consents')) {
      final id = 'c${calls.length}';
      return http.Response(
        jsonEncode({'consent_id': id, 'redirect_uri': 'https://gw/$id'}),
        201,
      );
    }
    return http.Response(jsonEncode({'payment_id': 'p1'}), 201);
  }

  Map<String, dynamic> body(int i) =>
      jsonDecode(calls[i].body) as Map<String, dynamic>;
}

void main() {
  late FakeBlinkPay blinkPay;
  late Handler handler;

  setUp(() {
    blinkPay = FakeBlinkPay();
    final config = ServerConfig(
      blinkPayApiUrl: 'blinkpay.test',
      clientId: 'id',
      clientSecret: 'secret',
      appApiKey: 'app-key',
      unitPrice: '0.50',
      redirectUri: 'demo://callback',
    );
    final router = Router();
    OrderRoutes(
      BlinkPayClient(config: config, httpClient: MockClient(blinkPay.handle)),
      OrderStore(unitPriceCents: Money.tryParseCents(config.unitPrice)!),
      config,
      now: () => DateTime.utc(2026, 10, 7, 2),
    ).addTo(router);
    handler = router.call;
  });

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, {
    Object? body,
    String? key,
  }) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://server$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'idempotency-key': ?key},
      ),
    );
    final text = await response.readAsString();
    return (
      response.statusCode,
      text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<String> createOrder(int quantity) async {
    final (status, json) = await call(
      'POST',
      '/orders',
      body: {'quantity': quantity},
    );
    expect(status, 201);
    return json['order_id'] as String;
  }

  group('orders', () {
    test('the server prices the order and ignores a client amount', () async {
      final (status, json) = await call(
        'POST',
        '/orders',
        body: {
          'quantity': 3,
          'amount': {'total': '0.01'},
        },
      );

      expect(status, 201);
      expect(json['amount'], {'total': '1.50', 'currency': 'NZD'});
      expect(json['reference'], matches(RegExp(r'^ORD-[0-9a-f]{8}$')));
    });

    for (final quantity in [0, -1, 100, 2.5, '3', null]) {
      test('rejects quantity $quantity', () async {
        final (status, json) = await call(
          'POST',
          '/orders',
          body: {'quantity': quantity},
        );
        expect(status, 400);
        expect(json['code'], 'invalid_quantity');
      });
    }
  });

  group('consent', () {
    test('the server builds the body: amount, PCR and redirect URI', () async {
      final orderId = await createOrder(3);

      final (status, json) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {
          'type': 'single',
          'amount': {'total': '0.01', 'currency': 'NZD'},
          'pcr': {'particulars': 'HACK'},
          'flow': {
            'detail': {'type': 'gateway', 'redirect_uri': 'https://evil/'},
          },
        },
      );

      expect(status, 201);
      expect(json, {'consent_id': 'c1', 'redirect_uri': 'https://gw/c1'});
      final sent = blinkPay.body(0);
      expect(blinkPay.calls.single.url.path, '/payments/v1/single-consents');
      expect(blinkPay.calls.single.headers['idempotency-key'], _key1);
      expect(sent['amount'], {'total': '1.50', 'currency': 'NZD'});
      expect(sent['pcr']['particulars'], 'Lollipops');
      expect(sent['pcr']['code'], 'DEMO');
      expect(sent['pcr']['reference'], startsWith('ORD-'));
      for (final value in (sent['pcr'] as Map).values) {
        expect((value as String).length, lessThanOrEqualTo(12));
      }
      expect(sent['flow'], {
        'detail': {'type': 'gateway', 'redirect_uri': 'demo://callback'},
      });
    });

    test('an enduring consent is capped at the order total', () async {
      final orderId = await createOrder(2);

      await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': 'enduring'},
      );

      final sent = blinkPay.body(0);
      expect(blinkPay.calls.single.url.path, '/payments/v1/enduring-consents');
      expect(sent['maximum_amount_payment'], {
        'total': '1.00',
        'currency': 'NZD',
      });
      expect(sent['maximum_amount_period'], {
        'total': '1.00',
        'currency': 'NZD',
      });
      expect(sent['period'], 'fortnightly');
      expect(sent['from_timestamp'], '2026-10-07T02:00:00.000Z');
    });

    test('needs a UUID idempotency key', () async {
      final orderId = await createOrder(1);

      for (final key in [null, 'abc']) {
        final (status, json) = await call(
          'POST',
          '/orders/$orderId/consent',
          key: key,
          body: {'type': 'single'},
        );
        expect(status, 400);
        expect(json['code'], 'missing_idempotency_key');
      }
      expect(blinkPay.calls, isEmpty);
    });

    test('a retry with the same key returns the same consent', () async {
      final orderId = await createOrder(1);

      final (_, first) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': 'single'},
      );
      final (status, again) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': 'single'},
      );

      expect(status, 201);
      expect(again, first);
      expect(blinkPay.calls, hasLength(1));
    });

    test('concurrent requests with the same key share one consent', () async {
      final orderId = await createOrder(1);
      blinkPay.hold = Completer<void>();

      final requests = [
        for (var i = 0; i < 3; i++)
          call(
            'POST',
            '/orders/$orderId/consent',
            key: _key1,
            body: {'type': 'single'},
          ),
      ];
      while (blinkPay.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      blinkPay.hold!.complete();
      final results = await Future.wait(requests);

      expect(results.map((r) => r.$2['consent_id']).toSet(), {'c1'});
      expect(blinkPay.calls, hasLength(1));
    });

    test('a different key on the same order is refused', () async {
      final orderId = await createOrder(1);
      await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': 'single'},
      );

      final (status, json) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key2,
        body: {'type': 'single'},
      );

      expect(status, 409);
      expect(json['code'], 'consent_exists');
    });

    test('a plain 4xx from Blink Payments lets the order try again', () async {
      final orderId = await createOrder(1);
      blinkPay.respond = (_) => http.Response(
        jsonEncode({'code': 'BP214', 'message': 'not whitelisted'}),
        400,
      );

      final (status, json) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': 'single'},
      );
      expect(status, 400);
      expect(json['code'], 'BP214');

      blinkPay.respond = null;
      final (retry, _) = await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key2,
        body: {'type': 'single'},
      );
      expect(retry, 201);
    });

    test('relays Retry-After on a 429', () async {
      final orderId = await createOrder(1);
      blinkPay.respond = (_) => http.Response(
        jsonEncode({'code': 'rate_limited'}),
        429,
        headers: {'retry-after': '7'},
      );

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://server/orders/$orderId/consent'),
          body: jsonEncode({'type': 'single'}),
          headers: {'idempotency-key': _key1},
        ),
      );

      expect(response.statusCode, 429);
      expect(response.headers['retry-after'], '7');
    });
  });

  group('payments', () {
    Future<String> orderWithConsent(String type) async {
      final orderId = await createOrder(2);
      await call(
        'POST',
        '/orders/$orderId/consent',
        key: _key1,
        body: {'type': type},
      );
      blinkPay.calls.clear();
      return orderId;
    }

    test(
      'forwards the idempotency key and sends only the consent for single',
      () async {
        final orderId = await orderWithConsent('single');

        final (status, json) = await call(
          'POST',
          '/orders/$orderId/payments',
          key: _key2,
          body: {
            'amount': {'total': '0.01'},
          },
        );

        expect(status, 201);
        expect(json['payment_id'], 'p1');
        expect(blinkPay.calls.single.headers['idempotency-key'], _key2);
        expect(blinkPay.body(0), {'consent_id': 'c1'});
      },
    );

    test('states the server amount and PCR for an enduring payment', () async {
      final orderId = await orderWithConsent('enduring');

      await call('POST', '/orders/$orderId/payments', key: _key2);

      final sent = blinkPay.body(0);
      expect(sent['amount'], {'total': '1.00', 'currency': 'NZD'});
      expect(sent['pcr']['particulars'], 'Lollipops');
    });

    test('needs an idempotency key', () async {
      final orderId = await orderWithConsent('single');

      final (status, _) = await call('POST', '/orders/$orderId/payments');

      expect(status, 400);
      expect(blinkPay.calls, isEmpty);
    });

    test('only returns a payment made with the order\'s consent', () async {
      final orderId = await orderWithConsent('single');
      const paymentId = '33333333-3333-4333-8333-333333333333';
      String consentOfPayment = 'c1';
      blinkPay.respond = (_) => http.Response(
        jsonEncode({
          'payment_id': paymentId,
          'status': 'Pending',
          'detail': {'consent_id': consentOfPayment},
        }),
        200,
      );

      final (mine, _) = await call(
        'GET',
        '/orders/$orderId/payments/$paymentId',
      );
      consentOfPayment = 'someone-elses-consent';
      final (theirs, json) = await call(
        'GET',
        '/orders/$orderId/payments/$paymentId',
      );

      expect(mine, 200);
      expect(theirs, 404);
      expect(json['code'], 'payment_not_found');
    });

    test('an unknown order is not found', () async {
      final (status, json) = await call(
        'POST',
        '/orders/44444444-4444-4444-8444-444444444444/payments',
        key: _key1,
      );

      expect(status, 404);
      expect(json['code'], 'order_not_found');
    });
  });

  group('Money', () {
    test('parses amounts into whole cents', () {
      expect(Money.tryParseCents('1'), 100);
      expect(Money.tryParseCents('1.5'), 150);
      expect(Money.tryParseCents('1.05'), 105);
      expect(Money.tryParseCents('0.10'), 10);
    });

    test('rejects anything that is not a plain amount', () {
      for (final value in ['', '-1', '1.005', '1,00', 'abc', '1.']) {
        expect(Money.tryParseCents(value), isNull, reason: value);
      }
    });

    test('formats cents', () {
      expect(Money.format(150), '1.50');
      expect(Money.format(5), '0.05');
      expect(Money.format(10000), '100.00');
    });
  });
}
