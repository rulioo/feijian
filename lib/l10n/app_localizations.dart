import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Feijian'**
  String get appName;

  /// No description provided for @navDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get navDevices;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @myDeviceSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'THIS DEVICE'**
  String get myDeviceSectionTitle;

  /// No description provided for @youLabel.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get youLabel;

  /// No description provided for @editDeviceName.
  ///
  /// In en, this message translates to:
  /// **'Change your device name'**
  String get editDeviceName;

  /// No description provided for @devicesOnNetworkCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{NO OTHER DEVICES} =1{ON THE NETWORK · 1} other{ON THE NETWORK · {count}}}'**
  String devicesOnNetworkCount(int count);

  /// No description provided for @statusOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get statusOnline;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get statusOffline;

  /// No description provided for @scanningTitle.
  ///
  /// In en, this message translates to:
  /// **'Scanning for devices on your network...'**
  String get scanningTitle;

  /// No description provided for @scanningHintIntro.
  ///
  /// In en, this message translates to:
  /// **'Make sure:'**
  String get scanningHintIntro;

  /// No description provided for @scanningHintRunning.
  ///
  /// In en, this message translates to:
  /// **'Other devices have Feijian running'**
  String get scanningHintRunning;

  /// No description provided for @scanningHintSameNetwork.
  ///
  /// In en, this message translates to:
  /// **'You are on the same Wi-Fi or LAN'**
  String get scanningHintSameNetwork;

  /// No description provided for @scanningHintFirewall.
  ///
  /// In en, this message translates to:
  /// **'Your firewall allows Feijian (TCP and UDP port {port})'**
  String scanningHintFirewall(int port);

  /// No description provided for @addDeviceByIp.
  ///
  /// In en, this message translates to:
  /// **'Add device by IP'**
  String get addDeviceByIp;

  /// No description provided for @rescan.
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get rescan;

  /// No description provided for @sendFileAction.
  ///
  /// In en, this message translates to:
  /// **'Send a file'**
  String get sendFileAction;

  /// No description provided for @addDeviceDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add device by IP'**
  String get addDeviceDialogTitle;

  /// No description provided for @addDeviceFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'IP address'**
  String get addDeviceFieldLabel;

  /// No description provided for @addDeviceFieldHint.
  ///
  /// In en, this message translates to:
  /// **'192.168.1.100'**
  String get addDeviceFieldHint;

  /// No description provided for @addDeviceInvalidIp.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid IP address'**
  String get addDeviceInvalidIp;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get actionAdd;

  /// No description provided for @chatEmptyWithPeer.
  ///
  /// In en, this message translates to:
  /// **'No messages yet. Say hello to {name}.'**
  String chatEmptyWithPeer(String name);

  /// No description provided for @chatEmptyNoPeer.
  ///
  /// In en, this message translates to:
  /// **'Select a device on the left to start chatting.'**
  String get chatEmptyNoPeer;

  /// No description provided for @composerHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get composerHint;

  /// No description provided for @attachFile.
  ///
  /// In en, this message translates to:
  /// **'Send a file'**
  String get attachFile;

  /// No description provided for @attachFolder.
  ///
  /// In en, this message translates to:
  /// **'Send a folder'**
  String get attachFolder;

  /// No description provided for @sendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get sendMessage;

  /// No description provided for @peerOfflineNotice.
  ///
  /// In en, this message translates to:
  /// **'{name} is offline. Messages and files will be sent when they are back.'**
  String peerOfflineNotice(String name);

  /// No description provided for @backTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get backTooltip;

  /// No description provided for @moreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get moreActions;

  /// No description provided for @viewPeerInfo.
  ///
  /// In en, this message translates to:
  /// **'Device info'**
  String get viewPeerInfo;

  /// No description provided for @clearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get clearHistory;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsSectionProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsSectionProfile;

  /// No description provided for @settingsSectionFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get settingsSectionFiles;

  /// No description provided for @settingsSectionNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsSectionNetwork;

  /// No description provided for @settingsSectionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsSectionNotifications;

  /// No description provided for @settingsSectionSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsSectionSystem;

  /// No description provided for @settingsSectionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsSectionLanguage;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsSectionAbout;

  /// No description provided for @settingsDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get settingsDisplayName;

  /// No description provided for @settingsDeviceIcon.
  ///
  /// In en, this message translates to:
  /// **'Device icon'**
  String get settingsDeviceIcon;

  /// No description provided for @settingsAvatar.
  ///
  /// In en, this message translates to:
  /// **'Avatar'**
  String get settingsAvatar;

  /// No description provided for @settingsDownloadFolder.
  ///
  /// In en, this message translates to:
  /// **'Download folder'**
  String get settingsDownloadFolder;

  /// No description provided for @settingsAutoAccept.
  ///
  /// In en, this message translates to:
  /// **'Auto-accept files'**
  String get settingsAutoAccept;

  /// No description provided for @settingsAutoAcceptOff.
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get settingsAutoAcceptOff;

  /// No description provided for @settingsAutoAcceptImages.
  ///
  /// In en, this message translates to:
  /// **'Accept images under {size} MB'**
  String settingsAutoAcceptImages(int size);

  /// No description provided for @settingsAutoAcceptTrusted.
  ///
  /// In en, this message translates to:
  /// **'Accept everything from trusted devices'**
  String get settingsAutoAcceptTrusted;

  /// No description provided for @settingsListenPort.
  ///
  /// In en, this message translates to:
  /// **'Listen port'**
  String get settingsListenPort;

  /// No description provided for @settingsMulticastAddress.
  ///
  /// In en, this message translates to:
  /// **'Multicast address'**
  String get settingsMulticastAddress;

  /// No description provided for @settingsEnabledInterfaces.
  ///
  /// In en, this message translates to:
  /// **'Network interfaces'**
  String get settingsEnabledInterfaces;

  /// No description provided for @settingsEnabledInterfacesHint.
  ///
  /// In en, this message translates to:
  /// **'Uncheck virtual adapters (Hyper-V, VMware, WSL) if some devices are missing from the list.'**
  String get settingsEnabledInterfacesHint;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Message notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsLaunchAtStartup.
  ///
  /// In en, this message translates to:
  /// **'Launch at startup'**
  String get settingsLaunchAtStartup;

  /// No description provided for @settingsMinimizeToTray.
  ///
  /// In en, this message translates to:
  /// **'Close to tray'**
  String get settingsMinimizeToTray;

  /// No description provided for @settingsBackgroundService.
  ///
  /// In en, this message translates to:
  /// **'Stay reachable in background'**
  String get settingsBackgroundService;

  /// No description provided for @settingsBackgroundServiceHint.
  ///
  /// In en, this message translates to:
  /// **'Shows a permanent notification. Without it, messages cannot be received while the app is in the background.'**
  String get settingsBackgroundServiceHint;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get settingsLanguage;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// No description provided for @settingsProtocolVersion.
  ///
  /// In en, this message translates to:
  /// **'Protocol version'**
  String get settingsProtocolVersion;

  /// No description provided for @settingsLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open source licenses'**
  String get settingsLicenses;

  /// No description provided for @deviceIconDesktop.
  ///
  /// In en, this message translates to:
  /// **'Desktop'**
  String get deviceIconDesktop;

  /// No description provided for @deviceIconLaptop.
  ///
  /// In en, this message translates to:
  /// **'Laptop'**
  String get deviceIconLaptop;

  /// No description provided for @deviceIconPhone.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get deviceIconPhone;

  /// No description provided for @deviceIconTablet.
  ///
  /// In en, this message translates to:
  /// **'Tablet'**
  String get deviceIconTablet;

  /// No description provided for @notImplementedTitle.
  ///
  /// In en, this message translates to:
  /// **'Not implemented yet'**
  String get notImplementedTitle;

  /// No description provided for @notImplementedBody.
  ///
  /// In en, this message translates to:
  /// **'This arrives in a later milestone.'**
  String get notImplementedBody;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
