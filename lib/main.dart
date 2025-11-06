import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:timezone/data/latest.dart' as tz;

import './blinkpay_service.dart';
import './env.dart';
import './models/shopping_cart_model.dart';
import './handlers/deep_link_handler.dart';
import './managers/payment_manager.dart';
import './utils/log.dart';
import './widgets/product_card.dart';
import './widgets/payment_buttons.dart';
import './widgets/loading_overlay.dart';
import './widgets/status_indicator.dart';

/// Initialize the app: set up timezones and load environment variables
Future<void> main() async {
  // Initialise the timezone database.
  tz.initializeTimeZones();

  await dotenv.load(fileName: ".env");

  // Validate essential environment variables
  if (!Environment.isValid()) {
    Log.error("CRITICAL ERROR: Environment variables not configured.");
    runApp(const ErrorApp(
      message: 'Configuration Error',
      details: 'Please ensure BLINKPAY_CLIENT_ID and BLINKPAY_CLIENT_SECRET are set in your .env file.',
    ));
    return;
  }

  runApp(const BlinkPayApp());
}

/// Error application widget for configuration issues
class ErrorApp extends StatelessWidget {
  final String message;
  final String details;

  const ErrorApp({
    super.key,
    required this.message,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BlinkPay Demo - Error',
      home: Scaffold(
        backgroundColor: const Color(0xFF1a273a),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.red,
                  size: 80,
                ),
                const SizedBox(height: 24),
                Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  details,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Main application widget defining the theme and home screen
class BlinkPayApp extends StatelessWidget {
  const BlinkPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BlinkPay Demo',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1a273a),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2a49f4),
          primary: const Color(0xFF2a49f4),
          onPrimary: Colors.white,
          surface: const Color(0xFF233994),
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2a49f4),
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00187d),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Colors.black87,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const BlinkPayDemo(),
    );
  }
}

/// Main demo screen for BlinkPay integration
class BlinkPayDemo extends StatefulWidget {
  const BlinkPayDemo({super.key});

  @override
  State<BlinkPayDemo> createState() => _BlinkPayDemoState();
}

class _BlinkPayDemoState extends State<BlinkPayDemo> with WidgetsBindingObserver {
  // Services and Models
  final BlinkPayService _blinkPayService = BlinkPayService();
  final ShoppingCartModel _cartModel = ShoppingCartModel();
  
  // Handlers and Managers
  late final DeepLinkHandler _deepLinkHandler;
  late final PaymentManager _paymentManager;
  
  // ====== LIFECYCLE METHODS ======
  
  @override
  void initState() {
    Log.info("BlinkPayDemoState initializing...");
    super.initState();
    
    // Instantiate PaymentManager, passing dependencies and UI callbacks
    _paymentManager = PaymentManager(
      blinkPayService: _blinkPayService,
      cartModel: _cartModel,
      showSnackBarCallback: _showSnackBar,
      handleApiErrorCallback: _handleApiError,
    );

    // Listen for payment state changes to handle URL launching
    _paymentManager.addListener(_onPaymentManagerChanged);

    // Initialize DeepLinkHandler with callbacks that use PaymentManager
    _deepLinkHandler = DeepLinkHandler(
      onLinkReceived: _handleDeepLinkData,
      onErrorOccurred: _handleDeepLinkError,
    );
    
    WidgetsBinding.instance.addObserver(this);
    _cartModel.addListener(_onCartModelChanged);
    Log.info("BlinkPayDemoState initialized.");
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Precache image via cart model
    precacheImage(const AssetImage('assets/lolly.webp'), context).then((_) {
      _cartModel.setImageLoaded(true);
    });
  }

  @override
  void dispose() {
    Log.info("BlinkPayDemoState disposing...");
    _deepLinkHandler.dispose();
    _cartModel.removeListener(_onCartModelChanged);
    _cartModel.dispose();
    _paymentManager.removeListener(_onPaymentManagerChanged);
    _paymentManager.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
    Log.info("BlinkPayDemoState disposed.");
  }
  
