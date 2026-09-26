/// Files, in and out of the three buckets — and the `attachments` row that makes them findable.
///
/// The mockups referenced twelve project files per job, STL downloads, casting photos,
/// certificate PDFs and voice notes, all pointing at remote Google URLs that will rot, and a
/// file counter with nothing behind it. Here a file is two things that must stay in step: an
/// object in a bucket and a row in `attachments`. [AttachmentStore.upload] writes both or
/// neither.
///
/// **Buckets are a sensitivity boundary, not a folder.** `job-files` is customer-visible;
/// `vault` holds stone photography and QC evidence and never reaches the portal; `brand` holds
/// the org's own marks. Routing is by [AttachmentKind] so a caller cannot put QC evidence in
/// front of a customer by passing the wrong string.
///
/// **Links are signed, never public.** A signed URL expires; a public URL outlives the session,
/// the job and the customer relationship.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:dhanaos/core/config.dart';
import 'package:dhanaos/data/supabase/client.dart';
import 'package:dhanaos/data/supabase/errors.dart';
import 'package:dhanaos/domain/enums.dart';
import 'package:dhanaos/domain/models/models.dart';

part 'storage.g.dart';

const _uuid = Uuid();

/// Which bucket a kind belongs in. Sensitivity, not convenience.
extension AttachmentKindBucket on AttachmentKind {
  String get bucket => switch (this) {
        // Internal only. Stone photography is inventory valuation material and QC evidence is
        // the record behind an irreversible authorisation — neither is customer-facing.
        AttachmentKind.stonePhoto || AttachmentKind.qcEvidence => Config.bucketVault,
        _ => Config.bucketJobFiles,
      };
}

// ---------------------------------------------------------------- request

/// One file to put away. Build it with [UploadRequest.bytes] (camera, recorder, web) or
/// [UploadRequest.file] (file picker, which hands back a path).
final class UploadRequest {
  UploadRequest._({
    required this.orgId,
    required this.kind,
    required this.filename,
    required this.bucket,
    this.jobId,
    this.caption,
    this.durationMs,
    this.threadId,
    this.mimeType,
    this.bytes,
    this.file,
  });

  /// Bytes already in memory — a camera capture, a finished voice note.
  factory UploadRequest.bytes({
    required String orgId,
    required AttachmentKind kind,
    required String filename,
    required Uint8List bytes,
    String? jobId,
    String? bucket,
    String? caption,
    int? durationMs,
    String? threadId,
    String? mimeType,
  }) =>
      UploadRequest._(
        orgId: orgId,
        kind: kind,
        filename: filename,
        bucket: bucket ?? kind.bucket,
        jobId: jobId,
        caption: caption,
        durationMs: durationMs,
        threadId: threadId,
        mimeType: mimeType,
        bytes: bytes,
      );

  /// A file on disk. Streamed rather than read into memory, which matters for an STL a caster
  /// downloads on a cheap handset.
  factory UploadRequest.file({
    required String orgId,
    required AttachmentKind kind,
    required File file,
    String? filename,
    String? jobId,
    String? bucket,
    String? caption,
    int? durationMs,
    String? threadId,
    String? mimeType,
  }) =>
      UploadRequest._(
        orgId: orgId,
        kind: kind,
        filename: filename ?? _basename(file.path),
        bucket: bucket ?? kind.bucket,
        jobId: jobId,
        caption: caption,
        durationMs: durationMs,
        threadId: threadId,
        mimeType: mimeType,
        file: file,
      );

  final String orgId;
  final AttachmentKind kind;

  /// The name an operator recognises — `cad_mesh_v2.png`, `Client_Instructions.wav`. Stored on
  /// the row; the object key is uniquified separately so two casters can both upload `IMG.jpg`.
  final String filename;

  final String bucket;

  /// Null for org-level files: a logo, an inventory photo not yet tied to a job.
  final String? jobId;

  final String? caption;

  /// Voice notes only. The mockup printed "01:20" from a hardcoded string; this is the figure
  /// the recorder actually reports.
  final int? durationMs;

  final String? threadId;
  final String? mimeType;

  /// Exactly one of these is set. [bytes] goes up through `uploadBinary`, [file] through
  /// `upload`, which streams it rather than holding a whole STL in memory.
  final Uint8List? bytes;
  final File? file;

  /// Where the object lands: `org/job/kind/uuid-name`. Job-scoped so a storage policy can be
  /// written against the prefix, and uuid-prefixed so uploads never collide.
  String objectPath() =>
      '$orgId/${jobId ?? '_org'}/${kind.wire}/${_uuid.v4()}-${_safeKey(filename)}';

  String? get contentType => mimeType ?? _contentTypeFor(filename);

