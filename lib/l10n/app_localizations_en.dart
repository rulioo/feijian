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
  String get discoveryFailedTitle => 'Device discovery is not running';

  @override
  String get discoveryFailedBody => 'This device could not open the port it listens on, so the list below cannot fill no matter who is on your network. Press Rescan to try again.';

  @override
  String get discoveryFailedDetail => 'Details';

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
  String get messageDeleteFailed => 'Could not delete this message';

  @override
  String get actionDelete => 'Delete';

  @override
  String clearHistoryConfirm(String name) {
    return 'Delete every message in this conversation from this device? $name keeps their own copy.';
  }

  @override
  String get historyCleared => 'History cleared';

  @override
  String get historyClearFailed => 'Could not clear the history';

  @override
  String fileSizeBytes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count bytes',
      one: '1 byte',
    );
    return '$_temp0';
  }

  @override
  String filePercent(int percent) {
    return '$percent%';
  }

  @override
  String get transferWaiting => 'Waiting';

  @override
  String get transferAwaitingAnswer => 'Waiting for your answer';

  @override
  String get transferDone => 'Completed';

  @override
  String get transferFailed => 'Failed';

  @override
  String get transferCancelled => 'Cancelled';

  @override
  String get transferDeclined => 'Declined';

  @override
  String get fileOpen => 'Open';

  @override
  String get fileSaveAs => 'Save as...';

  @override
  String get fileOpenFailed => 'There is no app on this device that can open this file.';

  @override
  String get fileMissing => 'The file is no longer on this device.';

  @override
  String get fileSaved => 'Saved';

  @override
  String get fileSaveFailed => 'The file could not be saved.';

  @override
  String get fileCancelled => 'Transfer cancelled';

  @override
  String fileSendFailed(String file) {
    return 'Could not send $file.';
  }

  @override
  String get fileTooManyTransfers => 'Too many files are already moving. Wait for one to finish and try again.';

  @override
  String get fileDropToSend => 'Drop to send';

  @override
  String get fileOfferTitle => 'Incoming file or folder';

  @override
  String fileOfferBody(String name, String file, String size) {
    return '$name wants to send you $file ($size)';
  }

  @override
  String get fileAccept => 'Accept';

  @override
  String get fileDecline => 'Decline';

  @override
  String get fileActionResultAccept => 'Accepted';

  @override
  String get fileActionResultDecline => 'Declined';

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
  String get settingsConfirmReceiving => 'Confirm before receiving';

  @override
  String get settingsConfirmReceivingHint => 'Ask before accepting a file or photo. Off means anything sent to this device is received straight away.';

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
  String get settingsCopyright => '© 2026 Beijing Sailanbo Technology Development Co., Ltd.';

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

  @override
  String folderFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get folderTooManyFiles => 'This folder holds too many files to describe in one go. Send a part of it instead.';

  @override
  String get folderUnreadable => 'That folder cannot be read on this device.';

  @override
  String folderSomeFilesFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files in this folder did not arrive',
      one: '1 file in this folder did not arrive',
    );
    return '$_temp0';
  }

  @override
  String folderMoreFiles(int count) {
    return '…and $count more';
  }

  @override
  String get trayMenuOpen => 'Open';

  @override
  String get trayMenuStatus => 'Status';

  @override
  String get trayMenuQuit => 'Quit';

  @override
  String trayStatusOnline(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices online',
      one: '1 device online',
      zero: 'No devices online',
    );
    return '$_temp0';
  }

  @override
  String get trayHintTitle => 'Feijian';

  @override
  String get trayHintBody => 'Feijian is still running so it can keep receiving files. Right-click the tray icon to quit.';
}
