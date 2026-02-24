import 'dart:async';
import 'package:flutter/material.dart'; // For ChangeNotifier, BuildContext

import '../blinkpay_service.dart';
import '../models/shopping_cart_model.dart';
import '../constants.dart';
// Utils
import '../utils/log.dart';
import '../utils/payment_error_helper.dart';

/// Sentinel value meaning "don't change this field" in [PaymentManager._updateState].
const String _unchanged = '\x00_UNCHANGED';

/// Represents the different stages of the payment process.
enum PaymentState {
  idle, // Initial state, ready for interaction
  creatingConsent, // API call to create consent in progress
  awaitingRedirect, // Consent created, waiting for user interaction via custom tab/browser
  verifying, // User returned, checking consent status and processing payment
  error, // An error occurred at some stage
}

/// Manages the state and logic for the entire payment flow.
class PaymentManager extends ChangeNotifier {
  final BlinkPayService _blinkPayService;
  final ShoppingCartModel _cartModel;

  // Callbacks for UI interactions (passed from the screen)
  // Note: BuildContext is obtained at call-time to avoid stale context issues
  final Function(bool success, String message) showSnackBarCallback;
  final Function(String message) handleApiErrorCallback;

  // Internal State using Enum
  PaymentState _state = PaymentState.idle;
  String?
      _consentIdForVerification; // ID of the consent being actively processed
  String?
      _consentTypeForVerification; // Type ('single' or 'enduring') of the active consent
  String?
      _errorDetails; // Stores the user-friendly error message if state is error
  bool _isCustomTabOpen = false; // Track if the custom tab is currently open

  // Getters for UI
  PaymentState get state => _state;
  bool get isLoading =>
      _state == PaymentState.creatingConsent ||
      _state == PaymentState.verifying;
  bool get isDisabled =>
      _state == PaymentState.creatingConsent ||
      _state == PaymentState.awaitingRedirect ||
      _state == PaymentState.verifying;
  String? get errorDetails => _errorDetails;
  String? get consentIdForVerification => _consentIdForVerification;
  String? get consentTypeForVerification => _consentTypeForVerification;
  bool get isCustomTabOpen => _isCustomTabOpen;

  PaymentManager({
    required BlinkPayService blinkPayService,
    required ShoppingCartModel cartModel,
    required this.showSnackBarCallback,
    required this.handleApiErrorCallback,
  })  : _blinkPayService = blinkPayService,
        _cartModel = cartModel;

  // ====== PAYMENT LOGIC METHODS ======

  /// Updates the state and notifies listeners.
  ///
  /// Pass [_unchanged] (the default) to preserve the current value of a field.
  /// Pass `null` to explicitly clear a field.
  void _updateState(PaymentState newState,
      {String? consentId = _unchanged,
      String? consentType = _unchanged,
      String? error = _unchanged,
      bool? isCustomTabOpen}) {
    bool changed = false;

    if (_state != newState) {
      _state = newState;
      changed = true;
      Log.info('Payment State changed to: $newState');
    }

    // Update consent ID (skip if sentinel)
    if (consentId != _unchanged && consentId != _consentIdForVerification) {
      _consentIdForVerification = consentId;
      changed = true;
    }

    // Update consent type (skip if sentinel)
    if (consentType != _unchanged &&
        consentType != _consentTypeForVerification) {
      _consentTypeForVerification = consentType;
      changed = true;
    }

    // Update error (skip if sentinel)
    if (error != _unchanged && error != _errorDetails) {
      _errorDetails = error;
      changed = true;
    }

    if (isCustomTabOpen != null && _isCustomTabOpen != isCustomTabOpen) {
      _isCustomTabOpen = isCustomTabOpen;
      changed = true;
    }

    // Clear error details if not in error state
    if (_state != PaymentState.error && _errorDetails != null) {
      _errorDetails = null;
      changed = true;
    }
    // Clear consent ID and type if idle
    if (_state == PaymentState.idle &&
        (_consentIdForVerification != null ||
            _consentTypeForVerification != null)) {
      _consentIdForVerification = null;
      _consentTypeForVerification = null;
      changed = true;
    }

    if (changed) {
      notifyListeners();
    }
  }