  Future<int> byteLength() async {
    final data = bytes;
    if (data != null) return data.lengthInBytes;
    final onDisk = file;
    if (onDisk != null) return onDisk.length();
    return 0;
  }
}

// ---------------------------------------------------------------- progress

/// Where a batch upload has got to.
///
/// Granularity is one file, not one byte: storage_client 2.8 exposes no per-byte hook, so
/// claiming a smooth percentage would be a lie drawn on a progress bar. [current] names the
/// file in flight so a four-photo upload still reads as movement.
final class UploadProgress {
  const UploadProgress({
    required this.total,
    required this.done,
    this.current,
    this.attachments = const [],
    this.failures = const [],
  });

  final int total;

  /// Files settled — uploaded *or* failed. The bar advances either way; a bar that stalls on a
  /// bad file looks like a hung app.
  final int done;

  /// Filename currently going up, or null once the batch is finished.
  final String? current;

  final List<Attachment> attachments;
  final List<DhFailure> failures;

  double get fraction => total == 0 ? 1 : done / total;
  bool get isComplete => done >= total;
  bool get hasFailures => failures.isNotEmpty;

  /// Written from the operator's side: what is happening, or what landed.
  String get label {
    if (!isComplete) {
      final name = current;
      return name == null
          ? 'Uploading $done of $total'
          : 'Uploading $name — $done of $total';
    }
    if (failures.isEmpty) {
      return total == 1 ? '1 file uploaded' : '$total files uploaded';
    }
    return '${attachments.length} of $total uploaded · '
        '${failures.length} failed. Retry the ones that failed.';
  }
}

// ---------------------------------------------------------------- store

/// Upload, download, sign and remove. Every method throws a [DhFailure] and nothing else.
final class AttachmentStore {
  const AttachmentStore(this._client);

  final SupabaseClient _client;

  /// Put one file away and record it.
  ///
  /// The object goes up first, then the row. If the row is refused — RLS, or the job was
  /// cancelled while the photo was uploading — the object is removed again, because bytes in a
  /// bucket that no row points at are invisible, unbilled to nobody, and impossible to find
  /// later.
  Future<Attachment> upload(
    UploadRequest request, {
    StorageRetryController? cancel,
  }) async {
    final objectPath = request.objectPath();
    final size = await request.byteLength();
    final options = FileOptions(
      contentType: request.contentType,
      // Never overwrite: the object key carries a uuid, so a collision means a bug, not a
      // re-upload, and silently replacing evidence is the worst possible response to it.
      upsert: false,
    );

    await guard(() async {
      final bucket = _client.storage.from(request.bucket);
      final onDisk = request.file;
      if (onDisk != null) {
        return bucket.upload(
          objectPath,
          onDisk,
          fileOptions: options,
          retryController: cancel,
        );
      }
      return bucket.uploadBinary(
        objectPath,
        request.bytes ?? Uint8List(0),
        fileOptions: options,
        retryController: cancel,
      );
    });

    try {
      final row = await guard(
        () => _client
            .from('attachments')
            .insert({
              'org_id': request.orgId,
              'job_id': request.jobId,
              // Convention 6: the enum crosses the wire as its Postgres value.
              'kind': request.kind.wire,
              'bucket': request.bucket,
              'path': objectPath,
              'filename': request.filename,
              'mime_type': request.contentType,
              'size_bytes': size,
              'duration_ms': request.durationMs,
              'caption': request.caption,
              'thread_id': request.threadId,
              'uploaded_by': _client.auth.currentUser?.id,
            })
            .select()
            .single(),
      );
      return Attachment.fromJson(row);
    } on DhFailure {
      await _removeQuietly(request.bucket, objectPath);
      rethrow;
    }
  }

  /// Upload several files, reporting after each one.
  ///
  /// A failure does not abort the batch. Four reference photos where the third has a corrupt
  /// EXIF header should still leave three photos on the job, with one named failure the
  /// operator can retry — not zero files and a red screen.
  Stream<UploadProgress> uploadAll(
    List<UploadRequest> requests, {
    StorageRetryController? cancel,
  }) async* {
    final done = <Attachment>[];
    final failed = <DhFailure>[];
    final total = requests.length;

    for (var i = 0; i < total; i++) {
      final request = requests[i];
      yield UploadProgress(
        total: total,
        done: i,
        current: request.filename,
        attachments: List.unmodifiable(done),
        failures: List.unmodifiable(failed),
      );
      try {
        done.add(await upload(request, cancel: cancel));
      } on DhFailure catch (failure) {
        failed.add(failure);
      }
    }

    yield UploadProgress(
      total: total,
      done: total,
      attachments: List.unmodifiable(done),
      failures: List.unmodifiable(failed),
    );
  }

