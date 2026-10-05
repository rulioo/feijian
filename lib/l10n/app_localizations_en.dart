import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Feijian';

  @override
  String get navDevices => 'Devices';

  @override
  String get navSettings => 'Settings';

  @override
  String get myDeviceSectionTitle => 'THIS DEVICE';

  @override
  String get youLabel => 'You';

  @override
  String get editDeviceName => 'Change your device name';

  @override
  String devicesOnNetworkCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'ON THE NETWORK · $count',
      one: 'ON THE NETWORK · 1',
      zero: 'NO OTHER DEVICES',
    );
    return '$_temp0';
  }

  @override
  String get statusOnline => 'Online';

  @override
  String get statusOffline => 'Offline';

  @override
  String get scanningTitle => 'Scanning for devices on your network...';

  @override
  String get scanningHintIntro => 'Make sure:';

  @override
  String get scanningHintRunning => 'Other devices have Feijian running';

  @override
  String get scanningHintSameNetwork => 'You are on the same Wi-Fi or LAN';

  @override
  String scanningHintFirewall(int port) {
    return 'Your firewall allows Feijian (TCP and UDP port $port)';
  }

  @override
  String get addDeviceByIp => 'Add device by IP';

  @override
  String get rescan => 'Rescan';

  @override
  String get sendFileAction => 'Send a file';

  @override
  String get addDeviceDialogTitle => 'Add device by IP';

  @override
  String get addDeviceFieldLabel => 'IP address';

  @override
  String get addDeviceFieldHint => '192.168.1.100';

  @override
  String get addDeviceInvalidIp => 'Enter a valid IP address';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionAdd => 'Add';

  @override
  String addDeviceConnecting(String target) {
    return 'Connecting to $target...';
  }

  @override
  String addDeviceAdded(String name) {
    return 'Added $name';
  }

  @override
  String addDeviceUnreachable(String target) {
    return 'Could not reach a device at $target. Check that Feijian is running on it and that its address has not changed.';
  }

  @override
  String get addDeviceSelf => 'That address is this device.';

  @override
  String get addDeviceOffline => 'Cannot add a device: the network service is not running.';

  @override
  String get removeDevice => 'Remove device';

  @override
  String removeDeviceConfirm(String name) {
    return 'Remove $name from the device list? The conversation stays on this device.';
  }

  @override
  String deviceRemoved(String name) {
    return 'Removed $name';
  }

  @override
  String chatEmptyWithPeer(String name) {
    return 'No messages yet. Say hello to $name.';
  }

  @override
  String get chatEmptyNoPeer => 'Select a device on the left to start chatting.';

  @override
  String get composerHint => 'Type a message...';

  @override
  String get attachFile => 'Send a file';

  @override
  String get attachFolder => 'Send a folder';

  @override
  String get sendMessage => 'Send';

  @override
  String peerOfflineNotice(String name) {
    return '$name is offline. Messages and files will be sent when they are back.';
  }

  @override
  String get backTooltip => 'Back';

  @override
  String get moreActions => 'More actions';

  @override
  String get viewPeerInfo => 'Device info';

  @override
  String get clearHistory => 'Clear history';

  @override
  String get messageActionCopy => 'Copy text';

  @override
  String get messageActionDelete => 'Delete for me';

  @override
  String get messageCopied => 'Copied';

  @override
  String get messageDeleted => 'Deleted from this device';

  @override
  String get actionDelete => 'Delete';

  @override
  String clearHistoryConfirm(String name) {
    return 'Delete every message in this conversation from this device? $name keeps their own copy.';
  }

  @override
  String get historyCleared => 'History cleared';

  @override
  String get peerInfoId => 'Device ID';

  @override
  String get peerInfoAddress => 'Address';

  @override
  String get peerInfoType => 'Type';

  @override
  String get peerInfoSystem => 'System';

  @override
  String get peerInfoStatus => 'Status';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionProfile => 'Profile';

  @override
  String get settingsSectionFiles => 'Files';

  @override
  String get settingsSectionNetwork => 'Network';

  @override
  String get settingsSectionNotifications => 'Notifications';

  @override
  String get settingsSectionSystem => 'System';

  @override
  String get settingsSectionLanguage => 'Language';

  @override
  String get settingsSectionAbout => 'About';

  @override
  String get settingsDisplayName => 'Display name';

  @override
  String get settingsDeviceIcon => 'Device icon';

  @override
  String get settingsAvatar => 'Avatar';

  @override
  String get settingsDownloadFolder => 'Download folder';

  @override
  String get settingsAutoAccept => 'Auto-accept files';

  @override
  String get settingsAutoAcceptOff => 'Ask every time';

  @override
  String settingsAutoAcceptImages(int size) {
    return 'Accept images under $size MB';
  }

  @override
  String get settingsAutoAcceptTrusted => 'Accept everything from trusted devices';

  @override
  String get settingsListenPort => 'Listen port';

  @override
  String get settingsMulticastAddress => 'Multicast address';

  @override
  String get settingsEnabledInterfaces => 'Network interfaces';

  @override
  String get settingsEnabledInterfacesHint => 'Uncheck virtual adapters (Hyper-V, VMware, WSL) if some devices are missing from the list.';

  @override
  String get settingsNotifications => 'Message notifications';

  @override
  String get settingsLaunchAtStartup => 'Launch at startup';

  @override
  String get settingsMinimizeToTray => 'Close to tray';

  @override
  String get settingsBackgroundService => 'Stay reachable in background';

  @override
  String get settingsBackgroundServiceHint => 'Shows a permanent notification. Without it, messages cannot be received while the app is in the background.';

  @override
  String get settingsLanguage => 'App language';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsProtocolVersion => 'Protocol version';

  @override
  String get settingsLicenses => 'Open source licenses';

  @override
  String get deviceIconDesktop => 'Desktop';

  @override
  String get deviceIconLaptop => 'Laptop';

  @override
  String get deviceIconPhone => 'Phone';

  @override
  String get deviceIconTablet => 'Tablet';

  @override
  String get deviceTypeWindows => 'Windows';

  @override
  String get deviceTypeAndroid => 'Android';

  @override
  String get deviceTypeIos => 'iOS';

  @override
  String get deviceTypeUnknown => 'Unknown';

  @override
  String get messageStatusPending => 'Waiting to send';

  @override
  String get messageStatusSent => 'Sent';

  @override
  String get messageStatusDelivered => 'Delivered';

  @override
  String get messageStatusFailed => 'Not sent — tap to try again';

  @override
  String get actionRetry => 'Try again';

  @override
  String get historyLoadFailed => 'Could not load this conversation.';

  @override
  String get sendUnavailable => 'Cannot send messages: the network service is not running.';

  @override
  String get loadingOlderMessages => 'Loading earlier messages...';

  @override
  String unreadMessagesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unread messages',
      one: '1 unread message',
    );
    return '$_temp0';
  }

  @override
  String get notImplementedTitle => 'Not implemented yet';

  @override
  String get notImplementedBody => 'This arrives in a later milestone.';

  @override
  String get close => 'Close';
}