  /// Resets payment state to idle and notifies listeners.
  void resetPaymentState() {
    _updateState(PaymentState.idle,
        consentId: null,
        consentType: null,
        error: null,
        isCustomTabOpen: false);
    _cartModel.reset(); // Reset the cart via the model
    Log.info('State reset to idle');
  }

  /// Explicitly marks the custom tab as closed.
  void setCustomTabClosed() {
    if (_isCustomTabOpen) {
      Log.info('Marking custom tab as closed.');
      _isCustomTabOpen = false;
      notifyListeners();
    }
  }

  /// Checks the status of a payment consent after user returns to the app.
  /// This typically happens after the deep link is received or the app is resumed.
  Future<void> checkConsentStatus(String consentId, String flowType) async {
    // Don't check if we are not in the awaiting redirect state for this specific consent
    if (_state != PaymentState.awaitingRedirect ||
        _consentIdForVerification != consentId) {
      Log.info(
          'Skipping checkConsentStatus: State is $_state or consent ID mismatch ($_consentIdForVerification vs $consentId)');
      return;
    }

    Log.info('Checking consent status for ID: $consentId, type: $flowType');
    _updateState(PaymentState.verifying, consentId: consentId);

    try {
      // Step 1: Get Consent Details from BlinkPay
      Log.info('Fetching consent details...');
      Map<String, dynamic> consentData;
      if (flowType == 'single') {
        consentData = await _blinkPayService.getSingleConsent(consentId);
      } else if (flowType == 'enduring') {
        consentData = await _blinkPayService.getEnduringConsent(consentId);
      } else {
        throw Exception('Unknown payment type: $flowType');
      }

      Log.info('<<< Raw Consent Data Received: $consentData');

      // Check if the state changed while fetching
      if (_consentIdForVerification != consentId) {
        Log.info(
            'Consent ID changed during fetch (Expected: $consentId, Current: $_consentIdForVerification). Aborting status check.');
        return;
      }

      final status = consentData['status'];
      Log.info('Consent status received: $status');

      // Step 2: Check if Consent is Authorised
      if (status == ConsentStatus.authorised) {
        Log.info('Consent authorised. Proceeding to create payment...');

        // Step 3: Create Payment Request with BlinkPay
        String paymentId;
        try {
          Log.info('Creating payment...');
          if (flowType == 'enduring') {
            final pcr = PCR(
              particulars: AppConstants.productName,
              code: AppConstants.pcrCode,
              reference: AppConstants.pcrReference,
            );
            paymentId = await _blinkPayService.createPayment(consentId,
                pcr: pcr, amount: AppConstants.enduringAmount);
          } else {
            paymentId = await _blinkPayService.createPayment(consentId);
          }
          Log.info('<<< Payment creation initiated. Payment ID: $paymentId');

          if (_state != PaymentState.verifying ||
              _consentIdForVerification != consentId) {
            throw Exception('Payment context changed during payment creation.');
          }
        } catch (e) {
          Log.error('Failed to create payment', e);
          throw Exception('Failed to create payment: ${e.toString()}');
        }

        // Step 4: Verify Payment Completion by Polling BlinkPay
        Log.info('Waiting for payment ($paymentId) completion...');
        bool paymentSuccessful;
        try {
          paymentSuccessful = await _blinkPayService.waitForPaymentCompletion(
            consentId,
            paymentId,
            type: flowType,
          );
          Log.info(
              'Payment completion status for $paymentId: $paymentSuccessful');
        } catch (e) {
          Log.error('Error during payment completion wait', e);
          throw Exception('Error verifying payment status: ${e.toString()}');
        }

        // Double-check context hasn't changed
        if (_state != PaymentState.verifying ||
            _consentIdForVerification != consentId) {
          throw Exception(
              'Payment context changed during payment verification.');
        }

        if (!paymentSuccessful) {
          throw Exception(
              'Payment was not completed successfully or timed out');
        }

        // Step 5: Payment Success - Show Confirmation and Reset
        Log.info('Payment successful!');
        if (!_isCustomTabOpen) {
          showSnackBarCallback(true, 'Payment completed successfully!');
        }

        resetPaymentState(); // Final state reached, reset everything
      } else {
        // Handle cases where consent is not authorised (e.g., Pending, Declined)
        Log.info('Consent status was not Authorised: $status');

        // Attempt to revoke if status is not Authorised and not already in a terminal failed/revoked state
        if (status != ConsentStatus.rejected &&
            status != ConsentStatus.revoked &&
            status != ConsentStatus.gatewayTimeout) {
          Log.info(
              'Attempting to revoke consent $consentId due to non-authorised status ($status)');
          bool revoked;
          if (flowType == 'single') {
            revoked = await _blinkPayService.revokeSingleConsent(consentId);
          } else {
            revoked = await _blinkPayService.revokeEnduringConsent(consentId);
          }
          Log.info('Revocation status for $consentId: $revoked');
        }

        throw Exception('Consent not authorised. Status: $status');
      }
    } catch (e, stacktrace) {
      // Handle any errors during the status check process
      final rawErrorMsg = e.toString();
      Log.error('Payment check process error', e, stacktrace);

      // Only update state if we are still verifying *this* consent
      if (_state == PaymentState.verifying &&
          _consentIdForVerification == consentId) {
        final userFriendlyError =
            PaymentErrorHelper.getUserFriendlyMessage(rawErrorMsg);
        _updateState(PaymentState.error,
            error: userFriendlyError,
            consentId: consentId); // Keep consent ID for context if needed
        showSnackBarCallback(false, userFriendlyError);
      } else {
        Log.info(
            'Ignoring error for previous/changed payment operation (State: $_state, ID: $_consentIdForVerification).');
      }
    } finally {
      // Log.info('Entering finally block for checkConsentStatus. Current state: $_state, Consent ID: $_consentIdForVerification (Expected: $consentId)');
    }
  }

