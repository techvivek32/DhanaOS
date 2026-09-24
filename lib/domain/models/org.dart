/// `orgs` — the manufacturing entity. "AuraForge India" in the mockups.
library;

import 'package:dhanaos/core/money.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'org.freezed.dart';
part 'org.g.dart';

@freezed
class Org with _$Org {
  const Org._();

  const factory Org({
    required String id,
    required String name,
    @JsonKey(name: 'legal_name') String? legalName,

    /// D-004. Without a GSTIN the org cannot legally raise a tax invoice, so this gates
    /// invoicing rather than sitting in a settings screen as decoration.
    String? gstin,
    String? pan,
    @Default(<String, dynamic>{}) Map<String, dynamic> address,
    @JsonKey(name: 'base_currency') @Default('INR') String baseCurrency,

    /// D-001. The job-code counter, minted server-side by `fn_mint_job_code`. Never increment
    /// this from the client — the SQL function takes a row lock so concurrent commits cannot
    /// collide.
    @JsonKey(name: 'job_seq') @Default(0) int jobSeq,
    @JsonKey(name: 'job_seq_year') required int jobSeqYear,
    @JsonKey(name: 'logo_path') String? logoPath,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Org;

  factory Org.fromJson(Map<String, dynamic> json) => _$OrgFromJson(json);

  String get displayName => legalName?.trim().isNotEmpty == true ? legalName! : name;

  /// D-004: an Indian entity cannot ship without a tax invoice, and cannot raise one without
  /// a GSTIN. Surfaced so the invoice screen can explain the block instead of failing.
  bool get canRaiseTaxInvoice => (gstin?.trim().length ?? 0) >= 15;

  /// The next code this org would mint, for preview only. The authoritative value comes back
  /// from `fn_mint_job_code`.
  String previewNextJobCode({DateTime? now}) {
    final year = (now ?? DateTime.now()).year;
    final next = year == jobSeqYear ? jobSeq + 1 : 1;
    return 'DH-$year-${next.toString().padLeft(5, '0')}';
  }

  /// Zero in the org's own currency, for seeding a running total.
  Money get zero => Money(0, baseCurrency);

  Money money(int minor) => Money(minor, baseCurrency);
}
