// Stub implementation — used on non-web platforms (iOS, Android, desktop).
// Real download only works on web (dart:html). On mobile, prefer the Python logger
// or add path_provider + share_plus later.

bool get isWebCsvSupported => false;

void saveCsvFile(String filename, String csvContent) {
  // No-op on non-web platforms. The UI shows a toast explaining this.
}
