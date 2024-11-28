import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

void main() => runApp(const MaterialApp(home: WebViewExample()));

class WebViewExample extends StatefulWidget {
  const WebViewExample({super.key});

  @override
  State<WebViewExample> createState() => _WebViewExampleState();
}

class _WebViewExampleState extends State<WebViewExample> {
  late final WebViewController _controller;
  late AppLinks _appLinks;
  late StreamSubscription _sub;

  bool _showWebView = false;
  bool _isLoading = true;

  static const String blinkpayUrl = 'https://acme-prod.blinkpay.co.nz';
  static const List<String> externalUrls = [
    'https://bank.westpac.co.nz',
    'https://links.anz.co.nz',
    'https://online.asb.co.nz'
  ];

  @override
  void initState() {
    super.initState();
    _setupDeepLinks();
    _setupWebView();
  }

  Future<void> _setupDeepLinks() async {
    _appLinks = AppLinks();
    _sub = _appLinks.uriLinkStream.listen((link) {
      _handleDeepLink(link);
    }, onError: (err) {
      debugPrint('Error handling deep link: $err');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error handling deep link: $err')),
      );
    });
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
          onProgress: (int progress) => debugPrint('Loading progress: $progress'),
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) => setState(() => _isLoading = false),
          onWebResourceError: (error) => debugPrint('Web resource error: $error'),
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            if (url.startsWith('$blinkpayUrl/redirect?cid=')) {
              _handleWebViewClose(url);
              return NavigationDecision.prevent;
            }
            if (externalUrls.any((externalUrl) => url.startsWith(externalUrl))) {
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(blinkpayUrl));

    if (_controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  void _handleDeepLink(Uri link) {
    if (!link.hasAbsolutePath || !Uri.parse(link.toString()).isAbsolute) {
      debugPrint('Invalid link received');
      return;
    }
    if (link.toString().startsWith('blinkpay://test-app/return')) {
      _handleWebViewClose(link.toString());
      _sendParametersToApi(link.queryParameters);
    }
  }

  Future<void> _sendParametersToApi(Map<String, String> parameters) async {
    final url = Uri.https('debit.blinkpay.co.nz', '/bank/1.0/return', parameters);
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        debugPrint('Parameters sent successfully');
      } else {
        debugPrint('Failed to send parameters: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send parameters to API')),
        );
      }
    } catch (e) {
      debugPrint('Error sending parameters: $e');
    }
  }

  void _handleWebViewClose(String navUrl) {
    setState(() {
      _showWebView = false;
    });
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Navigation URL'),
        content: Text(navUrl),
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
        leading: _showWebView
            ? IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            if (await _controller.canGoBack()) {
              _controller.goBack();
            } else {
              setState(() => _showWebView = false);
            }
          },
        )
            : null,
      ),
      body: _showWebView
          ? Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
        ],
      )
          : Center(
        child: ElevatedButton.icon(
          onPressed: () => setState(() => _showWebView = true),
          icon: const Icon(Icons.shopping_cart),
          label: const Text('View Shopping Cart in WebView'),
        ),
      ),
    );
  }
}