  /// Marks the custom tab as open when URL launch begins
  void markCustomTabOpen() {
    if (_state == PaymentState.awaitingRedirect) {
      _updateState(_state,
          consentId: _consentIdForVerification,
          consentType: _consentTypeForVerification,
          isCustomTabOpen: true);
    }
  }

  /// Handles error when URL launch fails
  void onLaunchError(String? consentId, String error) {
    Log.error('Error launching URL for consent $consentId: $error');
    _updateState(PaymentState.error,
        error: 'Failed to open payment page.',
        isCustomTabOpen: false,
        consentId: consentId,
        consentType: _consentTypeForVerification);
    handleApiErrorCallback('Failed to open payment page.');
  }

  /// Handles payment button click: updates state and starts submission.
  /// Returns the redirect URL if successful, null otherwise.
  Future<String?> handleButtonClick(String type) async {
    if (isLoading || isDisabled) {
      Log.info('Ignoring button click: Already processing (State: $_state)');
      return null;
    }
    Log.info('Button clicked: $type. Current State: $_state');

    // Capture old consent details before clearing state, so _submitPayment
    // can revoke the previous consent if one exists.
    final oldConsentId = _consentIdForVerification;
    final oldConsentType = _consentTypeForVerification;

    _updateState(PaymentState.creatingConsent,
        consentId: null, consentType: null, error: null);
    return await _submitPayment(type, oldConsentId, oldConsentType);
  }

