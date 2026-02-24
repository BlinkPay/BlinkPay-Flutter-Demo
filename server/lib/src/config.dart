import 'package:dotenv/dotenv.dart';

/// Server configuration loaded from environment variables.
class ServerConfig {
  final String blinkPayApiUrl;
  final String clientId;
  final String clientSecret;
  final String appApiKey;
  final int port;

  ServerConfig({
    required this.blinkPayApiUrl,
    required this.clientId,
    required this.clientSecret,
    required this.appApiKey,
    this.port = 4567,
  });

  /// Creates a [ServerConfig] from a [DotEnv] instance.
  factory ServerConfig.fromEnv(DotEnv env) {
    return ServerConfig(
      blinkPayApiUrl:
          env['BLINKPAY_API_URL'] ?? 'sandbox.debit.blinkpay.co.nz',
      clientId: env['BLINKPAY_CLIENT_ID'] ?? '',
      clientSecret: env['BLINKPAY_CLIENT_SECRET'] ?? '',
      appApiKey: env['APP_API_KEY'] ?? '',
      port: int.tryParse(env['SERVER_PORT'] ?? '4567') ?? 4567,
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
  }
}
