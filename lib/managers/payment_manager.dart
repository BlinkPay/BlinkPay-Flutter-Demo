import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../blinkpay_service.dart';
import '../models/payment_models.dart';
import '../models/shopping_cart_model.dart';
import '../utils/log.dart';
import '../utils/payment_error_helper.dart';

/// Where the payment flow is.
enum PaymentState {
  idle,
  starting,

  /// The customer is at the gateway or their bank; checking the consent.
  awaitingAuthorisation,

  /// A payment exists; checking it until the bank settles it.
  paymentProcessing,

  /// The payment reached `AcceptedSettlementCompleted`.
  succeeded,

  /// Definitely not paid: rejected, expired, or never created.
  failed,

  /// The customer cancelled before approving and the consent was revoked.
  cancelled,

  /// We stopped checking without a final answer. Not a failure: the outcome
  /// is still to come, and the backend must keep tracking it.
  unresolved,
}

/// How often and how long the app checks. The defaults follow the Blink
/// Payments docs: a consent no more than every 2-3 s, a payment every 30-60 s.
class PaymentTimings {
  final Duration consentPollInterval;

  /// The Gateway's session cutoff: how long the customer has to choose a
  /// bank, counted from consent creation.
  final Duration gatewayWaitLimit;

  /// How long to keep checking once the customer has reached their bank.
  /// The bank's own window (4-10 minutes, per bank and flow) starts then, so
  /// this runs after the gateway time rather than inside it.
  final Duration bankWaitLimit;
  final Duration paymentPollInterval;

  /// Settlement can take hours. The app watches for this long, then leaves
  /// the outcome to the backend.
  final Duration paymentWaitLimit;

  const PaymentTimings({
    this.consentPollInterval = const Duration(seconds: 3),
    this.gatewayWaitLimit = const Duration(minutes: 15),
    this.bankWaitLimit = const Duration(minutes: 10),
    this.paymentPollInterval = const Duration(seconds: 30),
    this.paymentWaitLimit = const Duration(minutes: 2),
  });
}

class _Flow {
  final String orderId;
  final String consentId;
  final String total;
  DateTime consentDeadline;
  bool reachedBank = false;

  /// One key per payment attempt, reused on every retry of the create call,
  /// including retries from later polling cycles and app resumes.
  final String paymentIdempotencyKey;

  String? paymentId;
  DateTime? paymentDeadline;
  DateTime? nextPaymentCheck;
  bool cancelRequested = false;
  bool creatingPayment = false;

  _Flow({
    required this.orderId,
    required this.consentId,
    required this.total,
    required this.consentDeadline,
    required this.paymentIdempotencyKey,
  });
}

/// Runs a payment from consent creation to a final outcome.
///
/// It never revokes a consent or reports a failure on its own while the
/// customer may still approve it or the payment is still in flight: only a
/// terminal status from Blink Payments ends the flow. When the app stops
/// checking first, the state is [PaymentState.unresolved].
class PaymentManager extends ChangeNotifier {
  final BlinkPayService _service;
  final ShoppingCartModel _cart;
  final Sleep _sleep;
  final DateTime Function() _now;
  final String Function() _newIdempotencyKey;
  final PaymentTimings timings;

  PaymentState _state = PaymentState.idle;
  String? _message;
  _Flow? _flow;

  /// Bumped whenever a flow starts or ends, so a check loop from an earlier
  /// flow stops at its next step.
  int _generation = 0;
  int? _trackingGeneration;

  PaymentManager({
    required BlinkPayService blinkPayService,
    required ShoppingCartModel cartModel,
    Sleep? sleep,
    DateTime Function()? clock,
    String Function()? newIdempotencyKey,
    this.timings = const PaymentTimings(),
  }) : _service = blinkPayService,
       _cart = cartModel,
       _sleep = sleep ?? Future<void>.delayed,
       _now = clock ?? DateTime.now,
       _newIdempotencyKey = newIdempotencyKey ?? (() => const Uuid().v4());

  PaymentState get state => _state;

  /// Customer-facing text for the current state.
  String? get message => _message;

  String? get consentId => _flow?.consentId;

  bool get isBusy =>
      _state == PaymentState.starting ||
      _state == PaymentState.awaitingAuthorisation ||
      _state == PaymentState.paymentProcessing;

  /// The customer can cancel only before the app starts creating a payment.
  bool get canCancel =>
      _state == PaymentState.awaitingAuthorisation &&
      _flow?.paymentId == null &&
      _flow?.cancelRequested == false &&
      _flow?.creatingPayment == false;

