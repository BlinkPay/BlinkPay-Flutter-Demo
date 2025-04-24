import 'package:flutter_dotenv/flutter_dotenv.dart';

class Environment {
  static final Environment _instance = Environment._internal();
  factory Environment() => _instance;
  Environment._internal();

  static String get blinkPayApiUrl => 
    dotenv.env['BLINKPAY_API_URL'] ?? 'sandbox.debit.blinkpay.co.nz';
    
  static String get clientId => 
    dotenv.env['BLINKPAY_CLIENT_ID'] ?? '';
    
  static String get clientSecret => 
    dotenv.env['BLINKPAY_CLIENT_SECRET'] ?? '';
    
  static String get redirectUri => 
      dotenv.env['APP_REDIRECT_URI'] ?? 'blinkpaydemo://callback';

  static String get unitPrice =>
    dotenv.env['UNIT_PRICE'] ?? '1.00';

  // Helper method to validate environment
  static bool isValid() {
    return clientId.isNotEmpty && 
           clientSecret.isNotEmpty;
  }
}