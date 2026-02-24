import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// HTTP client for the BlinkPay API with automatic OAuth2 token management.
///
/// This client holds the BlinkPay client_id and client_secret server-side,
/// acquires access tokens via the client_credentials grant, and forwards
/// requests from the Flutter app to BlinkPay with the appropriate
/// Bearer token attached.
class BlinkPayClient {
  final ServerConfig config;
  final http.Client _httpClient;

  static const Duration _tokenRequestTimeout = Duration(seconds: 10);
  static const Duration _apiRequestTimeout = Duration(seconds: 30);

  // Token state — same caching + mutex pattern as the original Flutter
  // BlinkPayService to handle concurrent requests safely.
  String? _accessToken;
  DateTime? _tokenExpiry;
  Future<String>? _tokenRefreshFuture;

  BlinkPayClient({required this.config}) : _httpClient = http.Client();

  /// Returns a valid access token, refreshing if expired.
  Future<String> _getToken() async {
    // Use cached token if still valid
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken!;
    }

    // Reuse in-flight refresh to prevent race conditions
    if (_tokenRefreshFuture != null) {
      return await _tokenRefreshFuture!;
    }

    // Start a new refresh
    _tokenRefreshFuture = _refreshToken();
    try {
      return await _tokenRefreshFuture!;
    } finally {
      _tokenRefreshFuture = null;
    }
  }

  /// Performs the OAuth2 client_credentials token exchange with BlinkPay.
  Future<String> _refreshToken() async {
    // Clear stale token so a failed refresh doesn't leave an expired token
    // that could pass the time check in _getToken() on the next call.
    _accessToken = null;
    _tokenExpiry = null;

    final tokenUri =
        Uri.https(config.blinkPayApiUrl, '/oauth2/token');

    final response = await _httpClient
        .post(
          tokenUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'client_id': config.clientId,
            'client_secret': config.clientSecret,
            'grant_type': 'client_credentials',
          }),
        )
        .timeout(_tokenRequestTimeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String;
      _tokenExpiry =
          DateTime.now().add(Duration(seconds: data['expires_in'] as int));
      print('[BlinkPayClient] Access token refreshed successfully');
      return _accessToken!;
    }

    throw Exception(
      'Failed to get BlinkPay token: ${response.statusCode}',
    );
  }

  /// Forwards an HTTP request to the BlinkPay API.
  ///
  /// Automatically attaches a valid Bearer token. Returns the raw
  /// [http.Response] so that route handlers can relay the status code
  /// and body back to the Flutter app as-is.
  Future<http.Response> forward({
    required String method,
    required String path,
    String? body,
  }) async {
    final token = await _getToken();
    final url = Uri.https(config.blinkPayApiUrl, path);

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
    };

    final http.Response response;

    switch (method.toUpperCase()) {
      case 'GET':
        response = await _httpClient
            .get(url, headers: headers)
            .timeout(_apiRequestTimeout);
      case 'POST':
        response = await _httpClient
            .post(url, headers: headers, body: body)
            .timeout(_apiRequestTimeout);
      case 'DELETE':
        response = await _httpClient
            .delete(url, headers: headers)
            .timeout(_apiRequestTimeout);
      default:
        throw ArgumentError('Unsupported HTTP method: $method');
    }

    return response;
  }
}