  /// Creates an order and consent, and returns the URL to open in the in-app
  /// browser, or null if it could not be created.
  Future<String?> start(ConsentType type) async {
    if (isBusy) return null;
    final generation = ++_generation;
    _flow = null;
    _setState(PaymentState.starting, null);

    try {
      final order = await _service.createOrder(_cart.quantity);
      final consent = await _service.createConsent(
        order.orderId,
        type,
        idempotencyKey: _newIdempotencyKey(),
      );
      if (generation != _generation) return null;

      _flow = _Flow(
        orderId: order.orderId,
        consentId: consent.consentId,
        total: order.total,
        consentDeadline: _now().add(timings.gatewayWaitLimit),
        paymentIdempotencyKey: _newIdempotencyKey(),
      );
      Log.info(
        'Consent ${consent.consentId} created for order ${order.orderId}',
      );
      _setState(PaymentState.awaitingAuthorisation, _awaitingMessage);
      return consent.redirectUri;
    } catch (e) {
      Log.error('Could not start payment', e);
      if (generation == _generation) {
        _setState(PaymentState.failed, PaymentErrorHelper.forError(e));
      }
      return null;
    }
  }

  /// Call once the in-app browser is open. Starts checking the consent.
  void onBrowserOpened() => _ensureTracking();

  /// The in-app browser could not be opened, so the customer never saw the
  /// consent. Nobody can approve it, and it expires on its own.
  void onBrowserFailed(Object error) {
    Log.error('Could not open the payment page', error);
    _endFlow(
      PaymentState.failed,
      'Could not open the payment page. No money has been taken.',
    );
  }

  /// The bank or gateway sent the customer back to the app. The return URL
  /// says nothing reliable about the outcome, even when it carries an
  /// `error`, so the status is read rather than assumed.
  void onReturnFromBank({String? consentId}) {
    if (consentId != null && consentId != _flow?.consentId) {
      Log.info('Ignoring return for another consent: $consentId');
      return;
    }
    _resumeChecking();
  }

  /// The app came back to the foreground, perhaps from the banking app.
  void onAppResumed() => _resumeChecking();

  /// The customer asked to cancel before approving. Revokes the consent so it
  /// cannot be approved later. If a payment already exists, keeps tracking it.
  Future<void> cancel() async {
    final flow = _flow;
    if (!canCancel || flow == null) return;
    flow.cancelRequested = true;
    notifyListeners();

    RevokeResult? result;
    try {
      result = await _service.revokeConsent(flow.orderId);
    } catch (e) {
      Log.error('Could not revoke consent ${flow.consentId}', e);
    }
    if (flow != _flow) return;

    if (result == RevokeResult.revoked ||
        result == RevokeResult.alreadyRevoked) {
      _endFlow(PaymentState.cancelled, PaymentErrorHelper.cancelled);
      return;
    }
    flow.cancelRequested = false;
    if (result == null) {
      _setState(
        PaymentState.awaitingAuthorisation,
        "We couldn't cancel the payment. If you don't want to pay, don't "
        'approve it with your bank.',
      );
    }
    notifyListeners();
    _ensureTracking();
  }

  /// Clears a finished, cancelled or unresolved flow.
  void dismiss() {
    if (isBusy) return;
    _endFlow(PaymentState.idle, null);
  }

  void _resumeChecking() {
    final flow = _flow;
    if (flow == null) return;
    if (_state == PaymentState.unresolved) {
      _setState(
        flow.paymentId == null
            ? PaymentState.awaitingAuthorisation
            : PaymentState.paymentProcessing,
        flow.paymentId == null ? _awaitingMessage : _processingMessage,
      );
    }
    if (isBusy) _ensureTracking();
  }

  Future<void> _ensureTracking() async {
    if (_flow == null || _trackingGeneration == _generation) return;
    final generation = _generation;
    _trackingGeneration = generation;
    try {
      await _track(generation);
    } finally {
      if (_trackingGeneration == generation) _trackingGeneration = null;
    }
  }

  bool _isStale(int generation) => generation != _generation;

