/// Layout constants shared across pages — design.md §6.1.
library;

/// At or above this width the app shows the two-pane master/detail layout
/// (device list + conversation side by side). Below it, the conversation is a
/// pushed full-screen page instead — which is what a phone needs.
const double kTwoPaneMinWidth = 900;

/// Width of the device list pane in the two-pane layout.
const double kDevicePaneWidth = 280;
