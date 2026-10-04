/// Temporary scaffolding flags.
///
/// Everything in this file is scheduled for deletion — it exists so the UI can
/// be reviewed before the networking milestones land. Do not build anything on
/// top of it.
library;

/// When true, the device list renders a small hardcoded set of peers so the
/// list layout can be seen before discovery exists.
///
/// **TODO(M1): delete this flag and the `samplePeers` list in
/// `lib/state/providers.dart` once UDP discovery is wired up.**
///
/// Set to false to review the "no devices found" empty state instead.
const bool kShowSamplePeers = true;
