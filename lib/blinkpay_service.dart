import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:intl/intl.dart';

import './env.dart';

/// Payment status constants
class PaymentStatus {
  static const String completed = 'AcceptedSettlementCompleted';
  static const String rejected = 'Rejected';
  static const String pending = 'Pending';
  static const String inProcess = 'AcceptedSettlementInProcess';
}

/// Consent status constants
class ConsentStatus {
  static const String authorised = 'Authorised';
  static const String awaitingAuthorisation = 'AwaitingAuthorisation';
  static const String rejected = 'Rejected';
  static const String revoked = 'Revoked';
  static const String gatewayTimeout = 'GatewayTimeout';
  static const String gatewayAwaitingSubmission = 'GatewayAwaitingSubmission';
}

/// Payment Clearing and Reconciliation information
class PCR {
  final String particulars;
  final String? code;
  final String? reference;

  /// Creates a PCR object with required particulars and optional code and reference.
  PCR({
    required this.particulars,
    this.code,
    this.reference,
  });

  // Ensure PCR values don't exceed maximum allowed length
  String get truncatedParticulars => particulars.substring(0, particulars.length.clamp(0, 12));
  String? get truncatedCode => code?.substring(0, code!.length.clamp(0, 12));
  String? get truncatedReference => reference?.substring(0, reference!.length.clamp(0, 12));
  
  // Convert to a map for API requests
  Map<String, dynamic> toJson() => {
        'particulars': truncatedParticulars,
        if (truncatedCode != null) 'code': truncatedCode,
        if (truncatedReference != null) 'reference': truncatedReference,
      };
}

/// Custom exception for payment check operations
class PaymentCheckException implements Exception {
  final String message;
  PaymentCheckException(this.message);

  @override
  String toString() => message;
}

/// Service for interacting with BlinkPay via the backend proxy server.
///
/// All requests go to the proxy server at [Environment.backendUrl], which
/// holds the BlinkPay client credentials and forwards requests with the
/// appropriate OAuth2 token. This app never sees BlinkPay secrets.
class BlinkPayService {
  static const int maxStatusChecks = 10;
  static const Duration checkInterval = Duration(seconds: 1);
  static const Duration apiTimeout = Duration(seconds: 30);
  static const Duration retryDelay = Duration(seconds: 1);
  static const int maxRetries = 3;

