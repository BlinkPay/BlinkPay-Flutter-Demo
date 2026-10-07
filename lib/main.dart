import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;

import './blinkpay_service.dart';
import './env.dart';
import './models/payment_models.dart';
import './models/shopping_cart_model.dart';
import './handlers/deep_link_handler.dart';
import './managers/payment_manager.dart';
import './utils/log.dart';
import './widgets/product_card.dart';
import './widgets/payment_buttons.dart';
import './widgets/payment_status_panel.dart';
import './widgets/loading_overlay.dart';

/// Validates configuration and starts the app.
Future<void> main() async {
  // Validate that required --dart-define values are present
  if (!Environment.isValid()) {
    Log.error("CRITICAL ERROR: Backend configuration not set.");
    runApp(const ErrorApp(
      message: 'Configuration Error',
      details: 'Please provide BACKEND_URL and APP_API_KEY via --dart-define.\n\n'
          'Example:\n'
          'flutter run --dart-define=BACKEND_URL=http://10.0.2.2:4567 '
          '--dart-define=APP_API_KEY=your_key\n\n'
          'Or use the run.sh script which sets these automatically.',
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
    
    _paymentManager = PaymentManager(
      blinkPayService: _blinkPayService,
      cartModel: _cartModel,
    );
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

  bool _imagePrecached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_imagePrecached) {
      _imagePrecached = true;
      precacheImage(const AssetImage('assets/lolly.webp'), context).then((_) {
        if (mounted) _cartModel.setImageLoaded(true);
      });
    }
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

  /// Coming back to the foreground (for example from the banking app) is a
  /// reason to check the payment again, never to give up on it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Log.info("App lifecycle state changed: $state");
    if (state == AppLifecycleState.resumed) {
      _paymentManager.onAppResumed();
    }
  }

  /// Called when the gateway sends the customer back to the app.
  void _handleDeepLinkData(
      String? consentIdFromUri, String? error, String? errorDescription) {
    Log.info('Return link: consent $consentIdFromUri, error $error');
    if (!mounted) return;
    _paymentManager.onReturnFromBank(consentId: consentIdFromUri);
  }

  /// A broken return link changes nothing: the payment is still checked.
  void _handleDeepLinkError(String errorMessage) {
    Log.error('Deep link listener error: $errorMessage');
  }

  /// Opens [url] in Chrome Custom Tabs (Android) or SFSafariViewController
  /// (iOS) rather than a WebView: the app cannot read or alter the bank's
  /// pages, and the customer gets the system browser's cookies and password
  /// autofill. iframes do not work at all (bank CSPs block them).
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

  /// Starts a payment and opens the gateway in the in-app browser.
  Future<void> _handlePaymentButtonClick(ConsentType type) async {
    final redirectUrl = await _paymentManager.start(type);
    if (redirectUrl == null || !mounted) return;

    try {
      Log.info('Opening the gateway for consent ${_paymentManager.consentId}');
      await _launchUrlInternal(context, redirectUrl);
      _paymentManager.onBrowserOpened();
    } catch (e) {
      _paymentManager.onBrowserFailed(e);
    }
  }

  // ====== MAIN UI BUILD ======
  @override
  Widget build(BuildContext context) {
    final buttonsDisabled = _paymentManager.isBusy ||
        _paymentManager.state == PaymentState.unresolved;
    final showLoadingOverlay = _paymentManager.state == PaymentState.starting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BlinkPay Demo'),
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
                    onButtonClick: _handlePaymentButtonClick,
                  ),
                  const SizedBox(height: 20),

                  PaymentStatusPanel(
                    state: _paymentManager.state,
                    message: _paymentManager.message,
                    canCancel: _paymentManager.canCancel,
                    onCancel: _paymentManager.cancel,
                    onDismiss: _paymentManager.dismiss,
                  ),
                ],
              ),
            ),
          ),
          LoadingOverlay(isLoading: showLoadingOverlay),
        ],
      ),
    );
  }
}
