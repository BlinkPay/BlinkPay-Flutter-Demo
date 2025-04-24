/// Provides helper functions for handling payment-related errors.
class PaymentErrorHelper {
  /// Converts a raw error message string into a user-friendly message.
  static String getUserFriendlyMessage(String errorMessage) {
    // Convert to lowercase for case-insensitive matching
    final lowerCaseError = errorMessage.toLowerCase();

    // Simplified Error Categories:

    // 1. Authentication / Consent Related
    if (lowerCaseError.contains('token') ||
        lowerCaseError.contains('authentication') ||
        lowerCaseError.contains('consent')) {
      return 'There was an issue setting up or authorizing the payment with your bank. Please try again.';
    }

    // 2. Verification / Timeout Related
    if (lowerCaseError.contains('timeout') ||
        lowerCaseError.contains('verify') ||
        lowerCaseError.contains('verification')) {
      return 'Payment status check timed out or failed. Please check your bank app/account before retrying.';
    }

    // 3. Network Related
    if (lowerCaseError.contains('network') ||
        lowerCaseError.contains('socket') ||
        lowerCaseError.contains('connection')) {
      return 'Network error. Please check your internet connection and try again.';
    }

    // 4. Browser/App Launch Related
    if (lowerCaseError.contains('browser') ||
        lowerCaseError.contains('launch')) {
      return 'Could not open the bank app or website. Please ensure you have the necessary apps installed and try again.';
    }

    // 5. Generic Fallback
    return 'An unexpected error occurred during the payment process. Please try again later.';
  }
}
