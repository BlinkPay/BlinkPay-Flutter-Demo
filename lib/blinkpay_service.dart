import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, HttpException;

import 'package:http/http.dart' as http;

import './env.dart';
import './models/payment_models.dart';
import './utils/log.dart';

/// Waits for [duration]. Injected so tests can run retries and polling
/// without real delays.
typedef Sleep = Future<void> Function(Duration duration);

/// The backend answered with an error. [code] is the Blink Payments error
/// code (`BPxxx`) relayed by the backend, or the backend's own code.
class BlinkPayApiException implements Exception {
  final int statusCode;
  final String? code;
  final String? message;

  BlinkPayApiException(this.statusCode, {this.code, this.message});

  factory BlinkPayApiException.fromResponse(http.Response response) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      body = null;
    }
    return BlinkPayApiException(
      response.statusCode,
      code: body?['code'] as String?,
      message: body?['message'] as String?,
    );
  }

  @override
  String toString() => 'BlinkPayApiException($statusCode, $code): $message';
}

/// The request may or may not have reached the backend: no response arrived.
class BlinkPayNetworkException implements Exception {
  final Object cause;

  BlinkPayNetworkException(this.cause);

  @override
  String toString() => 'BlinkPayNetworkException: $cause';
}

/// Talks to this demo's backend, which holds the Blink Payments credentials
/// and decides amounts and PCR. The app never sees a Blink Payments secret.
///
/// Retry policy: at most [maxRetries] retries. 5xx responses and network
/// failures back off exponentially (0.5 s, then 1 s); a 429 waits for its
/// `Retry-After`. Any other 4xx is never retried, because sending the same
/// request again cannot fix it. A POST is only retried when it carries an
/// idempotency key, so a retry can never create a second consent or payment.
class BlinkPayService {
  static const Duration apiTimeout = Duration(seconds: 30);
  static const int maxRetries = 2;
  static const Duration initialBackoff = Duration(milliseconds: 500);

  /// A 429 asking us to wait longer than this is reported rather than waited
  /// out with the customer watching a spinner.
  static const Duration maxRetryAfter = Duration(seconds: 10);

  final http.Client _client;
  final Sleep _sleep;
  final String _baseUrl;
  final String _apiKey;

  BlinkPayService({
    http.Client? client,
    Sleep? sleep,
    String baseUrl = Environment.backendUrl,
    String apiKey = Environment.appApiKey,
  }) : _client = client ?? http.Client(),
       _sleep = sleep ?? Future<void>.delayed,
       _baseUrl = baseUrl,
       _apiKey = apiKey;

  /// Asks the backend to price the cart. Not retried: it has no idempotency
  /// key, and the customer can simply tap again.
  Future<CreatedOrder> createOrder(int quantity) async {
    final json = await _send('POST', '/orders', body: {'quantity': quantity});
    return CreatedOrder(
      orderId: json['order_id'] as String,
      total: (json['amount'] as Map<String, dynamic>)['total'] as String,
    );
  }

  /// Creates the consent for an order. [idempotencyKey] identifies this
  /// attempt; retries reuse it.
  Future<CreatedConsent> createConsent(
    String orderId,
    ConsentType type, {
    required String idempotencyKey,
  }) async {
    final json = await _send(
      'POST',
      '/orders/$orderId/consent',
      body: {'type': type.name},
      idempotencyKey: idempotencyKey,
    );
    return CreatedConsent(
      consentId: json['consent_id'] as String,
      redirectUri: json['redirect_uri'] as String,
    );
  }

  /// Reads the order's consent, including its embedded `payments`.
  Future<Map<String, dynamic>> getConsent(String orderId) =>
      _send('GET', '/orders/$orderId/consent');

  /// Creates a payment against the order's consent and returns its ID.
  ///
  /// Use one [idempotencyKey] per payment attempt and send the same key on
  /// every retry of that attempt: Blink Payments then returns the original
  /// payment instead of creating a second one.
  Future<String> createPayment(
    String orderId, {
    required String idempotencyKey,
  }) async {
    final json = await _send(
      'POST',
      '/orders/$orderId/payments',
      body: const {},
      idempotencyKey: idempotencyKey,
    );
    final paymentId = json['payment_id'];
    if (paymentId is! String || paymentId.isEmpty) {
      throw BlinkPayApiException(200, message: 'No payment_id in response');
    }
    return paymentId;
  }

  /// Reads a payment's status.
  Future<Map<String, dynamic>> getPayment(String orderId, String paymentId) =>
      _send('GET', '/orders/$orderId/payments/$paymentId');

  /// Revokes the order's consent.
  Future<RevokeResult> revokeConsent(String orderId) async {
    try {
      await _send('DELETE', '/orders/$orderId/consent');
      return RevokeResult.revoked;
    } on BlinkPayApiException catch (e) {
      if (e.statusCode == 409 && e.code == 'BP701') {
        return RevokeResult.alreadyRevoked;
      }
      // 409 otherwise means a payment is pending or active on the consent;
      // 422 means the consent already ended, possibly because a payment was
      // made with it. Either way a payment may exist, so the outcome must be
      // read from the consent, not assumed.
      if (e.statusCode == 409 || e.statusCode == 422) {
        return RevokeResult.outcomeExists;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? idempotencyKey,
  }) async {
    final uri = Uri.parse('$_baseUrl/api$path');
    final retryable = method != 'POST' || idempotencyKey != null;

    for (var attempt = 0; ; attempt++) {
      final canRetry = retryable && attempt < maxRetries;
      final request = http.Request(method, uri)
        // DEMO ONLY: a static key. Production apps authenticate the customer.
        ..headers['Authorization'] = 'Bearer $_apiKey'
        ..headers['Content-Type'] = 'application/json';
      if (idempotencyKey != null) {
        request.headers['idempotency-key'] = idempotencyKey;
      }
      if (body != null) request.body = jsonEncode(body);

      http.Response? response;
      Object? noResponse;
      try {
        response = await http.Response.fromStream(
          await _client.send(request).timeout(apiTimeout),
        );
      } on TimeoutException catch (e) {
        noResponse = e;
      } on http.ClientException catch (e) {
        noResponse = e;
      }
      if (response == null) {
        Log.info(
          '$method $path: no response ($noResponse), '
          'attempt ${attempt + 1}',
        );
        if (!canRetry) throw BlinkPayNetworkException(noResponse!);
        await _sleep(_backoff(attempt));
        continue;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body.isEmpty) return const {};
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      final error = BlinkPayApiException.fromResponse(response);
      Log.info(
        '$method $path: ${response.statusCode} ${error.code}, '
        'attempt ${attempt + 1}',
      );
      final delay = canRetry ? _retryDelay(response, attempt) : null;
      if (delay == null) throw error;
      await _sleep(delay);
    }
  }

  Duration _backoff(int attempt) => initialBackoff * (1 << attempt);

  /// How long to wait before retrying [response], or null to give up.
  Duration? _retryDelay(http.Response response, int attempt) {
    if (response.statusCode == 429) {
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      if (retryAfter == null) return _backoff(attempt);
      return retryAfter > maxRetryAfter ? null : retryAfter;
    }
    return response.statusCode >= 500 ? _backoff(attempt) : null;
  }

  /// `Retry-After` is either whole seconds or an HTTP date.
  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final wait = HttpDate.parse(value).difference(DateTime.now());
      return wait.isNegative ? Duration.zero : wait;
    } on HttpException {
      return null;
    }
  }
}
