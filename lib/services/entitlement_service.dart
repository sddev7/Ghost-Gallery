import 'dart:async';
import 'package:flutter/foundation.dart';

enum EntitlementStatus {
  loading,
  neverRun,
  trialRunning,
  expired,
  subscribed,
  canceled,
}

// Manages feature availability; all features are completely free.
class EntitlementService {
  static final EntitlementService instance = EntitlementService._init();

  static const String productIdMonthly = 'ghost_sub_monthly';
  static const String productIdLifetime = 'ghost_lifetime_buy';

  final ValueNotifier<EntitlementStatus> statusNotifier =
      ValueNotifier<EntitlementStatus>(EntitlementStatus.subscribed);
  final ValueNotifier<bool> pricingBypassed = ValueNotifier<bool>(true);

  String? activeProductId = productIdLifetime;
  DateTime? activeTransactionDate;

  bool _initialized = false;

  EntitlementService._init();

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    statusNotifier.value = EntitlementStatus.subscribed;
    pricingBypassed.value = true;
  }

  void dispose() {}

  Future<void> debugSetStatus(EntitlementStatus newStatus, {String? productId, DateTime? txDate}) async {
    statusNotifier.value = EntitlementStatus.subscribed;
  }

  Future<void> checkStatus({bool showLoading = false}) async {
    statusNotifier.value = EntitlementStatus.subscribed;
  }

  Future<bool> isSubscribedOrInTrial() async => true;

  Future<void> buyProduct(String productId) async {}

  Future<void> restorePurchases() async {}

  Future<EntitlementStatus> restorePurchasesAndGetStatus() async => EntitlementStatus.subscribed;
}
