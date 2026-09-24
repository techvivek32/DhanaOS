/// `attachments` — every file the job carries, in Supabase Storage.
///
/// The mockups pointed at remote Google URLs that will rot, and counted "12 project files" with
/// nothing behind the number. Files live in one of two buckets by sensitivity: `job-files` is
/// customer-visible, `vault` holds inventory photography and QC evidence.
library;

import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/converters.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'attachment.freezed.dart';
part 'attachment.g.dart';

@freezed
class Attachment with _$Attachment {
  const Attachment._();

  const factory Attachment({
    required String id,
    @JsonKey(name: 'org_id') required String orgId,
    @JsonKey(name: 'job_id') String? jobId,
    @AttachmentKindConverter() required AttachmentKind kind,
    @Default('job-files') String bucket,

    /// Storage object path, not a URL. Signed URLs are minted per request so a leaked link
    /// cannot outlive the session.
    required String path,

    /// 'cad_mesh_v2.png', 'Client_Instructions.wav'.
    required String filename,
    @JsonKey(name: 'mime_type') String? mimeType,
    @JsonKey(name: 'size_bytes') int? sizeBytes,

    /// Voice notes only. The mockup rendered "Client_Instructions.wav 01:20" from a hardcoded
    /// string; this is the real figure the recorder reports.
    @JsonKey(name: 'duration_ms') int? durationMs,
    String? caption,

    /// Set when the file was posted into the digital thread rather than attached to a stage.
    @JsonKey(name: 'thread_id') String? threadId,
    @JsonKey(name: 'uploaded_by') String? uploadedBy,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Attachment;

  factory Attachment.fromJson(Map<String, dynamic> json) => _$AttachmentFromJson(json);

  /// Lowercase, without the dot. Empty when the filename carries none.
  String get extension {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 || dot == filename.length - 1
        ? ''
        : filename.substring(dot + 1).toLowerCase();
  }

  bool get isImage =>
      (mimeType?.startsWith('image/') ?? false) ||
      const {'png', 'jpg', 'jpeg', 'webp', 'heic'}.contains(extension);

  bool get isAudio =>
      (mimeType?.startsWith('audio/') ?? false) ||
      const {'wav', 'm4a', 'aac', 'mp3', 'ogg'}.contains(extension);

  bool get isPdf => mimeType == 'application/pdf' || extension == 'pdf';

  /// STL / STEP meshes are downloaded by the caster, never previewed in-app.
  bool get isModel => const {'stl', 'step', 'stp', '3dm', 'obj'}.contains(extension);

  bool get isVoiceNote => kind == AttachmentKind.voiceNote;

  /// D-011 rule 4. Intake cannot advance past media capture without a reference — and the
  /// mockup's camera-only gate was an oversight, so a voice note or an uploaded sketch counts
  /// just as much as a photo.
  bool get satisfiesCaptureGate => switch (kind) {
        AttachmentKind.referenceImage ||
        AttachmentKind.sketch ||
        AttachmentKind.voiceNote ||
        AttachmentKind.cadRender ||
        AttachmentKind.stonePhoto ||
        AttachmentKind.other =>
          true,
        _ => false,
      };

  /// D-011 rule 1. The one file that unlocks "Mark Complete" for the caster.
  bool get isCastingEvidence => kind == AttachmentKind.castingPhoto;

  /// Internal-only by bucket, not by convention — QC evidence and vault photography must never
  /// reach the customer portal.
  bool get isInternalOnly => bucket == 'vault';

  /// "01:20" — minutes and seconds, the form the recorder chip shows.
  String? get durationLabel {
    final ms = durationMs;
    if (ms == null || ms <= 0) return null;
    final total = Duration(milliseconds: ms);
    final mm = total.inMinutes.toString().padLeft(2, '0');
    final ss = (total.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// "1.4 MB". Binary units, because that is what the storage dashboard reports.
  String? get sizeLabel {
    final b = sizeBytes;
    if (b == null) return null;
    if (b < 1024) return '$b B';
    const units = ['KB', 'MB', 'GB'];
    var value = b / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }

  /// "Casting Photo · 1.4 MB" / "Voice Note · 01:20".
  String get metaLabel {
    final parts = <String>[kind.label];
    final d = durationLabel;
    final s = sizeLabel;
    if (d != null) parts.add(d);
    if (s != null) parts.add(s);
    return parts.join(' · ');
  }
}
