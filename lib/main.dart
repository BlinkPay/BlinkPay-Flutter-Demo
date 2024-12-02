import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Configuration values and constants used throughout the app
class AppConfig {
  // BlinkPay URLs and endpoints
  static const String blinkPayUrl = 'https://acme-prod.blinkpay.co.nz';
  static const String apiUrl = 'debit.blinkpay.co.nz';
  static const String deepLinkUrl = 'blinkpay://test-app/return';

  // List of external bank URLs that should open in external browser
  static const List<String> externalUrls = [
    'https://bank.westpac.co.nz',
    'https://links.anz.co.nz',
    'https://online.asb.co.nz'
  ];
}

void main() => runApp(const MaterialApp(home: WebViewExample()));

class WebViewExample extends StatefulWidget {
  const WebViewExample({super.key});

  @override
  State<WebViewExample> createState() => _WebViewExampleState();
}

class _WebViewExampleState extends State<WebViewExample> {
  // Controllers and subscriptions
  late final WebViewController _controller;
  late AppLinks _appLinks;
  late StreamSubscription _sub;

  // State management flags
  bool _showWebView = false;
  bool _isLoading = true;
  bool _isHandlingInWebView = false;

  @override
  void initState() {
    super.initState();
    _setupDeepLinks();
    _setupWebView();
  }

  /// Setup deep link handling for bank redirects
  Future<void> _setupDeepLinks() async {
    _appLinks = AppLinks();
    _sub = _appLinks.uriLinkStream.listen((link) {
      _handleDeepLink(link);
    }, onError: (err) {
      debugPrint('Error handling deep link: $err');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error handling deep link: $err')),
        );
      }
    });
  }

  /// Configure WebView with security and platform-specific settings
  void _setupWebView() {
    // Handle platform-specific WebView params
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
            setState(() => _isLoading = false); // Ensure loading state is reset
            _handleApiError('Failed to load page: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            // If we're intentionally loading in WebView, allow navigation
            if (_isHandlingInWebView) {
              return NavigationDecision.navigate;
            }

            // Handle redirect URLs from BlinkPay
            if (url.startsWith('${AppConfig.blinkPayUrl}/redirect?cid=')) {
              _handleWebViewClose(url);
              return NavigationDecision.prevent;
            }

            // Handle external bank URLs
            if (AppConfig.externalUrls
                .any((externalUrl) => url.startsWith(externalUrl))) {
              _handleExternalUrl(url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    // Enable debugging for Android WebView in debug mode
    if (_controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  Future<void> _handleExternalUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      // Attempt to launch URL in external app
      bool launched =
          await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
      if (!launched) {
        // If launch fails, load in WebView
        launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        if (!launched) {
          throw Exception('Failed to launch URL with in-app browser view: $uri');
        }
      }
    } catch (e) {
      debugPrint('Error launching URL: $e');
      if (mounted) {
        _loadUrlInWebView(url);
      }
    }
  }

  /// Load URL in WebView with error handling
  void _loadUrlInWebView(String url) {
    _isHandlingInWebView = true; // Set flag before loading
    _controller.loadRequest(Uri.parse(url)).catchError((error) {
      debugPrint('Error loading URL in WebView: $error');
      _handleApiError('Failed to load page');
    });
  }

  /// Process incoming deep links from bank redirects
  void _handleDeepLink(Uri link) {
    if (!link.hasAbsolutePath || !Uri.parse(link.toString()).isAbsolute) {
      debugPrint('Invalid link received');
      return;
    }
    if (link.toString().startsWith(AppConfig.deepLinkUrl)) {
      _handleWebViewClose(link.toString());
      _sendParametersToApi(link.queryParameters);
    }
  }

  /// Send query parameters back to BlinkPay API after bank redirect
  Future<void> _sendParametersToApi(Map<String, String> parameters) async {
    try {
      final url = Uri.https(AppConfig.apiUrl, '/bank/1.0/return', parameters);
      final response = await http.get(url).timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('API request timed out'),
          );

      if (response.statusCode == 200) {
        debugPrint('Parameters sent successfully');
      } else {
        _handleApiError('Failed to send parameters: ${response.statusCode}');
      }
    } catch (e) {
      _handleApiError('Error sending parameters: $e');
    }
  }

  /// Handle and display API errors
  void _handleApiError(String message) {
    debugPrint(message);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  /// Handle WebView closure and display navigation URL
  void _handleWebViewClose(String navUrl) {
    setState(() {
      _showWebView = false;
    });
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Closing WebView'),
        content: Text('Navigation URL: ' + navUrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.green,
      appBar: AppBar(
        title: const Text('Acme Mobile App'),
        actions: _showWebView
            ? [
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 24,
                  onPressed: () {
                    setState(() => _showWebView = false);
                    // Reset WebView to initial state
                    _controller.loadRequest(Uri.parse(AppConfig.blinkPayUrl));
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
                onPressed: () {
                  setState(() => _showWebView = true);
                  // Reload initial page when showing WebView
                  _controller.loadRequest(Uri.parse(AppConfig.blinkPayUrl));
                },
                icon: const Icon(Icons.shopping_cart),
                label: const Text('View Shopping Cart in WebView'),
              ),
            ),
    );
  }
}