  Future<void> _track(int generation) async {
    final flow = _flow!;

    while (flow.paymentId == null) {
      final (:body, :unreadable) = await _read(
        () => _service.getConsent(flow.orderId),
      );
      if (_isStale(generation)) return;
      if (unreadable) {
        return _setState(PaymentState.unresolved, _unreadableMessage);
      }

      final status = body?['status'] as String?;
      if (ConsentStatus.isFailed(status)) {
        return _endFlow(
          PaymentState.failed,
          PaymentErrorHelper.forConsentStatus(status),
        );
      }
      if (status == ConsentStatus.awaitingAuthorisation && !flow.reachedBank) {
        flow.reachedBank = true;
        final bankDeadline = _now().add(timings.bankWaitLimit);
        if (bankDeadline.isAfter(flow.consentDeadline)) {
          flow.consentDeadline = bankDeadline;
        }
      }
      if (!flow.cancelRequested &&
          (status == ConsentStatus.authorised ||
              status == ConsentStatus.consumed)) {
        // A payment from an earlier attempt shows up here: a single consent
        // is Consumed by it, but an enduring one stays Authorised.
        flow.paymentId = _firstPaymentId(body!);
        if (flow.paymentId == null) await _createPayment(flow);
      }
      if (_isStale(generation)) return;
      if (flow.paymentId != null) break;

      if (!_now().isBefore(flow.consentDeadline)) {
        return _setState(
          PaymentState.unresolved,
          "We haven't heard back from your bank yet. If you still approve "
          'the payment, come back to this app to finish it.',
        );
      }
      await _sleep(timings.consentPollInterval);
      if (_isStale(generation)) return;
    }

    _setState(PaymentState.paymentProcessing, _processingMessage);
    flow.paymentDeadline ??= _now().add(timings.paymentWaitLimit);
    flow.nextPaymentCheck ??= _now().add(timings.paymentPollInterval);

    while (true) {
      final wait = flow.nextPaymentCheck!.difference(_now());
      if (wait > Duration.zero) await _sleep(wait);
      if (_isStale(generation)) return;

      final (:body, :unreadable) = await _read(
        () => _service.getPayment(flow.orderId, flow.paymentId!),
      );
      if (_isStale(generation)) return;
      flow.nextPaymentCheck = _now().add(timings.paymentPollInterval);
      if (unreadable) {
        return _setState(PaymentState.unresolved, _unreadableMessage);
      }

      final status = body?['status'] as String?;
      if (status == PaymentStatus.completed) {
        _cart.reset();
        return _endFlow(
          PaymentState.succeeded,
          'Payment of \$${flow.total} completed.',
        );
      }
      if (status == PaymentStatus.rejected) {
        return _endFlow(PaymentState.failed, PaymentErrorHelper.bankDeclined);
      }
      if (!_now().isBefore(flow.paymentDeadline!)) {
        return _setState(
          PaymentState.unresolved,
          'Your bank is still processing the payment. You do not need to '
          'pay again: the merchant will confirm it once it completes.',
        );
      }
    }
  }

  /// Creates the payment, reusing the flow's idempotency key. Leaves
  /// [_Flow.paymentId] null when the outcome is not known yet, so the next
  /// check tries again with the same key.
  Future<void> _createPayment(_Flow flow) async {
    flow.creatingPayment = true;
    notifyListeners();
    try {
      flow.paymentId = await _service.createPayment(
        flow.orderId,
        idempotencyKey: flow.paymentIdempotencyKey,
      );
      Log.info('Payment ${flow.paymentId} created');
    } on BlinkPayNetworkException catch (e) {
      Log.info('Payment create outcome unknown, will retry: $e');
    } on BlinkPayApiException catch (e) {
      // 2xx without an ID, 409 (an earlier request with this key, or on this
      // consent, made or is making the payment) and BP002 (the consent is used
      // up, maybe by that payment) all mean a payment may exist: the consent's
      // payments will show it.
      if (e.statusCode < 400 ||
          e.statusCode == 409 ||
          e.statusCode == 429 ||
          e.statusCode >= 500 ||
          e.code == 'BP002') {
        Log.info('Payment create not confirmed, will re-check: $e');
        return;
      }
      Log.error('Payment create rejected', e);
      _endFlow(PaymentState.failed, PaymentErrorHelper.forError(e));
    } finally {
      flow.creatingPayment = false;
      if (flow == _flow) notifyListeners();
    }
  }

  String? _firstPaymentId(Map<String, dynamic> consent) {
    final payments = consent['payments'];
    if (payments is! List || payments.isEmpty) return null;
    return (payments.first as Map<String, dynamic>)['payment_id'] as String?;
  }

  /// Reads a status. [body] is null after a transient failure (try again
  /// later); [unreadable] means the backend cannot answer for this order.
  Future<({Map<String, dynamic>? body, bool unreadable})> _read(
    Future<Map<String, dynamic>> Function() read,
  ) async {
    try {
      return (body: await read(), unreadable: false);
    } on BlinkPayApiException catch (e) {
      Log.info('Status read failed: $e');
      final transient = e.statusCode == 429 || e.statusCode >= 500;
      return (body: null, unreadable: !transient);
    } on BlinkPayNetworkException catch (e) {
      Log.info('Status read failed: $e');
      return (body: null, unreadable: false);
    }
  }

  String get _awaitingMessage =>
      'Approve the payment of \$${_flow?.total} with your bank. You can '
      'switch to your banking app and come back here.';

  static const String _processingMessage =
      'Payment submitted. Waiting for your bank to confirm it.';

  static const String _unreadableMessage =
      "We couldn't check this payment. Please check with the merchant "
      'before paying again.';

  void _endFlow(PaymentState state, String? message) {
    _generation++;
    _flow = null;
    _setState(state, message);
  }

  void _setState(PaymentState state, String? message) {
    if (_state == state && _message == message) return;
    _state = state;
    _message = message;
    Log.info('Payment state: $state');
    notifyListeners();
  }
}
