import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:app_links/app_links.dart';

import './blinkpay_service.dart';
import './env.dart';

void main() async {
  await dotenv.load(fileName: ".env");
  runApp(const BlinkPayApp());
}

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

class BlinkPayDemo extends StatefulWidget {
  const BlinkPayDemo({super.key});

  @override
  State<BlinkPayDemo> createState() => _BlinkPayDemoState();
}

class _BlinkPayDemoState extends State<BlinkPayDemo> {
  final BlinkPayService _blinkPayService = BlinkPayService();

  String? _currentPaymentId;
  bool _isInitiatingPayment = false;
  bool _isLoading = false;
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _initDeepLinkListener();
  }

  void _initDeepLinkListener() {
    _appLinks = AppLinks();
    _linkSub = _appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null && uri.toString().startsWith(Environment.redirectUri)) {
        debugPrint('Received redirect: $uri');
        _checkPaymentStatus();
      }
    }, onError: (err) {
      debugPrint('Deep link error: $err');
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  Future<void> _initiatePayment() async {
    if (_isInitiatingPayment) return;
    _isInitiatingPayment = true;

    try {
      setState(() => _isLoading = true);
      debugPrint('Creating payment...');

      final PCR pcr = PCR(
        particulars: 'TestPayment',
        code: 'CODE001',
        reference: 'REF001',
      );
      const String amount = '0.01';

      final payment = await _blinkPayService.createQuickPayment(pcr, amount);
      _currentPaymentId = payment['quick_payment_id'];
      final String redirectUri = payment['redirect_uri'];

      await _launchUrl(context, redirectUri);
    } catch (e) {
      _handleApiError('Failed to initiate payment: $e');
    } finally {
      setState(() => _isLoading = false);
      _isInitiatingPayment = false;
    }
  }

  Future<void> _launchUrl(BuildContext context, String url) async {
    final theme = Theme.of(context);
    final uri = Uri.parse(url);

    try {
      await custom_tabs.launchUrl(
        uri,
        customTabsOptions: custom_tabs.CustomTabsOptions(
          colorSchemes: custom_tabs.CustomTabsColorSchemes.defaults(
            toolbarColor: theme.colorScheme.surface,
          ),
          shareState: custom_tabs.CustomTabsShareState.on,
          urlBarHidingEnabled: true,
          showTitle: true,
          closeButton: custom_tabs.CustomTabsCloseButton(
            icon: custom_tabs.CustomTabsCloseButtonIcons.back,
          ),
        ),
        safariVCOptions: custom_tabs.SafariViewControllerOptions(
          preferredBarTintColor: theme.colorScheme.surface,
          preferredControlTintColor: theme.colorScheme.onSurface,
          barCollapsingEnabled: true,
          dismissButtonStyle:
          custom_tabs.SafariViewControllerDismissButtonStyle.close,
        ),
      );
    } catch (e) {
      _handleApiError('Error launching browser: $e');
    }
  }

  Future<void> _checkPaymentStatus() async {
    if (_currentPaymentId == null) return;

    _showSnackBar(true, 'Checking payment...');
    try {
      await _blinkPayService.waitForPaymentCompletion(_currentPaymentId!);
      _showSnackBar(true, 'Payment completed successfully');
    } catch (e) {
      _showSnackBar(false,
          e is PaymentCheckException ? e.toString() : 'Payment was not completed');
    }
  }

  void _showSnackBar(bool success, String message) {
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

  void _handleApiError(String message) {
    debugPrint(message);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BlinkPay Demo')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF233994),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _isLoading
              ? const CircularProgressIndicator()
              : ElevatedButton.icon(
            onPressed: _initiatePayment,
            icon: const Icon(Icons.shopping_cart),
            label: const Text('Pay with BlinkPay'),
          ),
        ),
      ),
    );
  }
}