  /// Listener for cart model changes
  void _onCartModelChanged() {
    setState(() {});
  }

  /// Listener for payment manager changes
  void _onPaymentManagerChanged() {
    setState(() {});
  }

  /// Handles app lifecycle state changes (uses PaymentManager)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final consentId = _paymentManager.consentIdForVerification;
    final consentType = _paymentManager.consentTypeForVerification;
    final isDisabled = _paymentManager.isDisabled;
    final currentState = _paymentManager.state; // Get current state
    Log.info("App lifecycle state changed: $state");

    if (state == AppLifecycleState.resumed) {
      // Always mark the tab as potentially closed when resuming
      _paymentManager.setCustomTabClosed();

      // Check if we are *still* waiting for the redirect when the app resumes.
      // This handles cases where the deep link might not have triggered the check.
      if (currentState == PaymentState.awaitingRedirect &&
          consentId != null &&
          consentType != null) {
        Log.info(
            "Resuming app while still awaiting redirect for $consentId ($consentType). Triggering status check.");
        // Call checkConsentStatus. It has internal checks to prevent running multiple times
        // or in the wrong state.
        _paymentManager.checkConsentStatus(consentId, consentType);
      } else {
        Log.info(
            "Resuming app, but not in awaitingRedirect state (Current: $currentState) or no consent details. No action needed from lifecycle handler.");
        // DO NOTHING in the else block - avoid resetting state prematurely.
      }
    } else if (state == AppLifecycleState.paused) {
      if (consentId != null && isDisabled && !_paymentManager.isCustomTabOpen) {
        Log.info("Pausing app unexpectedly during active flow, resetting.");
        _showSnackBar(false, 'Payment process interrupted');
        _paymentManager.resetPaymentState();
      } else if (_paymentManager.isCustomTabOpen) {
        Log.info(
            'App pausing, likely due to custom tab being active. State maintained.');
      }
    }
  }

  /// Callback for DeepLinkHandler when a link is successfully parsed.
  void _handleDeepLinkData(
      String? consentIdFromUri, String? error, String? errorDescription) {
    Log.info(
        '[iOS Deep Link Check] _handleDeepLinkData received. URI Consent: $consentIdFromUri, Error: $error');
    Log.info(
        'Handling deep link data. Consent: $consentIdFromUri, Error: $error');
    if (!mounted) return;
    
    final currentConsent = _paymentManager.consentIdForVerification;
    final currentConsentType = _paymentManager.consentTypeForVerification;

    if (error != null) {
      String errorMessage = Uri.decodeComponent(errorDescription ?? error);
      Log.info('Deep link contained error: $errorMessage');
      _handleApiError('Payment failed: $errorMessage');
      _paymentManager.resetPaymentState();
    } else if (currentConsent != null &&
        currentConsentType != null &&
        (consentIdFromUri == null || consentIdFromUri == currentConsent)) {
      Log.info(
          'Deep link success/no consent ID. Checking status via manager for $currentConsent ($currentConsentType)...');
      _paymentManager.checkConsentStatus(currentConsent, currentConsentType);
    } else if (consentIdFromUri == null && error == null) {
      // Handle case where redirect happened without error but is missing the consent ID
      Log.error(
          'Redirect received successfully but missing required consent ID.');
      _showSnackBar(
          false, 'Payment failed: Invalid redirect received from bank.');
      _paymentManager.resetPaymentState();
    } else {
      Log.info(
          'Redirect received, but no active consent/type or ID mismatch. Resetting via manager. URI Consent: $consentIdFromUri, Current: $currentConsent ($currentConsentType)');
      _paymentManager.resetPaymentState();
    }
  }
  
  /// Callback for DeepLinkHandler when an error occurs in the stream.
  void _handleDeepLinkError(String errorMessage) {
    Log.error('Deep link listener error reported to State: $errorMessage');
    if (mounted) {
      _showSnackBar(false, 'Error processing redirect link.');
      _paymentManager.resetPaymentState();
    }
  }

  /// Internal implementation for launching URL, passed to PaymentManager
  Future<void> _launchUrlInternal(BuildContext context, String url) async {
    if (!mounted) {
      Log.info("Skipping _launchUrlInternal as widget is not mounted.");
      return;
    }
    final theme = Theme.of(context);
    final uri = Uri.parse(url);
    await custom_tabs.launchUrl(
      uri,
      customTabsOptions: custom_tabs.CustomTabsOptions(
        colorSchemes: custom_tabs.CustomTabsColorSchemes.defaults(
          toolbarColor: theme.colorScheme.surface,
        ),
        shareState: custom_tabs.CustomTabsShareState.off,
        urlBarHidingEnabled: true,
        showTitle: true,
        instantAppsEnabled: false,
        closeButton: custom_tabs.CustomTabsCloseButton(
          icon: custom_tabs.CustomTabsCloseButtonIcons.back,
        ),
        animations: custom_tabs.CustomTabsSystemAnimations.slideIn(),
      ),
      safariVCOptions: custom_tabs.SafariViewControllerOptions(
        preferredBarTintColor: theme.colorScheme.surface,
        preferredControlTintColor: theme.colorScheme.onSurface,
        barCollapsingEnabled: true,
        dismissButtonStyle:
            custom_tabs.SafariViewControllerDismissButtonStyle.close,
      ),
    );
  }

  // ====== UI HELPERS (Remain in State for now) ======
  // These are passed as callbacks to PaymentManager

  /// Displays snackbar message with success/failure styling
  void _showSnackBar(bool success, String message) {
    Log.info("Showing SnackBar: Success=$success, Message=$message");
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Handles API errors by displaying them in a snackbar
  void _handleApiError(String message) {
    Log.error('API Error reported to UI: $message');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  /// Handle payment button clicks and initiate payment flow
  Future<void> _handlePaymentButtonClick(String type) async {
    if (!mounted) return;

    // Get redirect URL from payment manager
    final redirectUrl = await _paymentManager.handleButtonClick(type);

    // If we got a redirect URL and still mounted, launch it
    if (redirectUrl != null && mounted) {
      final consentId = _paymentManager.consentIdForVerification;
      _paymentManager.markCustomTabOpen();

      try {
        Log.info('Launching Redirect URL: $redirectUrl for consent $consentId');
        await _launchUrlInternal(context, redirectUrl);
      } catch (e, stacktrace) {
        Log.error('Error launching URL for consent $consentId', e, stacktrace);
        if (mounted) {
          _paymentManager.onLaunchError(consentId, e.toString());
        }
      }
    }
  }

  // ====== MAIN UI BUILD ======
  @override
  Widget build(BuildContext context) {
    // UI state derived from PaymentManager
    bool buttonsDisabled =
        _paymentManager.isLoading || _paymentManager.isDisabled;
    bool showLoadingOverlay = _paymentManager.isLoading;
    PaymentState currentState = _paymentManager.state;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('BlinkPay Demo'),
        actions: [
          Center(
            child: StatusIndicator(state: currentState),
          ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AbsorbPointer(
              absorbing: showLoadingOverlay, 
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'Shopping Cart',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                    
                  ProductCard(cartModel: _cartModel),
                  const SizedBox(height: 20),

                  PaymentButtons(
                    isDisabled: buttonsDisabled,
                    onButtonClick: (type) => _handlePaymentButtonClick(type),
                  ),
                ],
              ),
            ),
          ),
          LoadingOverlay(
            isLoading: showLoadingOverlay,
            message: currentState == PaymentState.verifying
                ? 'Checking payment status...'
                : 'Processing...',
          ),
        ],
      ),
    );
  }
}
