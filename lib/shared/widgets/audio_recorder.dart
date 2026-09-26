/// The voice-note recorder. Mic ↔ stop swap, a live waveform, an mm:ss timer, then playback.
///
/// Modelled on `new_job_inquiry`, which was the **only working recorder in the whole 46-screen
/// corpus** — the one screen whose JavaScript actually swapped the mic icon for a stop icon,
/// animated bars and counted seconds. Every later redesign replaced it with a static
/// "Client_Instructions.wav 01:20" string. That screen's behaviour is preserved here and the parts
/// it faked are made real: the waveform is driven by the recorder's own amplitude stream, the
/// duration is measured rather than printed, and the note can be played back before it is kept.
///
/// D-011 rule 4: a voice note satisfies the capture gate on its own. The mockup's camera-only gate
/// was an oversight — a bench jeweller describing a repair out loud is giving us *more* than a
/// blurry photo would.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:dhanaos/core/theme/app_theme.dart';
import 'package:dhanaos/core/theme/tokens.dart';
import 'package:dhanaos/shared/widgets/reduced_motion.dart';

/// A finished recording. [waveform] is kept so the note can be redrawn exactly as it was captured
/// rather than as a row of identical bars.
@immutable
final class VoiceNote {
  const VoiceNote({
    required this.path,
    required this.duration,
    this.waveform = const <double>[],
  });

  /// Local file path. The caller uploads it and writes an `attachments` row with
  /// `kind: AttachmentKind.voiceNote` and `duration_ms`.
  final String path;

  final Duration duration;

  /// Normalised 0–1 amplitude samples, oldest first.
  final List<double> waveform;

  /// "01:20" — the form the attachment chip shows.
  String get durationLabel => VoiceNoteRecorder.formatDuration(duration);
}

enum _Phase { idle, starting, recording, recorded, denied, failed }

final class VoiceNoteRecorder extends StatefulWidget {
  const VoiceNoteRecorder({
    super.key,
    this.onRecorded,
    this.onCleared,
    this.initialNote,
    this.maxDuration = const Duration(minutes: 5),
    this.label = 'Voice Note',
    this.hint = 'Describe the piece in your own words — sizing, stones, what the client said.',
    this.enabled = true,
  });

  /// Fired once, when a recording is finished and playable.
  final ValueChanged<VoiceNote>? onRecorded;

  /// Fired when the operator deletes the note. The file is removed from disk first.
  final VoidCallback? onCleared;

  /// Re-opens an existing note — a draft resumed, or an attachment being reviewed.
  final VoiceNote? initialNote;

  /// Recording stops itself here. Five minutes is already a long brief.
  final Duration maxDuration;

  final String label;
  final String hint;
  final bool enabled;

