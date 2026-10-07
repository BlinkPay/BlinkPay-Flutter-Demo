import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:blinkpay_flutter_demo/blinkpay_service.dart';
import 'package:blinkpay_flutter_demo/managers/payment_manager.dart';
import 'package:blinkpay_flutter_demo/models/payment_models.dart';
import 'package:blinkpay_flutter_demo/models/shopping_cart_model.dart';
import 'package:blinkpay_flutter_demo/utils/payment_error_helper.dart';

/// A scripted backend. Statuses are functions of the fake clock, so a test
/// can say "awaiting authorisation for 5 minutes, then authorised".
class FakeBackend {
  final DateTime start = DateTime(2026, 1, 1, 12);
  late DateTime now = start;

  String Function(Duration elapsed) consentStatus = (_) =>
      'AwaitingAuthorisation';
  List<Map<String, dynamic>> consentPayments = [];
  String Function(Duration sincePayment) paymentStatus = (_) =>
      'AcceptedSettlementCompleted';
  List<http.Response Function()> paymentCreates = [];
  http.Response Function() revoke = () => http.Response('', 204);

  final List<http.Request> requests = [];
  final List<Duration> sleeps = [];
  DateTime? paymentCreatedAt;
  int consentCount = 0;

  Duration get elapsed => now.difference(start);

  Iterable<http.Request> where(String method, String pathEnd) =>
      requests.where((r) => r.method == method && r.url.path.endsWith(pathEnd));

  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    now = now.add(d);
  }

  http.Response _json(int status, Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), status);

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    if (r.method == 'POST' && path == '/api/orders') {
      consentCount++;
      return _json(201, {
        'order_id': 'o$consentCount',
        'amount': {'total': '2.00', 'currency': 'NZD'},
      });
    }
    if (path.endsWith('/consent')) {
      switch (r.method) {
        case 'POST':
          return _json(201, {
            'consent_id': 'c$consentCount',
            'redirect_uri': 'https://gateway/pay?id=c$consentCount',
          });
        case 'GET':
          return _json(200, {
            'status': consentStatus(elapsed),
            'payments': consentPayments,
          });
        case 'DELETE':
          return revoke();
      }
    }
    if (r.method == 'POST' && path.endsWith('/payments')) {
      final response = paymentCreates.isEmpty
          ? _json(201, {'payment_id': 'p1'})
          : paymentCreates.removeAt(0)();
      if (response.statusCode == 201) paymentCreatedAt ??= now;
      return response;
    }
    if (r.method == 'GET' && path.contains('/payments/')) {
      return _json(200, {
        'status': paymentStatus(now.difference(paymentCreatedAt ?? now)),
      });
    }
    return http.Response('not scripted: ${r.method} $path', 500);
  }
}

