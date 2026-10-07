/// Environment configuration loaded via `--dart-define` at build time.
///
/// No secrets are stored in this file or in the app binary. BlinkPay API
/// credentials live on the backend proxy server (see `server/`).
///
/// Usage:
///   flutter run \
///     --dart-define=BACKEND_URL=http://10.0.2.2:4567 \
///     --dart-define=APP_API_KEY=your_key_here
class Environment {
  /// URL of the backend proxy server.
  ///
  /// Defaults to `http://10.0.2.2:4567` which is the Android emulator's
  /// alias for the host machine's localhost.
  ///
  /// Common values:
  ///   - Android emulator:  http://10.0.2.2:4567
  ///   - iOS simulator:     http://localhost:4567
  ///   - Physical device:   http://`<your-lan-ip>`:4567
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'http://10.0.2.2:4567',
  );

  /// API key for authenticating with the backend proxy server.
  ///
  /// This must match the APP_API_KEY configured in `server/.env`.
  ///
  /// -----------------------------------------------------------------------
  /// DEMO ONLY: In production, use proper authentication (OAuth2, JWT, etc.)
  /// between the mobile app and your backend server.
  /// -----------------------------------------------------------------------
  static const String appApiKey = String.fromEnvironment('APP_API_KEY');

  /// The return URL the backend sends to Blink Payments (its
  /// `APP_REDIRECT_URI`), used here to recognise the deep link. The scheme is
  /// registered in AndroidManifest.xml and Info.plist.
  static const String redirectUri = String.fromEnvironment(
    'APP_REDIRECT_URI',
    defaultValue: 'blinkpaydemo://callback',
  );

  /// Unit price shown in the cart. Display only: the backend prices the
  /// order from its own `UNIT_PRICE`, and `run.sh` passes that value here.
  static const String unitPrice = String.fromEnvironment(
    'UNIT_PRICE',
    defaultValue: '1.00',
  );

  /// Validates that required configuration is present.
  static bool isValid() {
    return backendUrl.isNotEmpty && appApiKey.isNotEmpty;
  }
}