  static String formatDuration(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  State<VoiceNoteRecorder> createState() => _VoiceNoteRecorderState();
}

class _VoiceNoteRecorderState extends State<VoiceNoteRecorder>
    with SingleTickerProviderStateMixin {
  static const _barCount = 44;

  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _stopwatch = Stopwatch();

  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  StreamSubscription<Amplitude>? _amplitudeSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  Timer? _ticker;

  _Phase _phase = _Phase.idle;
  String? _failure;
  VoiceNote? _note;

  /// Every amplitude sample of the take, oldest first — ten a second, so a five-minute maximum is
  /// 3000 doubles. Kept whole rather than trimmed to the visible window, because the playback
  /// waveform has to show the shape of the *whole* note, not its last four seconds.
  List<double> _samples = const <double>[];

  /// [_samples] reduced to [_barCount] buckets, for the playback view.
  List<double> _playbackBars = const <double>[];

  Duration _elapsed = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialNote;
    if (initial != null) {
      _note = initial;
      _playbackBars = initial.waveform;
      _phase = _Phase.recorded;
      _loadForPlayback(initial.path);
    }
    _positionSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _playerStateSub = _player.playerStateStream.listen((state) async {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        await _player.pause();
        await _player.seek(Duration.zero);
        if (mounted) setState(() => _playing = false);
      } else {
        setState(() => _playing = state.playing);
      }
    });
  }

  /// A draft's existing note usually arrives *after* the first frame — the wizard step builds,
  /// then the attachment query resolves. Adopting it here is what stops a resumed draft showing an
  /// empty recorder over a note that already exists.
  @override
  void didUpdateWidget(VoiceNoteRecorder old) {
    super.didUpdateWidget(old);
    final incoming = widget.initialNote;
    if (incoming != null && incoming.path != _note?.path) {
      setState(() {
        _note = incoming;
        _playbackBars = incoming.waveform;
        _phase = _Phase.recorded;
        _position = Duration.zero;
      });
      _loadForPlayback(incoming.path);
    } else if (incoming == null &&
        old.initialNote != null &&
        _note?.path == old.initialNote!.path) {
      // The parent withdrew the note it supplied; do not delete the file it owns.
      setState(() {
        _note = null;
        _playbackBars = const <double>[];
        _phase = _Phase.idle;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The "recording" dot must not blink forever for someone who asked for no animation.
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_blink.isAnimating) _blink.stop();
      _blink.value = 1;
    } else if (_phase == _Phase.recording && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _blink.dispose();
    _recorder.dispose();
    _player.dispose();
    _stopwatch.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------- recording

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.starting;
      _failure = null;
    });

    try {
      if (!await _recorder.hasPermission()) {
        if (!mounted) return;
        setState(() => _phase = _Phase.denied);
        return;
      }

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      // AAC-LC in an m4a container: small enough for a 4G shop connection, and playable by every
      // browser the customer portal might open it in.
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 96000, sampleRate: 44100),
        path: path,
      );

      _samples = const <double>[];
      _playbackBars = const <double>[];
      _elapsed = Duration.zero;
      _position = Duration.zero;
      _stopwatch
        ..reset()
        ..start();

      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen(_onAmplitude);

      _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (!mounted) return;
        setState(() => _elapsed = _stopwatch.elapsed);
        if (_stopwatch.elapsed >= widget.maxDuration) _stop();
      });

      if (!mounted) return;
      setState(() => _phase = _Phase.recording);
      if (!context.reduceMotion) _blink.repeat(reverse: true);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = 'The microphone could not start. $e';
      });
    }
  }

  /// dBFS is negative and roughly floors at −55 in a quiet workshop, so the window is 55dB wide.
  /// A floor of 0.06 keeps a visible bar during a pause — a flat line reads as "broken".
  void _onAmplitude(Amplitude amp) {
    final normalised = ((amp.current + 55) / 55).clamp(0.06, 1.0);
    setState(() => _samples = [..._samples, normalised]);
  }

  /// Buckets the samples down to [_barCount], taking the peak of each bucket so a short loud
  /// syllable is not averaged out of existence.
  static List<double> _downsample(List<double> samples, int buckets) {
    if (samples.isEmpty) return const <double>[];
    if (samples.length <= buckets) return List<double>.unmodifiable(samples);
    final out = List<double>.filled(buckets, 0);
    for (var i = 0; i < buckets; i++) {
      final from = (samples.length * i / buckets).floor();
      final to = math.max(from + 1, (samples.length * (i + 1) / buckets).floor());
      var peak = 0.0;
      for (var j = from; j < to && j < samples.length; j++) {
        if (samples[j] > peak) peak = samples[j];
      }
      out[i] = peak;
    }
    return List<double>.unmodifiable(out);
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _stopwatch.stop();
    _blink.stop();

    String? path;
    try {
      path = await _recorder.stop();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = 'The recording could not be saved. $e';
      });
      return;
    }

    if (!mounted) return;
    if (path == null) {
      setState(() {
        _phase = _Phase.failed;
        _failure = 'The recording came back empty. Tap the mic to try again.';
      });
      return;
    }

    final bars = _downsample(_samples, _barCount);
    final note = VoiceNote(path: path, duration: _stopwatch.elapsed, waveform: bars);
    setState(() {
      _note = note;
      _playbackBars = bars;
      _phase = _Phase.recorded;
      _elapsed = note.duration;
    });
    await _loadForPlayback(path);
    final settled = _note;
    if (settled != null) widget.onRecorded?.call(settled);
  }

  Future<void> _loadForPlayback(String path) async {
    try {
      final real = await _player.setFilePath(path);
      if (!mounted || real == null) return;
      // The container's own duration beats the stopwatch — it is what the player will scrub.
      setState(() => _note = VoiceNote(
            path: path,
            duration: real,
            waveform: _note?.waveform ?? _playbackBars,
          ));
    } on Exception {
      // Playback is a convenience; a note that cannot be previewed is still a note that uploads.
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> _clear() async {
    final path = _note?.path;
    await _player.stop();
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } on FileSystemException {
        // A temp file we cannot delete is the OS's problem, not the operator's.
      }
    }
    if (!mounted) return;
    setState(() {
      _note = null;
      _samples = const <double>[];
      _playbackBars = const <double>[];
      _elapsed = Duration.zero;
      _position = Duration.zero;
      _phase = _Phase.idle;
    });
    widget.onCleared?.call();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final dh = context.dh;

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: dh.surfaceContainerLowest,
        borderRadius: Radii.rLg,
        border: Border.all(
          color: _phase == _Phase.recording ? scheme.tertiary : dh.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label.toUpperCase(),
                  style: context.text.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              if (_phase == _Phase.recording) _RecordingBadge(blink: _blink),
            ],
          ),
          const SizedBox(height: Spacing.md),
          switch (_phase) {
            _Phase.idle || _Phase.starting => _idleRow(context),
            _Phase.recording => _recordingRow(context),
            _Phase.recorded => _playbackRow(context),
            _Phase.denied => _messageRow(
                context,
                icon: Icons.mic_off_rounded,
                message: 'Microphone access is off. Turn it on in Settings › Apps › DhanaOS › '
                    'Permissions, then tap the mic again.',
                actionLabel: 'Try again',
                onAction: _start,
              ),
            _Phase.failed => _messageRow(
                context,
                icon: Icons.error_outline_rounded,
                message: _failure ?? 'The recorder stopped unexpectedly.',
                actionLabel: 'Try again',
                onAction: _start,
              ),
          },
        ],
      ),
    );
  }

  Widget _idleRow(BuildContext context) {
    final busy = _phase == _Phase.starting;
    return Row(
      children: [
        _RoundButton(
          icon: Icons.mic_rounded,
          filled: true,
          busy: busy,
          tooltip: 'Start recording',
          onTap: widget.enabled && !busy ? _start : null,
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Text(
            widget.hint,
            style: context.text.bodySmall
                ?.copyWith(color: context.scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _recordingRow(BuildContext context) {
    return Row(
      children: [
        _RoundButton(
          icon: Icons.stop_rounded,
          filled: true,
          tooltip: 'Stop and keep this recording',
          onTap: _stop,
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: SizedBox(
            height: 40,
            child: CustomPaint(
              painter: _WaveformPainter(
                bars: _samples,
                barCount: _barCount,
                played: context.scheme.tertiary,
                unplayed: context.dh.outlineVariant,
                progress: 1,
                alignRight: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: Spacing.md),
        _Clock(
          text: VoiceNoteRecorder.formatDuration(_elapsed),
          color: context.scheme.tertiary,
        ),
      ],
    );
  }

  Widget _playbackRow(BuildContext context) {
    final note = _note;
    final total = note?.duration ?? _elapsed;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return Column(
      children: [
        Row(
          children: [
            _RoundButton(
              icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              filled: false,
              tooltip: _playing ? 'Pause' : 'Play the note back',
              onTap: _togglePlay,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              // The waveform doubles as the scrubber, so the seek fraction has to come from the
              // painted box's own width — not from the whole recorder card.
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    if (constraints.maxWidth <= 0) return;
                    final fraction =
                        (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                    _player.seek(total * fraction);
                  },
                  child: SizedBox(
                    height: 40,
                    child: CustomPaint(
                      painter: _WaveformPainter(
                        bars: _playbackBars,
                        barCount: _barCount,
                        played: context.scheme.tertiary,
                        unplayed: context.dh.outlineVariant,
                        progress: progress,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Spacing.md),
            _Clock(
              text: '${VoiceNoteRecorder.formatDuration(_position)} / '
                  '${VoiceNoteRecorder.formatDuration(total)}',
              color: context.scheme.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: const Text('Record again'),
            ),
            const SizedBox(width: Spacing.sm),
            TextButton.icon(
              onPressed: _clear,
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.scheme.error),
              label: Text(
                'Delete',
                style: TextStyle(color: context.scheme.error),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _messageRow(
    BuildContext context, {
    required IconData icon,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final scheme = context.scheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: scheme.error),
        const SizedBox(width: Spacing.sm + Spacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: context.text.bodySmall?.copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: Spacing.xs),
              TextButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ),
        ),
      ],
    );
  }
}

/// "REC" plus a dot that fades in and out. Under reduced motion the controller is parked at 1, so
/// the dot is simply on — the state is still unmistakable.
final class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge({required this.blink});

  final Animation<double> blink;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: blink,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: Spacing.xs + 2),
        Text(
          'RECORDING',
          style: AppTheme.mono(size: 10, weight: FontWeight.w700, color: scheme.error)
              .copyWith(letterSpacing: 1.2),
        ),
      ],
    );
  }
}

final class _Clock extends StatelessWidget {
  const _Clock({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        // Tabular figures, so the timer does not jitter as the seconds roll over.
        style: AppTheme.mono(size: 13, weight: FontWeight.w600, color: color),
      );
}

final class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.filled,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final bool filled;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final enabled = onTap != null;
    final bg = filled
        ? (enabled ? scheme.primary : context.dh.surfaceContainerHigh)
        : context.dh.surfaceContainerHigh;
    final fg = filled
        ? (enabled ? scheme.onPrimary : scheme.onSurfaceVariant)
        : scheme.onSurface;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(icon, size: 26, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded bars from a normalised amplitude list.
///
/// While recording it draws right-aligned so new samples arrive at the leading edge, which is how
/// the source screen's animation read. On playback it spreads the captured shape across the full
/// width and tints the played portion, which makes the bar double as a scrubber.
final class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.bars,
    required this.barCount,
    required this.played,
    required this.unplayed,
    required this.progress,
    this.alignRight = false,
  });

  final List<double> bars;
  final int barCount;
  final Color played;
  final Color unplayed;
  final double progress;
  final bool alignRight;

  @override
  void paint(Canvas canvas, Size size) {
    if (barCount <= 0) return;
    final slot = size.width / barCount;
    final barWidth = math.max(2.0, slot * 0.55);
    final radius = Radius.circular(barWidth / 2);
    final centre = size.height / 2;
    final playedUntil = size.width * progress;

    for (var i = 0; i < barCount; i++) {
      // Right-aligned: the most recent sample sits in the last slot and older ones trail left.
      final sampleIndex = alignRight ? bars.length - barCount + i : i;
      final value = (sampleIndex >= 0 && sampleIndex < bars.length)
          ? bars[sampleIndex]
          : (alignRight ? 0.0 : _fallbackShape(i));
      if (value <= 0) continue;

      final height = math.max(barWidth, value * size.height);
      final x = slot * i + (slot - barWidth) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, centre - height / 2, barWidth, height),
        radius,
      );
      canvas.drawRRect(
        rect,
        Paint()..color = (x + barWidth / 2) <= playedUntil ? played : unplayed,
      );
    }
  }

  /// Only used when a note was restored without its captured waveform: a gentle, obviously
  /// synthetic shape rather than a flat line that would read as a failed recording.
  static double _fallbackShape(int i) => 0.25 + 0.35 * (1 + math.sin(i * 0.7)) / 2;

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress ||
      old.bars.length != bars.length ||
      !identical(old.bars, bars) ||
      old.played != played ||
      old.unplayed != unplayed;
}
