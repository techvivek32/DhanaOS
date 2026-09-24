/// Environment configuration.
///
/// Values come from `--dart-define` at build time so no key is ever committed:
///
/// ```
/// flutter run --dart-define-from-file=env/dev.json
/// flutter build apk --release --dart-define-from-file=env/prod.json
/// ```
///
/// See `env/dev.example.json`. The anon key is a public client key — it is safe in an APK
/// *because* every table is protected by RLS (0009_rls.sql). That is what makes D-008 load
/// bearing rather than decorative.
library;

abstract final class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Default org for single-tenant installs; resolved from the session when absent.
  static const defaultOrgSlug = String.fromEnvironment('DEFAULT_ORG', defaultValue: '');

  static const isConfigured = supabaseUrl != '' && supabaseAnonKey != '';

  /// Storage buckets, split by sensitivity. `job-files` is customer-visible;
  /// `vault` holds inventory photography and QC evidence and is internal only.
  static const bucketJobFiles = 'job-files';
  static const bucketVault = 'vault';
  static const bucketBrand = 'brand';

  static String get missingConfigMessage =>
      'Supabase is not configured. Build with '
      '--dart-define-from-file=env/dev.json (copy env/dev.example.json to start).';
}
