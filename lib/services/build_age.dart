/// Soft build-age warning (v0.27.1).
///
/// After [buildAgeWarningDays] days this build shows a dashboard banner
/// telling the operator to update to the latest Shepherd. That is all it
/// does: a nudge, never a lockout. Sensing, detection, alerts, and the
/// tracker keep running exactly as before — a stale build must never go
/// dark in the field, and anyone rebuilding from the GPLv3 source can
/// remove this check, so it is honest labeling, not enforcement.
///
/// [buildDate] is the date this version was cut. It MUST be updated at
/// every version bump, alongside pubspec.yaml — a stale buildDate would
/// warn on a fresh build. There is no network check and no clock
/// authority here; the device clock is the only input, so a wrong clock
/// can warn early or late, and that is acceptable for a nudge.
library;

/// Date this version was cut. Update at every version bump.
/// (DateTime has no const constructor, so this is final, not const.)
final DateTime buildDate = DateTime(2026, 11, 5);

/// Days after the build date before the banner appears.
const int buildAgeWarningDays = 90;

/// Days since the build date, clamped at zero for a clock set before it.
int buildAgeDays({required DateTime now, DateTime? build}) {
  final b = build ?? buildDate;
  final days = now.difference(b).inDays;
  return days < 0 ? 0 : days;
}

/// The banner text, or null when the build is fresh enough to stay quiet.
/// Pure function so the boundary is unit-testable.
String? buildAgeWarning({required DateTime now, DateTime? build}) {
  final days = buildAgeDays(now: now, build: build);
  if (days < buildAgeWarningDays) return null;
  return 'THIS BUILD IS $days DAYS OLD — PLEASE UPDATE TO THE LATEST '
      'SHEPHERD. SENSING AND ALERTS ARE UNAFFECTED.';
}