  /// The files on a job, newest first. Pass [kind] to answer a gate question directly — the
  /// caster's "is there a casting photo yet" (D-011 rule 1) is
  /// `forJob(id, kind: AttachmentKind.castingPhoto)`.
  Future<List<Attachment>> forJob(String jobId, {AttachmentKind? kind}) async {
    final rows = await guard(() {
      final query = _client.from('attachments').select().eq('job_id', jobId);
      final scoped = kind == null ? query : query.eq('kind', kind.wire);
      return scoped.order('created_at', ascending: false);
    });
    return [for (final row in rows) Attachment.fromJson(row)];
  }

  /// Bytes, for a preview or an offline copy.
  Future<Uint8List> download(Attachment attachment) => guard(
        () => _client.storage.from(attachment.bucket).download(attachment.path),
      );

  /// A short-lived URL for `Image.network` / `cached_network_image`.
  ///
  /// Thirty minutes is long enough to scroll a job and short enough that a link pasted into a
  /// chat is dead before it leaves the building. Never call `getPublicUrl` on these buckets.
  Future<String> signedUrl(
    Attachment attachment, {
    Duration ttl = const Duration(minutes: 30),
  }) =>
      guard(
        () => _client.storage
            .from(attachment.bucket)
            .createSignedUrl(attachment.path, ttl.inSeconds),
      );

  /// Signed URLs for a whole list in one round trip, keyed by attachment id. Files that cannot
  /// be signed are simply absent from the map, so a gallery renders the rest instead of
  /// failing whole.
  Future<Map<String, String>> signedUrls(
    List<Attachment> attachments, {
    Duration ttl = const Duration(minutes: 30),
  }) async {
    final out = <String, String>{};
    final byBucket = <String, List<Attachment>>{};
    for (final attachment in attachments) {
      byBucket.putIfAbsent(attachment.bucket, () => []).add(attachment);
    }
    for (final entry in byBucket.entries) {
      final paths = [for (final a in entry.value) a.path];
      final results = await guard(
        () => _client.storage.from(entry.key).createSignedUrlsResult(paths, ttl.inSeconds),
      );
      final byPath = <String, String>{
        for (final result in results)
          if (result is SignedUrlSuccess) result.path: result.signedUrl,
      };
      for (final attachment in entry.value) {
        final url = byPath[attachment.path];
        if (url != null) out[attachment.id] = url;
      }
    }
    return out;
  }

  /// Remove the row first, then the object.
  ///
  /// That order is deliberate: a row pointing at a missing object renders as a broken tile on
  /// every screen that lists files, while an object with no row is merely unreferenced storage
  /// that a bucket sweep can reclaim. Take the visible failure off the table first.
  Future<void> delete(Attachment attachment) async {
    await guard(() => _client.from('attachments').delete().eq('id', attachment.id));
    await _removeQuietly(attachment.bucket, attachment.path);
  }

  /// Best-effort object removal used on the two compensating paths. It cannot be allowed to
  /// mask the real failure that sent us here.
  Future<void> _removeQuietly(String bucket, String path) async {
    try {
      await _client.storage.from(bucket).remove([path]);
    } on Object catch (_) {
      // Nothing useful to do: the row is already gone or was never written.
    }
  }
}

@riverpod
AttachmentStore attachmentStore(Ref ref) => AttachmentStore(ref.watch(supabaseProvider));

// ---------------------------------------------------------------- helpers

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? path : parts.last;
}

/// Storage object keys tolerate a narrow charset; an operator's filename does not. Keep the
/// readable characters, fold the rest, and never let the key go empty.
String _safeKey(String filename) {
  final cleaned = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'_{2,}'), '_');
  return trimmed.isEmpty ? 'file' : trimmed;
}

String _extension(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot <= 0 || dot == filename.length - 1
      ? ''
      : filename.substring(dot + 1).toLowerCase();
}

/// Supabase stores whatever `Content-Type` it is handed, and the browser and the Flutter image
/// decoder both believe it. Getting this wrong turns a JPEG into a download prompt.
String? _contentTypeFor(String filename) => switch (_extension(filename)) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'wav' => 'audio/wav',
      'm4a' => 'audio/mp4',
      'aac' => 'audio/aac',
      'mp3' => 'audio/mpeg',
      'ogg' => 'audio/ogg',
      'mp4' => 'video/mp4',
      'stl' => 'model/stl',
      'step' || 'stp' => 'model/step',
      'obj' => 'model/obj',
      'zip' => 'application/zip',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'txt' => 'text/plain',
      _ => null,
    };
