/// The domain models, mirroring the SQL schema in `supabase/migrations`.
///
/// Import this one file:
/// ```dart
/// import 'package:dhanaos/domain/models/models.dart';
/// ```
///
/// Not exported on purpose:
///   * `converters.dart` — the enum JsonConverters are plumbing for the generated code. Nothing
///     outside a model needs them, and exporting 94 converter names would bury the models.
///   * `package:dhanaos/domain/enums.dart` — import it directly. It is the shared vocabulary of
///     the whole app, not a detail of this layer.
library;

export 'activity.dart';
export 'app_user.dart';
export 'attachment.dart';
export 'billing.dart';
export 'commercial.dart';
export 'customer.dart';
export 'inventory.dart';
export 'job.dart';
export 'job_stage.dart';
export 'org.dart';
export 'partner.dart';
export 'production.dart';
export 'resource.dart';
export 'spec.dart';
export 'stone.dart';
export 'units.dart';
export 'wire_enums.dart';
