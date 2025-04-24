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

/// Service for interacting with the BlinkPay API
class BlinkPayService {
  static const int maxStatusChecks = 10;
  static const Duration checkInterval = Duration(seconds: 1);

  // Authentication state
  String? _accessToken;
  DateTime? _tokenExpiry;
  
  /// Get a valid access token, refreshing if necessary
  Future<String> _getToken() async {
    try {
      // Use existing token if valid
      if (_accessToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
        return _accessToken!;
      }

      // Request new token
      final tokenUri = Uri.https(Environment.blinkPayApiUrl, '/oauth2/token');
      debugPrint('Getting new BlinkPay access token');

      final response = await http.post(
        tokenUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': Environment.clientId,
          'client_secret': Environment.clientSecret,
          'grant_type': 'client_credentials'
        }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        _tokenExpiry = DateTime.now().add(Duration(seconds: data['expires_in']));
        return _accessToken!;
      }

      throw Exception('Failed to get token: ${response.statusCode}');
    } catch (e) {
      debugPrint('Error getting token: $e');
      rethrow;
    }
  }

  /// Make an authenticated API request with error handling
  Future<Map<String, dynamic>> _makeApiRequest({
    required String method,
    required String endpoint,
    Map<String, dynamic>? body,
  }) async {
    try {
      final token = await _getToken();
      final url = 'https://${Environment.blinkPayApiUrl}$endpoint';

      http.Response response;

      switch (method.toUpperCase()) {
        case 'GET':
          response = await http.get(
            Uri.parse(url),
            headers: {'Authorization': 'Bearer $token'},
          );
          break;
        case 'POST':
          response = await http.post(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          );
          break;
        case 'DELETE':
          response = await http.delete(
            Uri.parse(url),
            headers: {'Authorization': 'Bearer $token'},
          );
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
      throw Exception(
          'API request failed: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('API error ($method $endpoint): $e');
      rethrow;
    }
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
          // Consider if specific errors should allow retries vs immediate failure
          return false; // Fail on error during polling attempt
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