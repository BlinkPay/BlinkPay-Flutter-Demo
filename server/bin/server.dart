import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:blinkpay_proxy_server/src/config.dart';
import 'package:blinkpay_proxy_server/src/blinkpay_client.dart';
import 'package:blinkpay_proxy_server/src/middleware/auth_middleware.dart';
import 'package:blinkpay_proxy_server/src/routes/consent_routes.dart';
import 'package:blinkpay_proxy_server/src/routes/payment_routes.dart';

void main() async {
  // ── Load configuration ─────────────────────────────────────────────
  final env = DotEnv()..load(['.env']);
  final config = ServerConfig.fromEnv(env);

  try {
    config.validate();
  } catch (e) {
    stderr.writeln('Configuration error: $e');
    exit(1);
  }

  // ── Create BlinkPay API client ─────────────────────────────────────
  final blinkPayClient = BlinkPayClient(config: config);

  // ── Build routes ───────────────────────────────────────────────────
  //
  // All BlinkPay proxy endpoints are mounted under /api/payments/v1/.
  // The route handlers register paths relative to that mount point.
  final apiRouter = Router();
  ConsentRoutes(blinkPayClient).addTo(apiRouter);
  PaymentRoutes(blinkPayClient).addTo(apiRouter);

  final router = Router();
  router.mount('/api/payments/v1/', apiRouter.call);

  // ── Apply middleware and serve ─────────────────────────────────────
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(apiKeyAuth(config.appApiKey))
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, '0.0.0.0', config.port);

  print('');
  print('========================================');
  print('  BlinkPay Proxy Server');
  print('========================================');
  print('  Listening on: http://${server.address.host}:${server.port}');
  print('  BlinkPay API: https://${config.blinkPayApiUrl}');
  print('========================================');
  print('');
}
