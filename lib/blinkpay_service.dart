import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import './env.dart';

class Status {
  static const String completed = 'AcceptedSettlementCompleted';
  static const String rejected = 'Rejected';
  static const String revoked = 'Revoked';
  static const String pending = 'Pending';
  static const String inProcess = 'AcceptedSettlementInProcess';
  static const String gatewayTimeout = 'GatewayTimeout';
  static const String gatewayAwaitingSubmission = 'GatewayAwaitingSubmission';
  static const String authorised = 'Authorised';
  static const String awaitingAuthorisation = 'AwaitingAuthorisation';
}

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

  String get truncatedParticulars => particulars.substring(0, particulars.length.clamp(0, 12));
  String? get truncatedCode => code?.substring(0, code!.length.clamp(0, 12));
  String? get truncatedReference => reference?.substring(0, reference!.length.clamp(0, 12));
}

class PaymentCheckException implements Exception {
  final String message;
  PaymentCheckException(this.message);

  @override
  String toString() => message;
}

class BlinkPayService {
  static const int maxStatusChecks = 10;
  static const Duration checkInterval = Duration(seconds: 1);

  String? _accessToken;
  DateTime? _tokenExpiry;
  
  Future<String> _getToken() async {
    try {
      if (_accessToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
        return _accessToken!;
      }

      final tokenUri = Uri.https(Environment.blinkPayApiUrl, '/oauth2/token');
      debugPrint('Getting new BlinkPay access token from: $tokenUri');

      final response = await http.post(
        tokenUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': Environment.clientId,
          'client_secret': Environment.clientSecret,
          'grant_type': 'client_credentials'
        }),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('Token request timed out');
          throw TimeoutException('Connection timed out');
        },
      );

      debugPrint('Token response status: ${response.statusCode}');
      debugPrint('Token response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        _tokenExpiry = DateTime.now().add(Duration(seconds: data['expires_in']));
        return _accessToken!;
      }

      debugPrint('Non-200 response received: ${response.statusCode}');
      debugPrint('Response body: ${response.body}');
      throw Exception('Failed to get token: ${response.statusCode}');
    } catch (e, stackTrace) {
      debugPrint('Error getting token: $e');
      debugPrint('Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createQuickPayment(PCR pcr, String amount) async {
    final token = await _getToken();
    debugPrint('Creating BlinkPay payment');
    final response = await http.post(
      Uri.parse('https://${Environment.blinkPayApiUrl}/payments/v1/quick-payments'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'type': 'single',
        'flow': {
          'detail': {
            'type': 'gateway',
            'redirect_uri': Environment.redirectUri,
          }
        },
        'pcr': {
          'particulars': pcr.truncatedParticulars,
          'reference': pcr.truncatedReference,
          'code': pcr.truncatedCode
        },
        'amount': {
          'total': amount,
          'currency': 'NZD'
        }
      }),
    );

    if (response.statusCode == 201) {
      return jsonDecode(response.body);
    }
    throw Exception('Failed to create payment: ${response.statusCode}');
  }


  Future<void> waitForPaymentCompletion(String quickPaymentId) async {
    int checkCount = 0;
    
    while (checkCount < maxStatusChecks) {
      checkCount++;
      debugPrint('Payment status check attempt $checkCount of $maxStatusChecks');

      try {
        final consentOrPaymentStatus = await getPaymentStatus(quickPaymentId);
        debugPrint('Status: $consentOrPaymentStatus');

        if (consentOrPaymentStatus == Status.completed) {
          return; // Payment successful
        } else if (consentOrPaymentStatus == Status.rejected || consentOrPaymentStatus == Status.revoked || consentOrPaymentStatus == Status.gatewayTimeout) {
          await _handleFailedPayment(quickPaymentId);
          throw PaymentCheckException('Payment was not completed');
        } else if (consentOrPaymentStatus == Status.gatewayAwaitingSubmission || consentOrPaymentStatus == Status.awaitingAuthorisation || consentOrPaymentStatus == Status.authorised) {
          bool wasRevoked = await _handleFailedPayment(quickPaymentId);
          if (!wasRevoked) {
            // The payment might have compelted, check the status again 
            continue;
          }
          throw PaymentCheckException('Payment was not submitted');
        }
        else {
          // Continue checking - still in progress
          await Future.delayed(checkInterval);
        } 
      } catch (e) {
        if (e is PaymentCheckException) {
          rethrow;
        }
        throw PaymentCheckException('Error checking payment status: $e');
      }
    }

    // If we get here, we've exceeded max checks
    await _handleFailedPayment(quickPaymentId);
    throw PaymentCheckException('Payment status check timed out after $maxStatusChecks attempts');
  }

  Future<bool> _handleFailedPayment(String quickPaymentId) async {
    try {
      return await revokePayment(quickPaymentId);
    } catch (e) {
      debugPrint('Error while revoking payment: $e');
      // We still want to throw the original error, so we don't rethrow this
      return false;
    }
  }

  Future<String> getPaymentStatus(String quickPaymentId) async {
    final token = await _getToken();
    final response = await http.get(
      Uri.parse('https://${Environment.blinkPayApiUrl}/payments/v1/quick-payments/$quickPaymentId'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['consent']['payments']?.isNotEmpty == true) {
        return data['consent']['payments'][0]['status'];
      }
      return data['consent']['status'];
    }
    throw Exception('Failed to get payment status: ${response.statusCode}');
  }

  Future<bool> revokePayment(String quickPaymentId) async {
    final token = await _getToken();
    final response = await http.delete(
      Uri.parse('https://${Environment.blinkPayApiUrl}/payments/v1/quick-payments/$quickPaymentId'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 409) {
      return true; // Ignore 409 as payment is already revoked
    }

    if (response.statusCode == 422) {
      return false; // A response code of 422 indicates the payment might have already completed
    }
    
    if (response.statusCode != 204) {
      throw Exception('Failed to revoke payment: ${response.statusCode}');
    }
    return true;
  }
}