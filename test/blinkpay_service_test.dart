import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:blinkpay_flutter_demo/blinkpay_service.dart';
import 'package:blinkpay_flutter_demo/models/payment_models.dart';

http.Response _json(
  int status,
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

http.Response _error(int status, String code, {Map<String, String>? headers}) =>
    _json(status, {
      'code': code,
      'message': 'irrelevant',
    }, headers: headers ?? const {});

void main() {
  late List<http.Request> requests;
  late List<Duration> sleeps;
  late List<http.Response Function()> responses;

  BlinkPayService service() => BlinkPayService(
    baseUrl: 'http://backend',
    apiKey: 'key',
    sleep: (d) async => sleeps.add(d),
    client: MockClient((request) async {
      requests.add(request);
      return responses.removeAt(0)();
    }),
  );

  setUp(() {
    requests = [];
    sleeps = [];
    responses = [];
  });

  group('idempotency key', () {
    test('a retried payment request reuses the same key', () async {
      responses = [
        () => _error(503, 'BP601'),
        () => _json(201, {'payment_id': 'p1'}),
      ];

      final id = await service().createPayment('o1', idempotencyKey: 'k-1');

      expect(id, 'p1');
      expect(requests.map((r) => r.headers['idempotency-key']), ['k-1', 'k-1']);
      expect(requests.first.url.path, '/api/orders/o1/payments');
    });

    test('a POST without a key is never retried', () async {
      responses = [() => _error(503, 'proxy_error')];

      await expectLater(
        service().createOrder(1),
        throwsA(isA<BlinkPayApiException>()),
      );
      expect(requests, hasLength(1));
      expect(sleeps, isEmpty);
    });
  });

  group('retry policy', () {
    test('5xx backs off 0.5 s then 1 s and gives up after 2 retries', () async {
      responses = [for (var i = 0; i < 3; i++) () => _error(503, 'BP601')];

      await expectLater(
        service().getConsent('o1'),
        throwsA(
          isA<BlinkPayApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.code, 'code', 'BP601'),
        ),
      );
      expect(requests, hasLength(3));
      expect(sleeps, [
        const Duration(milliseconds: 500),
        const Duration(seconds: 1),
      ]);
    });

    test('429 waits for Retry-After seconds', () async {
      responses = [
        () => _error(429, 'rate_limited', headers: {'retry-after': '2'}),
        () => _json(200, {'status': 'Authorised'}),
      ];

      final consent = await service().getConsent('o1');

      expect(consent['status'], 'Authorised');
      expect(sleeps, [const Duration(seconds: 2)]);
    });

    test('429 waits for a Retry-After HTTP date', () async {
      final at = DateTime.now().add(const Duration(seconds: 5));
      responses = [
        () => _error(
          429,
          'rate_limited',
          headers: {'retry-after': HttpDate.format(at)},
        ),
        () => _json(200, {'status': 'Authorised'}),
      ];

      await service().getConsent('o1');

      expect(sleeps.single.inSeconds, inInclusiveRange(3, 5));
    });

    test('429 without Retry-After backs off exponentially', () async {
      responses = [
        () => _error(429, 'rate_limited'),
        () => _json(200, {'status': 'Authorised'}),
      ];

      await service().getConsent('o1');

      expect(sleeps, [const Duration(milliseconds: 500)]);
    });

    test(
      '429 asking for longer than 10 s is reported, not waited out',
      () async {
        responses = [
          () => _error(429, 'rate_limited', headers: {'retry-after': '60'}),
        ];

        await expectLater(
          service().getConsent('o1'),
          throwsA(
            isA<BlinkPayApiException>().having(
              (e) => e.statusCode,
              'status',
              429,
            ),
          ),
        );
        expect(requests, hasLength(1));
      },
    );

    for (final status in [400, 401, 403, 404, 409, 422]) {
      test('$status is never retried', () async {
        responses = [() => _error(status, 'BP002')];

        await expectLater(
          service().createPayment('o1', idempotencyKey: 'k-1'),
          throwsA(
            isA<BlinkPayApiException>()
                .having((e) => e.statusCode, 'status', status)
                .having((e) => e.code, 'code', 'BP002'),
          ),
        );
        expect(requests, hasLength(1));
        expect(sleeps, isEmpty);
      });
    }

    test('network failures are retried and then reported as unknown', () async {
      final client = MockClient((request) async {
        requests.add(request);
        throw http.ClientException('connection reset');
      });
      final svc = BlinkPayService(
        baseUrl: 'http://backend',
        apiKey: 'key',
        client: client,
        sleep: (d) async => sleeps.add(d),
      );

      await expectLater(
        svc.createPayment('o1', idempotencyKey: 'k-1'),
        throwsA(isA<BlinkPayNetworkException>()),
      );
      expect(requests, hasLength(3));
      expect(requests.map((r) => r.headers['idempotency-key']).toSet(), {
        'k-1',
      });
    });
  });

  group('revokeConsent', () {
    Future<RevokeResult> revoke(http.Response response) {
      responses = [() => response];
      return service().revokeConsent('o1');
    }

    test('204 is revoked', () async {
      expect(await revoke(http.Response('', 204)), RevokeResult.revoked);
    });

    test('409 BP701 is already revoked', () async {
      expect(await revoke(_error(409, 'BP701')), RevokeResult.alreadyRevoked);
    });

    test('409 for a pending payment means the outcome must be read', () async {
      expect(await revoke(_error(409, 'BP703')), RevokeResult.outcomeExists);
    });

    test('422 means the consent already ended', () async {
      expect(await revoke(_error(422, 'BP011')), RevokeResult.outcomeExists);
    });

    test('anything else is an error', () async {
      await expectLater(
        revoke(_error(404, 'order_not_found')),
        throwsA(isA<BlinkPayApiException>()),
      );
    });
  });
}
