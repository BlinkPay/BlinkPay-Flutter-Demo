import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../blinkpay_client.dart';

/// Proxy routes for BlinkPay single-consent and enduring-consent endpoints.
///
/// All requests are forwarded to BlinkPay with the server-managed OAuth2
/// token. The Flutter app never sees BlinkPay credentials.
class ConsentRoutes {
  final BlinkPayClient _client;

  ConsentRoutes(this._client);

  /// Registers all consent routes on the given [router].
  ///
  /// Routes are relative to the mount point (e.g. `/api/payments/v1/`).
  void addTo(Router router) {
    // Single consents
    router.post('/single-consents', _createSingleConsent);
    router.get('/single-consents/<id>', _getSingleConsent);
    router.delete('/single-consents/<id>', _revokeSingleConsent);

    // Enduring consents
    router.post('/enduring-consents', _createEnduringConsent);
    router.get('/enduring-consents/<id>', _getEnduringConsent);
    router.delete('/enduring-consents/<id>', _revokeEnduringConsent);
  }

  // ── Single consents ──────────────────────────────────────────────────

  Future<Response> _createSingleConsent(Request request) async {
    return _proxyPost(request, '/payments/v1/single-consents');
  }

  Future<Response> _getSingleConsent(Request request, String id) async {
    return _proxyGet('/payments/v1/single-consents/$id');
  }

  Future<Response> _revokeSingleConsent(Request request, String id) async {
    return _proxyDelete('/payments/v1/single-consents/$id');
  }

  // ── Enduring consents ────────────────────────────────────────────────

  Future<Response> _createEnduringConsent(Request request) async {
    return _proxyPost(request, '/payments/v1/enduring-consents');
  }

  Future<Response> _getEnduringConsent(Request request, String id) async {
    return _proxyGet('/payments/v1/enduring-consents/$id');
  }

  Future<Response> _revokeEnduringConsent(Request request, String id) async {
    return _proxyDelete('/payments/v1/enduring-consents/$id');
  }

  // ── Proxy helpers ────────────────────────────────────────────────────

  Future<Response> _proxyPost(Request request, String path) async {
    try {
      final body = await request.readAsString();
      final blinkPayResponse =
          await _client.forward(method: 'POST', path: path, body: body);
      return Response(
        blinkPayResponse.statusCode,
        body: blinkPayResponse.body,
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      print('[ConsentRoutes] Error proxying POST $path: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'proxy_error', 'message': 'An internal error occurred. Please try again.'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _proxyGet(String path) async {
    try {
      final blinkPayResponse =
          await _client.forward(method: 'GET', path: path);
      return Response(
        blinkPayResponse.statusCode,
        body: blinkPayResponse.body,
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      print('[ConsentRoutes] Error proxying GET $path: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'proxy_error', 'message': 'An internal error occurred. Please try again.'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _proxyDelete(String path) async {
    try {
      final blinkPayResponse =
          await _client.forward(method: 'DELETE', path: path);

      // DELETE may return 204 (no content), 409 (already revoked), or 422.
      // Pass the status code through; include body only if present.
      final body = blinkPayResponse.body.isNotEmpty
          ? blinkPayResponse.body
          : null;
      return Response(
        blinkPayResponse.statusCode,
        body: body,
        headers: body != null ? {'content-type': 'application/json'} : null,
      );
    } catch (e) {
      print('[ConsentRoutes] Error proxying DELETE $path: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': 'proxy_error', 'message': 'An internal error occurred. Please try again.'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }
}
