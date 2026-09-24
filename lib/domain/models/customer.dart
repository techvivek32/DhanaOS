/// `customers` — the retailers the workshop manufactures for. "Scottsdale Diamond Co."
library;

import 'package:dhanaos/core/money.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'customer.freezed.dart';
part 'customer.g.dart';

@freezed
class Customer with _$Customer {
  const Customer._();

  const factory Customer({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    required String name,
    String? code,
    @JsonKey(name: 'contact_name') String? contactName,
    String? email,
    String? phone,

    /// D-004. Needed on the customer too, not just the org: it decides place of supply, and
    /// therefore IGST versus CGST + SGST on every invoice.
    String? gstin,
    @Default(<String, dynamic>{}) Map<String, dynamic> address,

    /// "Net 30".
    @JsonKey(name: 'payment_terms') String? paymentTerms,

    /// A retailer may be billed in a currency other than the org's base.
    @Default('INR') String currency,
    String? notes,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Customer;

  factory Customer.fromJson(Map<String, dynamic> json) => _$CustomerFromJson(json);

  /// "ABC Jewelers · ABCJ-01" in a list row; just the name when no code was assigned.
  String get displayName {
    final c = code?.trim();
    return c == null || c.isEmpty ? name : '$name · $c';
  }

  bool get isGstRegistered => (gstin?.trim().length ?? 0) >= 15;

  /// GSTIN digits 1-2 are the state code. Comparing it with the org's is what decides IGST,
  /// so the invoice never has to ask the operator "is this interstate?".
  String? get stateCode {
    final g = gstin?.trim();
    return g != null && g.length >= 2 ? g.substring(0, 2) : null;
  }

  /// D-004: interstate supply is IGST, intrastate splits into CGST + SGST. Unknown state codes
  /// fall back to interstate, the conservative choice — under-collecting IGST is the costlier
  /// error of the two.
  bool isInterstateFrom(String? orgGstin) {
    final mine = stateCode;
    final theirs = orgGstin != null && orgGstin.trim().length >= 2
        ? orgGstin.trim().substring(0, 2)
        : null;
    if (mine == null || theirs == null) return true;
    return mine != theirs;
  }

  Money money(int minor) => Money(minor, currency);
}
