import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// How big a file is, in the units a person reads — design.md §6.3.
///
/// Binary units (1024), not decimal: the number the card shows has to match the
/// number the file manager will show for the same file, and every desktop file
/// manager counts in KiB while calling them KB. A decimal 1.0 MB over a file
/// Explorer calls 1.02 MB would read as a transfer that lost 2%.
///
/// The unit suffixes are not localized. KB/MB/GB are the same string in every
/// language this app ships or is likely to, and `l10n` has no business inventing
/// translations for them — the one part that does vary, how the number itself is
/// written and grouped, goes through [NumberFormat] with the app's locale.
///
/// Bytes are the exception and go through the ARB, because "1 byte" and
/// "2 bytes" are a real singular and plural in English and a language we add
/// later will have its own rule.
String formatBytes(AppLocalizations l10n, int bytes) {
  if (bytes < 0) {
    return l10n.fileSizeBytes(0);
  }
  if (bytes < 1024) {
    return l10n.fileSizeBytes(bytes);
  }

  const List<String> units = <String>['KB', 'MB', 'GB', 'TB', 'PB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }

  // One decimal below ten, none above it: `1.4 MB` and `156 MB` are both the
  // precision the reader wants, and `156.3 MB` is noise. Rounded first, because
  // 9.97 would otherwise be shown as `10.0` with the decimal rule of the value
  // it no longer is.
  final bool oneDecimal = value < 9.95;
  final String number = NumberFormat(
    oneDecimal ? '#,##0.0' : '#,##0',
    l10n.localeName,
  ).format(oneDecimal ? (value * 10).round() / 10 : value.roundToDouble());

  return '$number ${units[unit]}';
}
