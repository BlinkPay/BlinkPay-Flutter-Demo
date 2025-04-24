import 'dart:async';
import 'package:app_links/app_links.dart';
import '../env.dart';
import '../utils/log.dart';

/// Handles incoming deep links for payment redirection.
class DeepLinkHandler {
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSub;

  // Callbacks to notify the main application
  final Function(String? consentId, String? error, String? errorDescription)
      onLinkReceived;
  final Function(String error) onErrorOccurred;

  /// Initializes the handler and starts listening for links.
  DeepLinkHandler({
    required this.onLinkReceived,
    required this.onErrorOccurred,
  }) : _appLinks = AppLinks() {
    _initListener();
  }

  /// Initializes the deep link listener stream.
  void _initListener() {
    Log.info('Initializing deep link listener...');
    _linkSub = _appLinks.uriLinkStream.listen(
      (Uri? uri) {
        if (uri == null) {
          Log.debug('Received null URI from deep link stream');
          return;
        }
        Log.info('Received deep link: $uri');

        // Check if it's our expected redirect URI
        if (uri.toString().startsWith(Environment.redirectUri)) {
          final error = uri.queryParameters['error'];
          final consentIdFromUri = uri.queryParameters['cid'];
          final errorDescription = uri.queryParameters['error_description'];
          Log.info(
              'Redirect URI received. ConsentId: $consentIdFromUri, Error: $error, Description: $errorDescription');
          onLinkReceived(consentIdFromUri, error, errorDescription);
        } else {
          Log.info('Ignoring deep link from unexpected source: $uri');
        }
      },
      onError: (err, stacktrace) {
        final errorMessage = 'Deep link listener error: $err';
        Log.error(errorMessage, err, stacktrace);
        onErrorOccurred(errorMessage);
      },
    );
  }

  /// Disposes the stream subscription.
  void dispose() {
    _linkSub?.cancel();
    Log.info('DeepLinkHandler Disposed');
  }
}