void main() {
  late FakeBackend backend;
  late PaymentManager manager;
  late List<PaymentState> states;
  var keys = 0;

  setUp(() {
    backend = FakeBackend();
    keys = 0;
    manager = PaymentManager(
      blinkPayService: BlinkPayService(
        baseUrl: 'http://backend',
        apiKey: 'key',
        client: MockClient(backend.handle),
        sleep: backend.sleep,
      ),
      cartModel: ShoppingCartModel(),
      sleep: backend.sleep,
      clock: () => backend.now,
      newIdempotencyKey: () => 'key-${++keys}',
    );
    states = [];
    manager.addListener(() {
      if (states.isEmpty || states.last != manager.state) {
        states.add(manager.state);
      }
    });
  });

  Future<void> settle() async {
    for (var i = 0; i < 100000 && manager.isBusy; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> run(ConsentType type) async {
    expect(await manager.start(type), startsWith('https://gateway/'));
    manager.onBrowserOpened();
    await settle();
  }

  group('waiting for the customer', () {
    test(
      'a consent awaiting authorisation on return is never revoked or failed',
      () async {
        backend.consentStatus = (t) => t < const Duration(minutes: 3)
            ? ConsentStatus.awaitingAuthorisation
            : ConsentStatus.authorised;

        expect(await manager.start(ConsentType.single), isNotNull);
        manager.onBrowserOpened();
        manager.onReturnFromBank(consentId: 'c1');
        manager.onAppResumed();
        await settle();

        expect(backend.where('DELETE', '/consent'), isEmpty);
        expect(states, isNot(contains(PaymentState.failed)));
        expect(manager.state, PaymentState.succeeded);
        expect(backend.where('POST', '/payments'), hasLength(1));
        // About 60 checks over the 3 minutes, never more than one per 3 s.
        expect(
          backend.where('GET', '/consent').length,
          inInclusiveRange(60, 62),
        );
      },
    );

    test('consent polling waits 3 s between checks', () async {
      backend.consentStatus = (t) => t < const Duration(seconds: 30)
          ? ConsentStatus.gatewayAwaitingSubmission
          : ConsentStatus.authorised;

      await run(ConsentType.single);

      final consentSleeps = backend.sleeps.takeWhile((d) => d.inSeconds < 30);
      expect(consentSleeps, isNotEmpty);
      expect(consentSleeps.toSet(), {const Duration(seconds: 3)});
    });

    test('a consent that never resolves ends unresolved, not failed', () async {
      backend.consentStatus = (_) => ConsentStatus.gatewayAwaitingSubmission;

      await run(ConsentType.single);

      expect(manager.state, PaymentState.unresolved);
      expect(manager.message, contains("haven't heard back"));
      expect(backend.where('DELETE', '/consent'), isEmpty);
      expect(backend.where('POST', '/payments'), isEmpty);
      expect(
        backend.elapsed,
        greaterThanOrEqualTo(const Duration(minutes: 15)),
      );
      expect(
        backend.elapsed,
        lessThan(const Duration(minutes: 15, seconds: 4)),
      );
    });

    test(
      'reaching the bank late extends the wait by the bank window',
      () async {
        backend.consentStatus = (t) => t < const Duration(minutes: 12)
            ? ConsentStatus.gatewayAwaitingSubmission
            : ConsentStatus.awaitingAuthorisation;

        await run(ConsentType.single);

        expect(manager.state, PaymentState.unresolved);
        expect(
          backend.elapsed,
          greaterThanOrEqualTo(const Duration(minutes: 22)),
        );
        expect(
          backend.elapsed,
          lessThan(const Duration(minutes: 22, seconds: 4)),
        );
      },
    );

    test(
      'resuming after giving up checks again and can still complete',
      () async {
        var approved = false;
        backend.consentStatus = (_) => approved
            ? ConsentStatus.authorised
            : ConsentStatus.awaitingAuthorisation;
        await run(ConsentType.single);
        expect(manager.state, PaymentState.unresolved);

        approved = true;
        manager.onAppResumed();
        await settle();

        expect(manager.state, PaymentState.succeeded);
        expect(backend.where('DELETE', '/consent'), isEmpty);
      },
    );

    test('a return link for another consent is ignored', () async {
      backend.consentStatus = (_) => ConsentStatus.rejected;
      expect(await manager.start(ConsentType.single), isNotNull);

      manager.onReturnFromBank(consentId: 'someone-else');
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(backend.where('GET', '/consent'), isEmpty);
      expect(manager.state, PaymentState.awaitingAuthorisation);
    });
  });

  group('terminal consent statuses', () {
    for (final status in [
      ConsentStatus.rejected,
      ConsentStatus.gatewayTimeout,
      ConsentStatus.revoked,
    ]) {
      test(
        '$status fails with its own message and creates no payment',
        () async {
          backend.consentStatus = (_) => status;

          await run(ConsentType.single);

          expect(manager.state, PaymentState.failed);
          expect(manager.message, PaymentErrorHelper.forConsentStatus(status));
          expect(backend.where('POST', '/payments'), isEmpty);
          expect(backend.where('DELETE', '/consent'), isEmpty);
        },
      );
    }
  });

  group('payment outcome', () {
    setUp(() => backend.consentStatus = (_) => ConsentStatus.authorised);

    test('polls the payment every 30 s until it settles', () async {
      backend.paymentStatus = (t) => t < const Duration(seconds: 70)
          ? PaymentStatus.inProcess
          : PaymentStatus.completed;

      await run(ConsentType.single);

      expect(manager.state, PaymentState.succeeded);
      expect(manager.message, 'Payment of \$2.00 completed.');
      expect(backend.where('GET', '/payments/p1'), hasLength(3));
      expect(backend.sleeps, everyElement(const Duration(seconds: 30)));
    });

    test(
      'a payment still in flight after 2 minutes is unresolved, not failed',
      () async {
        backend.paymentStatus = (t) => t < const Duration(seconds: 15)
            ? PaymentStatus.pending
            : PaymentStatus.inProcess;

        await run(ConsentType.single);

        expect(manager.state, PaymentState.unresolved);
        expect(manager.message, contains('still processing'));
        expect(backend.where('GET', '/payments/p1'), hasLength(4));
        expect(backend.where('DELETE', '/consent'), isEmpty);
        expect(states, isNot(contains(PaymentState.failed)));
      },
    );

    test('a rejected payment fails', () async {
      backend.paymentStatus = (_) => PaymentStatus.rejected;

      await run(ConsentType.single);

      expect(manager.state, PaymentState.failed);
      expect(manager.message, PaymentErrorHelper.bankDeclined);
    });

    test('only AcceptedSettlementCompleted counts as paid', () async {
      backend.paymentStatus = (_) => PaymentStatus.inProcess;

      await run(ConsentType.single);

      expect(states, isNot(contains(PaymentState.succeeded)));
    });
  });

  group('payment idempotency', () {
    setUp(() => backend.consentStatus = (_) => ConsentStatus.authorised);

    test(
      'a create with no response is retried later under the same key',
      () async {
        http.Response reset() => throw http.ClientException('connection reset');
        backend.paymentCreates = [reset, reset, reset];

        await run(ConsentType.single);

        final creates = backend.where('POST', '/payments').toList();
        expect(creates, hasLength(4));
        expect(creates.map((r) => r.headers['idempotency-key']).toSet(), {
          'key-2',
        });
        expect(manager.state, PaymentState.succeeded);
      },
    );

    test('each payment attempt gets its own key', () async {
      await run(ConsentType.single);
      manager.dismiss();
      await run(ConsentType.single);

      final keysSent = backend
          .where('POST', '/payments')
          .map((r) => r.headers['idempotency-key'])
          .toList();
      expect(keysSent, hasLength(2));
      expect(keysSent.toSet(), hasLength(2));
    });

    test(
      'an enduring consent that stays Authorised yields its existing payment',
      () async {
        backend.paymentCreates = [
          () => http.Response(jsonEncode({'code': 'BP703'}), 409),
        ];
        var gets = 0;
        backend.consentStatus = (_) {
          if (++gets > 1) {
            backend.consentPayments = [
              {'payment_id': 'p1', 'status': 'Pending'},
            ];
            backend.paymentCreatedAt ??= backend.now;
          }
          return ConsentStatus.authorised;
        };

        await run(ConsentType.enduring);

        expect(backend.where('POST', '/payments'), hasLength(1));
        expect(manager.state, PaymentState.succeeded);
      },
    );

    test('prefers the live payment over a rejected row listed first', () async {
      backend.consentStatus = (_) => ConsentStatus.consumed;
      backend.consentPayments = [
        {'payment_id': 'p0', 'status': 'Rejected'},
        {'payment_id': 'p1', 'status': 'Pending'},
      ];
      backend.paymentCreatedAt = backend.now;

      await run(ConsentType.single);

      expect(backend.where('GET', '/payments/p1'), isNotEmpty);
      expect(backend.where('GET', '/payments/p0'), isEmpty);
      expect(manager.state, PaymentState.succeeded);
    });

    test('a definite 4xx on create fails with the coded message', () async {
      backend.paymentCreates = [
        () => http.Response(jsonEncode({'code': 'BP036'}), 422),
      ];

      await run(ConsentType.single);

      expect(manager.state, PaymentState.failed);
      expect(manager.message, PaymentErrorHelper.bankDeclined);
      expect(backend.where('POST', '/payments'), hasLength(1));
    });
  });

  group('customer cancel', () {
    test('revokes the consent and ends cancelled', () async {
      expect(await manager.start(ConsentType.single), isNotNull);
      expect(manager.canCancel, isTrue);

      await manager.cancel();

      expect(backend.where('DELETE', '/consent'), hasLength(1));
      expect(manager.state, PaymentState.cancelled);
    });

    test('keeps tracking when a payment already exists', () async {
      backend.revoke = () => http.Response(jsonEncode({'code': 'BP703'}), 409);
      backend.consentStatus = (_) => ConsentStatus.consumed;
      backend.consentPayments = [
        {'payment_id': 'p1', 'status': 'Pending'},
      ];
      backend.paymentCreatedAt = backend.now;
      expect(await manager.start(ConsentType.single), isNotNull);

      await manager.cancel();
      await settle();

      expect(manager.state, PaymentState.succeeded);
      expect(backend.where('POST', '/payments'), isEmpty);
    });

    test('is not offered once the app starts creating the payment', () async {
      backend.consentStatus = (_) => ConsentStatus.authorised;
      final offered = <bool>[];
      manager.addListener(() {
        if (backend.where('POST', '/payments').isNotEmpty) {
          offered.add(manager.canCancel);
        }
      });

      await run(ConsentType.single);

      expect(offered, isNotEmpty);
      expect(offered, everyElement(isFalse));
    });
  });
}
