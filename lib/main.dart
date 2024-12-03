import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import './blinkpay_service.dart';
import './env.dart';

// List of external bank URLs that should open in external browser
const List<String> externalUrls = [
  'https://bank.westpac.co.nz',
  'https://links.anz.co.nz',
  'https://online.asb.co.nz'
];

void main() async {
  await dotenv.load(fileName: ".env");
  runApp(const MaterialApp(home: WebViewExample()));
}

class WebViewExample extends StatefulWidget {
  const WebViewExample({super.key});

  @override
  State<WebViewExample> createState() => _WebViewExampleState();
}

class _WebViewExampleState extends State<WebViewExample> {
  final BlinkPayService _blinkPayService = BlinkPayService();
  String? _currentPaymentId;

  bool _isInitiatingPayment = false;

  late final WebViewController _controller;
  late StreamSubscription _sub;

  bool _showWebView = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _setupWebView();
  }

  void _setupWebView() {
    final PlatformWebViewControllerCreationParams params =
        (WebViewPlatform.instance is WebKitWebViewPlatform)
            ? WebKitWebViewControllerCreationParams(
                allowsInlineMediaPlayback: true,
                mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
              )
            : const PlatformWebViewControllerCreationParams();

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) =>
              debugPrint('Loading progress: $progress'),
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) {
            setState(() => _isLoading = false);
            debugPrint('Page finished loading');
          },
          onWebResourceError: (error) {
            debugPrint('Web resource error: ${error.description}');
            setState(() => _isLoading = false);
            _handleApiError('Failed to load page: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            debugPrint('Navigating to: $url');

            // Handle redirect back to app
            if (url.startsWith(Environment.redirectUri)) {
              _handleWebViewClose();
              return NavigationDecision.prevent;
            }

            // Handle external bank URLs
            if (externalUrls
                .any((externalUrl) => url.startsWith(externalUrl))) {
              _handleExternalUrl(url);
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      );

    if (_controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  Future<void> _initiatePayment() async {
    if (_isInitiatingPayment) {
      debugPrint('Payment initiation already in progress');
      return;
    }

    _isInitiatingPayment = true;

    try {
      setState(() => _isLoading = true);
      debugPrint('Creating payment...'); 

      final payment = await _blinkPayService.createQuickPayment("0.01");
      _currentPaymentId = payment['quick_payment_id'];

      await _controller.clearCache();
      setState(() => _showWebView = true);
      await _controller.loadRequest(Uri.parse("about:blank"));
      await _controller.loadRequest(Uri.parse(payment['redirect_uri']));
    } catch (e) {
      _handleApiError('Failed to initiate payment: $e');
    } finally {
      setState(() => _isLoading = false);
      _isInitiatingPayment = false;
    }
  }

  Future<void> _handleExternalUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (Platform.isAndroid) {
        bool canLaunch = await canLaunchUrl(uri);
        debugPrint('Can launch URL? $canLaunch');

        if (!canLaunch) {
          debugPrint('No app can handle this URL, falling back to WebView');
          _loadUrlInWebView(url);
          return;
        }

        bool launched = await launchUrl(uri,
            mode: LaunchMode.externalNonBrowserApplication);

        if (!launched) {
          debugPrint('Launch failed, falling back to WebView');
          _loadUrlInWebView(url);
        }
      } else if (Platform.isIOS) {
        bool launched = await launchUrl(uri,
            mode: LaunchMode.externalNonBrowserApplication);

        if (!launched) {
          launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
          if (!launched) {
            throw Exception(
                'Failed to launch URL with in-app browser view: $uri');
          }
        }
      }
    } catch (e) {
      debugPrint('Error launching URL: $e');
      if (mounted) {
        _loadUrlInWebView(url);
      }
    }
  }

  void _loadUrlInWebView(String url) {
    _controller.loadRequest(Uri.parse(url)).catchError((error) {
      debugPrint('Error loading URL in WebView: $error');
      _handleApiError('Failed to load page');
    });
  }

  Future<void> _checkPaymentStatus() async {
    if (_currentPaymentId == null) {
      return;
    }

    _showSnackBar(true, 'Checking payment...');

    try {
      await _blinkPayService.waitForPaymentCompletion(_currentPaymentId!);
      _showSnackBar(true, 'Payment completed successfully');
    } catch (e) {
      if (e is PaymentCheckException) {
        _showSnackBar(false, e.toString());
      } else {
        _showSnackBar(false, 'Payment was not completed');
      }
    }
  }

  void _showSnackBar(bool success, String message) {
    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar(); // if any
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _handleApiError(String message) {
    debugPrint(message);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  void _handleWebViewClose() {
    setState(() {
      _showWebView = false;
    });
    _checkPaymentStatus();
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('BlinkPay Demo'),
        actions: _showWebView
            ? [
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 24,
                  onPressed: () {
                    _handleWebViewClose();
                  },
                ),
              ]
            : null,
      ),
      body: _showWebView
          ? Stack(
              key: const Key('webview_stack'),
              children: [
                WebViewWidget(controller: _controller),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator()),
              ],
            )
          : Center(
              child: ElevatedButton.icon(
                onPressed: _initiatePayment,
                icon: const Icon(Icons.shopping_cart),
                label: const Text('Pay with BlinkPay'),
              ),
            ),
    );
  }
}
