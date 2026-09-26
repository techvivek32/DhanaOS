/// The DhanaOS design system in Flutter.
///
/// D-010: one component set, two token sets. Every mockup declared `darkMode:"class"` and shipped
/// zero `dark:` variants, because light and dark were complete standalone palettes bound to the
/// same token names — so the markup was theme-agnostic by construction. These widgets keep that
/// property: none of them contains a colour, radius or spacing literal, and every one renders
/// correctly in both themes and with animations disabled.
///
/// Import this one file:
///
/// ```dart
/// import 'package:dhanaos/shared/widgets/widgets.dart';
/// ```
///
/// One name to watch: [StageRail] is also the name of the *data* aggregate in
/// `domain/models/job_stage.dart`. A library that must write both type names can reach the widget
/// through the [JobStageRail] alias instead of prefixing an import.
library;

export 'attachment_tile.dart';
export 'audio_recorder.dart';
export 'data_pair.dart';
export 'dh_card.dart';
export 'empty_state.dart';
export 'money_field.dart';
export 'reduced_motion.dart';
export 'req_tag.dart';
export 'segmented.dart';
export 'selectable_tile.dart';
export 'stage_rail.dart';
export 'status_chip.dart';
export 'stepper_field.dart';
export 'wizard_scaffold.dart';
