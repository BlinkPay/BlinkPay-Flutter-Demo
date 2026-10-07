import '../blinkpay_service.dart';
import '../models/payment_models.dart';

/// Chooses the customer-facing message for an error or a failed outcome.
///
/// Branches on the Blink Payments error `code` (see the Error Codes reference
/// in the docs), then on the HTTP status, never on the wording of a message:
/// messages are for developers and can change.
class PaymentErrorHelper {
  static const String expired =
      'This payment request has expired. Please start again.';
  static const String cancelled =
      'This payment was cancelled. No money has been taken.';
  static const String bankDeclined =
      'Your bank declined the payment. No money has been taken.';
  static const String overLimit =
      'This amount is over the payment limit for your bank.';
  static const String bankUnavailable =
      'Your bank is temporarily unavailable. Please try again shortly.';
  static const String notSetUp =
      'Payments are not set up correctly for this app. Please contact the merchant.';
  static const String busy =
      'We are receiving a lot of requests. Please wait a moment and try again.';
  static const String serviceUnavailable =
      'The payment service is having problems. Please try again shortly.';
  static const String network =
      'Network error. Please check your internet connection and try again.';
  static const String generic =
      'Something went wrong setting up the payment. Please try again.';

  static const Map<String, String> _byCode = {
    'BP002': expired,
    'BP003': expired,
    'BP004': expired,
    'BP021': expired,
    'BP025': expired,
    'BP015': cancelled,
    'BP701': cancelled,
    'BP036': bankDeclined,
    'BP229': overLimit,
    'BP277': overLimit,
    'BP287': overLimit,
    'BP214': notSetUp,
    'BP216': notSetUp,
    'invalid_api_key': notSetUp,
    'BP601': bankUnavailable,
    'order_not_found': expired,
  };

  /// The message for an error thrown by [BlinkPayService].
  static String forError(Object error) {
    if (error is BlinkPayNetworkException) return network;
    if (error is! BlinkPayApiException) return generic;

    final byCode = _byCode[error.code];
    if (byCode != null) return byCode;
    if (error.statusCode == 429) return busy;
    if (error.statusCode >= 500) return serviceUnavailable;
    return generic;
  }

  /// The message for a consent that ended without a payment.
  static String forConsentStatus(String? status) {
    switch (status) {
      case ConsentStatus.rejected:
        return 'The payment was declined or not approved in time. '
            'No money has been taken.';
      case ConsentStatus.gatewayTimeout:
        return 'The payment session expired before a bank was chosen. '
            'Please start again.';
      case ConsentStatus.revoked:
        return cancelled;
      default:
        return generic;
    }
  }
}