  /// Submits the initial request to BlinkPay to create a payment consent.
  /// Returns the redirect URL if successful, null otherwise.
  Future<String?> _submitPayment(
      String buttonType, String? oldConsentId, String? oldConsentType) async {
    // Revoke any existing consent before starting a new one
    if (oldConsentId != null && oldConsentType != null) {
      Log.info(
          'Revoking previous consent ($oldConsentId - $oldConsentType) before starting new one.');
      bool revoked;
      if (oldConsentType == 'single') {
        revoked = await _blinkPayService.revokeSingleConsent(oldConsentId);
      } else {
        revoked = await _blinkPayService.revokeEnduringConsent(oldConsentId);
      }
      Log.info('Previous consent revocation status: $revoked');
    }

    if (_state != PaymentState.creatingConsent) {
      Log.error(
          'Submit payment called in incorrect state: $_state. Expected creatingConsent.');
      return null; // Should not happen if handleButtonClick is used
    }

    final total = _cartModel.total;
    final totalAmount = total.toStringAsFixed(2);
    // Enduring consent needs a max amount (e.g. double the initial)
    // Single consent uses the exact amount.
    final enduringMaxAmount = (total * 2).toStringAsFixed(2);
    if (buttonType == 'single') {
      Log.info('Initiating single consent for amount: $totalAmount');
    } else {
      Log.info(
          'Initiating enduring consent with max amount: $enduringMaxAmount');
    }

    try {
      // Step 1: Create Consent Request via BlinkPayService
      Log.info('Creating consent request...');
      Map<String, dynamic> paymentResponse;
      final pcr = PCR(
        particulars: AppConstants.productName,
        code: AppConstants.pcrCode,
        reference: AppConstants.pcrReference,
      );

      if (buttonType == 'single') {
        paymentResponse =
            await _blinkPayService.createSingleConsent(pcr, totalAmount);
      } else if (buttonType == 'enduring') {
        // Use enduring amount from constants if defined, else calculated max
        final double constantEnduringAmount =
            double.tryParse(AppConstants.enduringAmount) ?? 0.0;
        final amountForEnduring = constantEnduringAmount > 0
            ? constantEnduringAmount.toStringAsFixed(2)
            : enduringMaxAmount;
        paymentResponse = await _blinkPayService.createEnduringConsent(
            amountForEnduring, amountForEnduring);
      } else {
        throw Exception('Unknown payment type selected: $buttonType');
      }

      final String? consentId = paymentResponse['consent_id'];
      final String? redirectUri = paymentResponse['redirect_uri'];

      if (consentId == null || consentId.isEmpty) {
        throw Exception('No valid consent ID returned from consent creation');
      }
      if (redirectUri == null || redirectUri.isEmpty) {
        throw Exception('No redirect URI provided by consent creation');
      }
      Log.info('Consent created ($consentId)');

      // Double-check the flow wasn't cancelled while waiting for the API response
      if (_state != PaymentState.creatingConsent) {
        Log.info("Flow interrupted before redirect; aborting submitPayment.");
        // If consent was created but flow cancelled, maybe try to revoke?
        // For simplicity, just log and exit.
        return null;
      }

      // Step 2: Update State - URL will be launched by caller
      _updateState(PaymentState.awaitingRedirect,
          consentId: consentId, consentType: buttonType); // Store type
      Log.info('Redirect URI ready for launch');
      return redirectUri; // Return URL for caller to launch
    } catch (e, stacktrace) {
      // Handle errors during consent creation
      final rawErrorMsg = e.toString();
      Log.error('Error initiating consent', e, stacktrace);
      if (_state == PaymentState.creatingConsent) {
        // Check if still in the creation phase
        final userFriendlyError =
            PaymentErrorHelper.getUserFriendlyMessage(rawErrorMsg);
        _updateState(PaymentState.error,
            error: userFriendlyError, consentId: null);
        showSnackBarCallback(false, userFriendlyError);
      } else {
        Log.info(
            'Ignoring initiation error for different/old attempt (State: $_state).');
      }
      return null;
    }
  }
}
