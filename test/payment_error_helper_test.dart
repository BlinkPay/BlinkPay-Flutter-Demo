import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:blinkpay_flutter_demo/blinkpay_service.dart';
import 'package:blinkpay_flutter_demo/models/payment_models.dart';
import 'package:blinkpay_flutter_demo/utils/payment_error_helper.dart';

void main() {
  String forCode(int status, String? code, {String? message}) =>
      PaymentErrorHelper.forError(
        BlinkPayApiException(status, code: code, message: message),
      );

  group('forError', () {
    test('chooses the message from the error code', () {
      expect(forCode(400, 'BP214'), PaymentErrorHelper.notSetUp);
      expect(forCode(422, 'BP036'), PaymentErrorHelper.bankDeclined);
      expect(forCode(422, 'BP229'), PaymentErrorHelper.overLimit);
      expect(forCode(422, 'BP004'), PaymentErrorHelper.expired);
      expect(forCode(409, 'BP701'), PaymentErrorHelper.cancelled);
      expect(forCode(503, 'BP601'), PaymentErrorHelper.bankUnavailable);
    });

    test('ignores the wording of the message', () {
      expect(
        forCode(422, 'BP036', message: 'Consent timeout: network error'),
        PaymentErrorHelper.bankDeclined,
      );
      expect(
        forCode(400, 'BP999', message: 'consent token authentication'),
        PaymentErrorHelper.generic,
      );
    });

    test('falls back to the HTTP status for unknown codes', () {
      expect(forCode(429, null), PaymentErrorHelper.busy);
      expect(
        forCode(502, 'proxy_error'),
        PaymentErrorHelper.serviceUnavailable,
      );
      expect(forCode(400, null), PaymentErrorHelper.generic);
    });

    test('maps a missing response to the network message', () {
      expect(
        PaymentErrorHelper.forError(
          BlinkPayNetworkException(http.ClientException('reset')),
        ),
        PaymentErrorHelper.network,
      );
    });
  });

  test('forConsentStatus distinguishes how a consent ended', () {
    expect(
      PaymentErrorHelper.forConsentStatus(ConsentStatus.revoked),
      PaymentErrorHelper.cancelled,
    );
    expect(
      PaymentErrorHelper.forConsentStatus(ConsentStatus.rejected),
      contains('declined'),
    );
    expect(
      PaymentErrorHelper.forConsentStatus(ConsentStatus.gatewayTimeout),
      contains('expired'),
    );
  });
}
