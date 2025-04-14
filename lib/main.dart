import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:timezone/data/latest.dart' as tz;

import './blinkpay_service.dart';
import './env.dart';

Future<void> main() async {
  // Initialise the timezone database.
  tz.initializeTimeZones();

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

class _BlinkPayDemoState extends State<BlinkPayDemo> with WidgetsBindingObserver {
  final BlinkPayService _blinkPayService = BlinkPayService();

  // consent state variables.
  String? _currentConsentId;
  bool _isLoading = false;
  bool _disabled = false;
  String? _clickedButton; // 'single' for PayNow, 'enduring' for AutoPay, 'xero' for Invoice
  String? _errorResponse;

  // shopping cart variables.
  bool _imageLoaded = false;
  int _quantity = 1;
  final double _unitPrice = double.tryParse(Environment.unitPrice) ?? 1.00;
  late final TextEditingController _quantityController;

  // deep linking.
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _quantityController = TextEditingController(text: '$_quantity');
    _initDeepLinkListener();

    // Register this widget as an observer to app lifecycle changes.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Precache the image after inherited widgets are available.
    precacheImage(const AssetImage('assets/lolly.webp'), context).then((_) {
      setState(() {
        _imageLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _quantityController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Listen for app lifecycle changes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resetPaymentState();
    }
  }

  /// Resets payment button state and quantity when returning to the app.
  void _resetPaymentState() {
    setState(() {
      _disabled = false;
      _clickedButton = null;
      _quantity = 1;
      _quantityController.text = '$_quantity';
      _errorResponse = null;
    });
  }

  void _initDeepLinkListener() {
    _appLinks = AppLinks();
    _linkSub = _appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null && uri.toString().startsWith(Environment.redirectUri)) {
        debugPrint('Received redirect: $uri');
        // Check if an error parameter is present.
        final error = uri.queryParameters["error"];
        if (error != null && error.isNotEmpty) {
          // Handle the error; update your UI / state accordingly.
          _handleApiError(Uri.decodeComponent(error));
        } else {
          // No error parameter, proceed with checking the payment status.
          _checkConsentStatus();
        }
      }
    }, onError: (err) {
      debugPrint('Deep link error: $err');
    });
  }

  Future<void> _checkConsentStatus() async {
    if (_currentConsentId == null) {
      return;
    }

    // Capture the current clicked button value.
    final String? clickedType = _clickedButton;

    _showSnackBar(true, 'Checking consent...');

    try {
      if (clickedType == 'single') {
        // For PayNow: fetch single consent details.
        final consentData = await _blinkPayService.getSingleConsent(_currentConsentId!);
        final status = consentData['status'];
        debugPrint('Single consent status: $status');

        if (status == Status.authorised) {
          debugPrint('Single consent authorised, creating payment');
          await _blinkPayService.createPayment(_currentConsentId!);
        } else {
          throw PaymentCheckException('Single consent not authorised. Status: $status');
        }
      } else if (clickedType == 'enduring') {
        // For AutoPay: fetch enduring consent details.
        final consentData = await _blinkPayService.getEnduringConsent(_currentConsentId!);
        final status = consentData['status'];
        final randomCode = _generateRandomString(4);
        debugPrint('Enduring consent status: $status');

        if (status == Status.authorised) {
          debugPrint('Enduring consent authorised, creating payment');
          final pcr = PCR(
            particulars: 'Red Heart Lollipop',
            code: 'code-$randomCode',
            reference: 'REF001',
          );
          final fortnightlyAmount = '0.10';
          await _blinkPayService.createPayment(_currentConsentId!, pcr: pcr,
              amount: fortnightlyAmount);
        } else {
          throw PaymentCheckException('Enduring consent not authorised. Status: $status');
        }
      } else {
        await _blinkPayService.waitForPaymentCompletion(_currentConsentId!);
      }

      _showSnackBar(true, 'Payment completed successfully');

      // After a successful payment, fetch the final details.
      Map<String, dynamic> finalData;
      if (clickedType == 'single') {
        finalData = await _blinkPayService.getSingleConsent(_currentConsentId!);
      } else if (clickedType == 'enduring') {
        finalData = await _blinkPayService.getEnduringConsent(_currentConsentId!);
      } else {
        // Default case: assume quick payment.
        finalData = await _blinkPayService.getQuickPayment(_currentConsentId!);
      }

      // Display the final details in a popup.
      _showPaymentDetailsPopup(finalData);
    } catch (e) {
      _showSnackBar(false,
          e is PaymentCheckException ? e.toString() : 'Payment was not completed');
    }
  }

  /// Recursively formats JSON data (Map or List) into a multi-line string with indentation.
  String _formatJson(dynamic data, {int indent = 0}) {
    final indentStr = ' ' * indent;
    if (data is Map) {
      return data.entries.map((entry) {
        final key = entry.key;
        final value = entry.value;
        String formattedValue;
        if (value is Map || value is List) {
          formattedValue = '\n${_formatJson(value, indent: indent + 2)}';
        } else {
          formattedValue = value.toString();
        }
        return '$indentStr$key: $formattedValue';
      }).join('\n');
    } else if (data is List) {
      return data
          .map((item) => _formatJson(item, indent: indent))
          .join('\n');
    } else {
      return data.toString();
    }
  }

  /// Displays a popup dialog with payment/consent details using a black font colour.
  void _showPaymentDetailsPopup(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text(
            'Payment Details',
            style: TextStyle(color: Colors.black),
          ),
          content: SingleChildScrollView(
            child: Text(
              _formatJson(data, indent: 0),
              style: const TextStyle(fontSize: 14, color: Colors.black),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        );
      },
    );
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

  /// Generates a random alphanumeric string of [length].
  String _generateRandomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
        length, (index) => chars[Random().nextInt(chars.length)]).join();
  }

  /// Computes total cost (subtotal plus fee).
  /// Fee is calculated as the minimum of (subtotal × 0.0095) and 3.
  double _calculateTotal() {
    final subtotal = _unitPrice * _quantity;
    final fee = min(subtotal * 0.0095, 3);
    return subtotal + fee;
  }

  /// Changes the quantity by [change] while ensuring a minimum of 1.
  void _changeQuantity(int change) {
    setState(() {
      _quantity = max(1, _quantity + change);
      _quantityController.text = _quantity.toString();
    });
  }

  /// Called when one of the payment buttons is tapped.
  void _handleButtonClick(String type) {
    if (_disabled) return;
    setState(() {
      _clickedButton = type;
      _disabled = true;
    });
    _submitPayment();
  }

  /// Submits the payment using BlinkPayService based on the button pressed.
  Future<void> _submitPayment() async {
    final buttonValue = _clickedButton;
    final randomCode = _generateRandomString(4);
    final total = _calculateTotal();
    final totalAmount = total.toStringAsFixed(2);
    final maxAmountPeriod = (total * 2).toStringAsFixed(2);
    final maxAmountPayment = (total * 2).toStringAsFixed(2);

    setState(() {
      _isLoading = true;
      _errorResponse = null;
    });

    try {
      Map<String, dynamic> paymentResponse;

      // Create a PCR instance.
      final pcr = PCR(
        particulars: 'Red Heart Lollipop',
        code: 'code-$randomCode',
        reference: 'REF001',
      );

      // Determine the payment flow type.
      if (buttonValue == 'single') {
        paymentResponse =
        await _blinkPayService.createSingleConsent(pcr, totalAmount);
      } else if (buttonValue == 'enduring') {
        paymentResponse =
        await _blinkPayService.createEnduringConsent(maxAmountPeriod, maxAmountPayment);
      } else if (buttonValue == 'xero') {
        paymentResponse =
        await _blinkPayService.createQuickPayment(pcr, totalAmount);
      } else {
        throw Exception('Unknown payment type');
      }

      _currentConsentId = paymentResponse['quick_payment_id'] ??
          paymentResponse['consent_id'];
      final String redirectUri = paymentResponse['redirect_uri'];

      // Launch the browser to complete payment.
      await _launchUrl(context, redirectUri);
    } catch (error) {
      setState(() {
        _errorResponse = error.toString();
        _disabled = false;
      });
      _handleApiError('Failed to initiate payment: $error');
    }

    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BlinkPay Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Shopping Cart Title.
            const Text(
              'Shopping Cart',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            // Product Card.
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // Row for image and product details.
                    Row(
                      children: [
                        // Product image.
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.grey[200],
                          ),
                          clipBehavior: Clip.hardEdge,
                          child: _imageLoaded
                              ? Image.asset(
                            'assets/lolly.webp',
                            fit: BoxFit.cover,
                          )
                              : const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Product details.
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Red Heart Lollipop, unwrapped',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Colors.black),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '\$${_unitPrice.toStringAsFixed(2)} each',
                                style: const TextStyle(
                                  color: Colors.black,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Quantity controls.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 60,
                          child: TextField(
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            controller: _quantityController,
                            style: const TextStyle(color: Colors.black),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 8),
                            ),
                            onChanged: (value) {
                              final int? newQty = int.tryParse(value);
                              if (newQty != null && newQty > 0) {
                                setState(() {
                                  _quantity = newQty;
                                });
                              }
                            },
                          ),
                        ),
                        IconButton(
                          onPressed: () => _changeQuantity(-1),
                          icon: const Icon(Icons.remove),
                        ),
                        IconButton(
                          onPressed: () => _changeQuantity(1),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Display the calculated total.
                    Text(
                      'Total: \$${_calculateTotal().toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Payment buttons or a loading indicator.
            _isLoading
                ? const CircularProgressIndicator()
                : Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: _disabled
                      ? null
                      : () => _handleButtonClick('single'),
                  icon: const Icon(Icons.shopping_cart),
                  label: const Text('PayNow'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: _disabled
                      ? null
                      : () => _handleButtonClick('enduring'),
                  icon: const Icon(Icons.shopping_cart),
                  label: const Text('AutoPay'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: _disabled
                      ? null
                      : () => _handleButtonClick('xero'),
                  icon: const Icon(Icons.shopping_cart),
                  label: const Text('QuickPayment'),
                ),
              ],
            ),
            if (_errorResponse != null) ...[
              const SizedBox(height: 20),
              Text(
                'Error: $_errorResponse',
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
