import 'package:dotenv/dotenv.dart';

/// Server configuration loaded from environment variables.
class ServerConfig {
  final String blinkPayApiUrl;
  final String clientId;
  final String clientSecret;
  final String appApiKey;
  final int port;

  /// Price of the demo product, e.g. `1.00`. The server prices every order
  /// from this value; the app's own copy is for display only.
  final String unitPrice;

  /// Where Blink Payments sends the customer after the bank. It must be
  /// registered for your client in the Merchant Portal (Settings > API).
  final String redirectUri;

  ServerConfig({
    required this.blinkPayApiUrl,
    required this.clientId,
    required this.clientSecret,
    required this.appApiKey,
    this.port = 4567,
    this.unitPrice = '1.00',
    this.redirectUri = 'blinkpaydemo://callback',
  });

  /// Creates a [ServerConfig] from a [DotEnv] instance.
  factory ServerConfig.fromEnv(DotEnv env) {
    return ServerConfig(
      blinkPayApiUrl: env['BLINKPAY_API_URL'] ?? 'sandbox.debit.blinkpay.co.nz',
      clientId: env['BLINKPAY_CLIENT_ID'] ?? '',
      clientSecret: env['BLINKPAY_CLIENT_SECRET'] ?? '',
      appApiKey: env['APP_API_KEY'] ?? '',
      port: int.tryParse(env['SERVER_PORT'] ?? '4567') ?? 4567,
      unitPrice: env['UNIT_PRICE'] ?? '1.00',
      redirectUri: env['APP_REDIRECT_URI'] ?? 'blinkpaydemo://callback',
    );
  }

  /// Validates that all required configuration values are present.
  void validate() {
    final missing = <String>[];
    if (clientId.isEmpty) missing.add('BLINKPAY_CLIENT_ID');
    if (clientSecret.isEmpty) missing.add('BLINKPAY_CLIENT_SECRET');
    if (appApiKey.isEmpty) missing.add('APP_API_KEY');

    if (missing.isNotEmpty) {
      throw StateError(
        'Missing required environment variables: ${missing.join(', ')}\n'
        'Copy server/.env.example to server/.env and fill in the values.',
      );
    }
    if (Money.tryParseCents(unitPrice) == null) {
      throw StateError(
        'UNIT_PRICE must be an amount like 1.00, got "$unitPrice"',
      );
    }
  }
}

/// Whole-cent arithmetic for NZD amounts, so prices never pass through a
/// floating-point value.
class Money {
  static final _pattern = RegExp(r'^\d{1,7}(\.\d{1,2})?$');

  /// Parses `"12"`, `"12.5"` or `"12.50"` into cents; null if not an amount.
  static int? tryParseCents(String value) {
    if (!_pattern.hasMatch(value)) return null;
    final parts = value.split('.');
    final cents = parts.length == 2 ? parts[1].padRight(2, '0') : '00';
    return int.parse(parts[0]) * 100 + int.parse(cents);
  }

  /// Formats cents as the API's amount string, e.g. `300` → `"3.00"`.
  static String format(int cents) =>
      '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
}