  /// Checks if an error is retryable (network errors, 5xx, 429)
  bool _isRetryableError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('timeout') ||
           errorStr.contains('socket') ||
           errorStr.contains('connection') ||
           errorStr.contains('network') ||
           errorStr.contains('status code 500') ||
           errorStr.contains('status code 502') ||
           errorStr.contains('status code 503') ||
           errorStr.contains('status code 504') ||
           errorStr.contains('status code 429');
  }

  /// Make an authenticated API request to the backend proxy server.
  ///
  /// The proxy server handles BlinkPay OAuth2 authentication. This method
  /// only needs to include the app-to-server API key.
  Future<Map<String, dynamic>> _makeApiRequest({
    required String method,
    required String endpoint,
    Map<String, dynamic>? body,
  }) async {
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;

      try {
        final url = '${Environment.backendUrl}/api$endpoint';

        http.Response response;

        // Authenticate with the backend proxy using the static API key.
        // The proxy then authenticates with BlinkPay using OAuth2 — the
        // mobile app never sees the BlinkPay client_id or client_secret.
        final headers = <String, String>{
          'Authorization': 'Bearer ${Environment.appApiKey}',
          'Content-Type': 'application/json',
        };

        switch (method.toUpperCase()) {
          case 'GET':
            response = await http.get(
              Uri.parse(url),
              headers: headers,
            ).timeout(apiTimeout);
            break;
          case 'POST':
            response = await http.post(
              Uri.parse(url),
              headers: headers,
              body: jsonEncode(body),
            ).timeout(apiTimeout);
            break;
          case 'DELETE':
            response = await http.delete(
              Uri.parse(url),
              headers: headers,
            ).timeout(apiTimeout);
            break;
          default:
            throw Exception('Unsupported method: $method');
        }

        // Special case for DELETE which returns no content
        if (method.toUpperCase() == 'DELETE') {
          if (response.statusCode == 204) {
            return {'success': true};
          } else if (response.statusCode == 409) {
            return {'success': true, 'alreadyRevoked': true};
          } else if (response.statusCode == 422) {
            return {'success': false, 'completed': true};
          }
          // If DELETE returns other status codes, fall through to the general error handling
        }

        // Handle successful responses
        if (response.statusCode == 200 || response.statusCode == 201) {
          return jsonDecode(response.body);
        }

        // Handle error responses
        final errorException = Exception(
            'API request failed: Status code ${response.statusCode}');

        // Retry on 5xx or 429
        if ((response.statusCode >= 500 && response.statusCode < 600) ||
            response.statusCode == 429) {
          if (attempt < maxRetries) {
            debugPrint('Retryable error (${response.statusCode}), attempt $attempt/$maxRetries');
            await Future.delayed(retryDelay);
            continue;
          }
        }

        throw errorException;
      } catch (e) {
        debugPrint('API error ($method $endpoint), attempt $attempt/$maxRetries: $e');

        // Retry on network errors
        if (_isRetryableError(e) && attempt < maxRetries) {
          debugPrint('Retrying after network error...');
          await Future.delayed(retryDelay);
          continue;
        }

        // No more retries or non-retryable error
        rethrow;
      }
    }

    throw Exception('API request failed after $maxRetries attempts');
  }

  /// Create a single payment consent
  Future<Map<String, dynamic>> createSingleConsent(
      PCR pcr, String amount) async {
    debugPrint('Creating BlinkPay single consent');
    return _makeApiRequest(
      method: 'POST',
      endpoint: '/payments/v1/single-consents',
      body: {
        'flow': {
          'detail': {
            'type': 'gateway',
            'redirect_uri': Environment.redirectUri,
          }
        },
        'pcr': pcr.toJson(),
        'amount': {
          'total': amount,
          'currency': 'NZD'
        }
      },
    );
  }

  /// Create an enduring (recurring) consent
  Future<Map<String, dynamic>> createEnduringConsent(String maxAmountPeriod, String maxAmountPayment) async {
    debugPrint('Creating BlinkPay enduring consent');

    // Get current Auckland time
    final auckland = tz.getLocation('Pacific/Auckland');
    final nowInAuckland = tz.TZDateTime.now(auckland);
    
    // Format timestamp with timezone offset
    final baseFormat = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS");
    final baseFormatted = baseFormat.format(nowInAuckland);
    
    final offset = nowInAuckland.timeZoneOffset;
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final sign = offset.isNegative ? '-' : '+';
    final offsetStr = '$sign$hours:$minutes';
    
    final formattedDate = '$baseFormatted$offsetStr';
    
    return _makeApiRequest(
      method: 'POST',
      endpoint: '/payments/v1/enduring-consents',
      body: {
        'flow': {
          'detail': {
            'type': 'gateway',
            'redirect_uri': Environment.redirectUri,
          }
        },
        'maximum_amount_period': {
          'total': maxAmountPeriod,
          'currency': 'NZD'
        },
        'period': 'fortnightly',
        'from_timestamp': formattedDate,
        'maximum_amount_payment': {
          'total': maxAmountPayment,
          'currency': 'NZD'
        }
      },
    );
  }

  /// Create a payment using a consent and return the payment ID
  Future<String> createPayment(String consentId,
      {PCR? pcr, String? amount}) async {
    debugPrint('Creating BlinkPay payment for consent: $consentId');

    final Map<String, dynamic> payload = {
      'consent_id': consentId,
      if (pcr != null && amount != null) ...{
        'pcr': pcr.toJson(),
        'amount': {
          'total': amount,
          'currency': 'NZD',
        },
      },
    };

    try {
      final response = await _makeApiRequest(
        method: 'POST',
        endpoint: '/payments/v1/payments',
        body: payload,
      );

      // Handle different response formats - the API might return payment_id or id
      // Ensure payment_id exists and is a string
      final paymentId = response['payment_id'];
      if (paymentId == null || paymentId is! String || paymentId.isEmpty) {
        debugPrint(
            'Error: Payment ID missing or invalid in response: $response');
        throw Exception('Payment ID missing or invalid in API response');
      }

      debugPrint('Created payment with ID: $paymentId');
      return paymentId; // Return the valid string ID
    } catch (e) {
      debugPrint('Error creating payment: $e');
      // Rethrow the exception to be handled by the caller
      rethrow;
    }
  }

  /// Get details of a single consent
  Future<Map<String, dynamic>> getSingleConsent(String consentId) async {
    debugPrint('Retrieving BlinkPay single consent');
    return _makeApiRequest(
      method: 'GET',
      endpoint: '/payments/v1/single-consents/$consentId',
    );
  }

  /// Get details of an enduring consent
  Future<Map<String, dynamic>> getEnduringConsent(String consentId) async {
    debugPrint('Retrieving BlinkPay enduring consent');
    return _makeApiRequest(
      method: 'GET',
      endpoint: '/payments/v1/enduring-consents/$consentId',
    );
  }
  
  /// Revoke a single consent
  Future<bool> revokeSingleConsent(String consentId) async {
    debugPrint('Revoking BlinkPay single consent: $consentId');
    try {
      final response = await _makeApiRequest(
        method: 'DELETE',
        endpoint: '/payments/v1/single-consents/$consentId',
      );
      // Check the success field based on _makeApiRequest DELETE handling
      return response['success'] == true;
    } catch (e) {
      debugPrint('Error revoking single consent: $e');
      // Consider if specific error types should be checked (e.g., 404 Not Found vs other errors)
      return false; // Assume failure on any exception
    }
  }

  /// Revoke an enduring consent
  Future<bool> revokeEnduringConsent(String consentId) async {
    debugPrint('Revoking BlinkPay enduring consent: $consentId');
    try {
      final response = await _makeApiRequest(
        method: 'DELETE',
        endpoint: '/payments/v1/enduring-consents/$consentId',
      );
      return response['success'] == true;
    } catch (e) {
      debugPrint('Error revoking enduring consent: $e');
      return false;
    }
  }

  /// Helper: Fetches consent data based on type.
  Future<Map<String, dynamic>> _fetchConsentData(
      String consentId, String type) async {
    if (type == 'single') {
      return await getSingleConsent(consentId);
    } else if (type == 'enduring') {
      return await getEnduringConsent(consentId);
    } else {
      throw Exception('Invalid consent type provided: $type');
    }
  }

  /// Helper: Finds the specific payment map within the consent data's payment list.
  Map<String, dynamic>? _findSpecificPayment(
      Map<String, dynamic> consentData, String paymentId) {
    final payments = consentData['payments'] as List<dynamic>?;
    if (payments == null || payments.isEmpty) {
      return null;
    }

    for (final payment in payments) {
      final currentId = payment['payment_id'] ?? payment['id'];
      if (currentId != null && currentId.toString() == paymentId) {
        return payment; // Found the payment
      }
    }
    return null; // Payment not found in the list
  }

  /// Check if a specific payment has been completed by polling until it reaches a terminal status
  /// Returns true if completed, false otherwise (rejected, timed out, error).
  /// If the check times out for a single consent, it attempts to revoke the consent.
  Future<bool> waitForPaymentCompletion(String consentId, String paymentId,
      {String type = 'single'}) async {
    debugPrint(
        'Waiting for payment $paymentId completion on consent $consentId (type: $type)');
    int attempts = 0;

    try {
      while (attempts < maxStatusChecks) {
        attempts++;
        debugPrint(
            'Checking payment status (attempt $attempts/$maxStatusChecks)');

        try {
          final consentData = await _fetchConsentData(consentId, type);
          final specificPayment = _findSpecificPayment(consentData, paymentId);

          if (specificPayment == null) {
            debugPrint(
                'Payment ID $paymentId not found yet (attempt $attempts).');
            await Future.delayed(checkInterval);
            continue; // Continue polling
          }

          final status = specificPayment['status'] as String?;
          final foundPaymentId =
              specificPayment['payment_id'] ?? specificPayment['id'];
          debugPrint(
              'Found payment $foundPaymentId status: $status (attempt $attempts)');

          if (status == PaymentStatus.completed) {
            debugPrint('Payment $foundPaymentId completed successfully.');
            return true; // Success
          } else if (status == PaymentStatus.rejected) {
            debugPrint('Payment $foundPaymentId failed with status: $status.');
            return false; // Explicit failure
          }

          // Other non-terminal statuses - keep waiting
          await Future.delayed(checkInterval);

        } catch (e) {
          debugPrint('Error in status check attempt $attempts: $e');

          // Retry on transient errors
          if (_isRetryableError(e)) {
            if (attempts < maxStatusChecks) {
              debugPrint('Retryable error during payment verification, continuing...');
              await Future.delayed(checkInterval);
              continue;
            }
          }

          // Non-retryable error or retries exhausted
          return false;
        }
      } // End of while loop

      // --- Loop Finished (Timeout) ---
      debugPrint(
          'Payment check timed out after $maxStatusChecks attempts for payment $paymentId.');

      if (type == 'single') {
        debugPrint(
            'Attempting to revoke single consent $consentId due to timeout.');
        try {
          bool revoked = await revokeSingleConsent(consentId);
          debugPrint(
              'Single consent $consentId revocation attempt result: $revoked');
        } catch (e) {
          debugPrint(
              'Error revoking single consent $consentId after timeout: $e');
        }
      } else {
        debugPrint('Enduring consent $consentId not revoked on timeout.');
      }

      return false; // Failure due to timeout

    } catch (e) {
      debugPrint(
          'Critical error during payment status check for consent $consentId: $e');
      return false; // Failure due to critical error (e.g., initial consent fetch failed)
    }
  }
}