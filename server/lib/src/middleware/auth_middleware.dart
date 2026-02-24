import 'package:shelf/shelf.dart';

/// Creates Shelf middleware that validates a static API key.
///
/// The Flutter app must include the header:
///   `Authorization: Bearer <APP_API_KEY>`
///
/// -----------------------------------------------------------------------
/// DEMO ONLY: This is a simplified form of app-to-server authentication
/// to demonstrate the *pattern*. In a production application you should:
///
///   - Use proper authentication (OAuth2, JWT, session tokens, etc.)
///   - Serve over HTTPS / TLS
///   - Add rate limiting and request validation
///   - Rotate keys regularly and store them in a secrets manager
/// -----------------------------------------------------------------------
Middleware apiKeyAuth(String expectedApiKey) {
  return (Handler innerHandler) {
    return (Request request) {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || authHeader != 'Bearer $expectedApiKey') {
        return Response.forbidden(
          '{"error": "invalid_api_key", '
          '"message": "A valid API key is required. '
          'Pass it via the Authorization: Bearer <key> header."}',
          headers: {'content-type': 'application/json'},
        );
      }

      return innerHandler(request);
    };
  };
}
