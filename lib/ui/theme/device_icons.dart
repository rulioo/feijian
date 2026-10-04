import 'package:flutter/material.dart';

import '../../core/models/peer.dart';

/// Maps the wire-level [DeviceIcon] to a Material icon.
///
/// Using Material glyphs rather than bundled assets: they are already in the
/// app, scale cleanly, and adapt to the theme's foreground colour.
extension DeviceIconGlyph on DeviceIcon {
  IconData get glyph => switch (this) {
    DeviceIcon.desktop => Icons.desktop_windows_outlined,
    DeviceIcon.laptop => Icons.laptop_mac_outlined,
    DeviceIcon.phone => Icons.smartphone_outlined,
    DeviceIcon.tablet => Icons.tablet_mac_outlined,
  };

  IconData get filledGlyph => switch (this) {
    DeviceIcon.desktop => Icons.desktop_windows,
    DeviceIcon.laptop => Icons.laptop_mac,
    DeviceIcon.phone => Icons.smartphone,
    DeviceIcon.tablet => Icons.tablet_mac,
  };
}
