/// Consent statuses returned by Blink Payments.
class ConsentStatus {
  static const String gatewayAwaitingSubmission = 'GatewayAwaitingSubmission';
  static const String awaitingAuthorisation = 'AwaitingAuthorisation';
  static const String authorised = 'Authorised';
  static const String consumed = 'Consumed';
  static const String rejected = 'Rejected';
  static const String revoked = 'Revoked';
  static const String gatewayTimeout = 'GatewayTimeout';

  /// The consent ended without a payment.
  static bool isFailed(String? status) =>
      status == rejected || status == revoked || status == gatewayTimeout;
}

/// Payment statuses returned by Blink Payments.
class PaymentStatus {
  static const String pending = 'Pending';
  static const String inProcess = 'AcceptedSettlementInProcess';

  /// The only status that means the customer's bank has sent the money.
  static const String completed = 'AcceptedSettlementCompleted';
  static const String rejected = 'Rejected';
}

/// The two kinds of consent this demo can create.
enum ConsentType {
  /// PayNow: one payment of a fixed amount.
  single,

  /// AutoPay: repeat payments up to an agreed limit.
  enduring,
}

/// An order created and priced by the backend.
class CreatedOrder {
  final String orderId;
  final String total;

  const CreatedOrder({required this.orderId, required this.total});
}

/// A consent created for an order, and where to send the customer to approve it.
class CreatedConsent {
  final String consentId;
  final String redirectUri;

  const CreatedConsent({required this.consentId, required this.redirectUri});
}

/// What a revoke request found.
enum RevokeResult {
  /// The consent is revoked; no payment can be made with it.
  revoked,

  /// It was already revoked, by us earlier or by the customer at their bank.
  alreadyRevoked,

  /// It could not be revoked because a payment exists or is in flight, or the
  /// consent already ended. Read its status to learn the outcome.
  outcomeExists,
}
