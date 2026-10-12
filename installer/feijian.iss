; Feijian -- Windows installer.
;
; Built by tool/release_windows.sh, which stages the built application, copies
; the C++ runtime in beside it, and then compiles this script against that
; staging directory. So a release is one command, and the zip and the installer
; it produces are the same bytes at the same version number.
;
;   MSYS_NO_PATHCONV=1 ISCC.exe /DAppVersion=1.0.12 /DAppFullVersion=1.0.12+18 feijian.iss
;
; That `MSYS_NO_PATHCONV=1` is not decoration. Git Bash rewrites an argument
; that looks like a path, and `/DAppVersion=1.0.12` looks like one: without the
; prefix the compiler receives `C:/Program Files/Git/DAppVersion=1.0.12` and
; quietly falls back to the defaults below.
;
; Why an installer at all, given the zip: the zip works, but only for someone
; who knows to unpack it whole. Copying just `feijian.exe` and the DLLs beside
; it out of a build folder produces a program that will not start -- the Dart
; code, the fonts and the ICU data live in the `data/` directory next to the
; executable, and the C++ runtime DLLs are not in the build output at all. The
; installer puts all of it where it belongs, adds the Start menu entry, opens
; the firewall, and needs nothing explained.

#ifndef AppVersion
  ; Only reached when this file is compiled by hand. The real value comes from
  ; tool/release_windows.sh, which bumps the version and passes both defines.
  #define AppVersion "0.0.0"
#endif
#ifndef AppFullVersion
  #define AppFullVersion AppVersion
#endif

[Setup]
; A fixed GUID, and it must stay fixed. Inno identifies an installed
; application by it: a different one on the next release means the new version
; installs *alongside* the old one instead of replacing it, and the machine
; ends up with two Feijians and two sets of Start menu entries.
AppId={{9F3C7A14-2D68-4E05-B1C7-6A84E29D3B70}
AppName=Feijian
AppVersion={#AppVersion}
AppVerName=Feijian {#AppVersion}

; Setup derives the executable's own version resource from `AppVersion`, but
; only when that reads as four numbers -- and `1.0.12` is three. Left alone, the
; "File version" field in the installer's Properties dialog comes out blank
; while "Product version" beside it is filled in, which looks like something
; failed. The `.0` below is what makes it four.
VersionInfoVersion={#AppVersion}.0
AppPublisher=Beijing Sailanbo Technology Development Co., Ltd.
AppCopyright=Copyright (C) 2026 Beijing Sailanbo Technology Development Co., Ltd.
DefaultDirName={autopf}\Feijian
DefaultGroupName=Feijian
DisableProgramGroupPage=yes
UninstallDisplayName=Feijian {#AppVersion}
UninstallDisplayIcon={app}\feijian.exe
OutputDir=..\dist
OutputBaseFilename=feijian-{#AppFullVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; Needed for the firewall rules below, and for nothing else. The program does
; not want to run elevated -- see the `runasoriginaluser` on the [Run] entry at
; the end of this file, which is what keeps it from doing so.
PrivilegesRequired=admin

; The application itself is x64. `x64compatible` (Inno 6.3 and later) also
; permits ARM64 Windows, where it runs under emulation. Checked against the
; compiler actually installed: Inno Setup 6.7.3.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; A running Feijian holds this mutex -- `kMutexName` in
; windows/runner/single_instance.h -- and Setup checks for it before touching
; any files. That turns the worst upgrade case into a sentence the user can act
; on ("close Feijian, then run this again") instead of a half-finished install.
;
; It cannot close the window for them. Closing to the tray is implemented by
; answering `WM_CLOSE` with a hide, and a `WM_CLOSE` is exactly what Setup
; sends, so the automatic close would be answered by the window disappearing
; and the process carrying on. Hence the message rather than a silent fix, and
; hence the tray menu's Quit being the way out.
;
; The two spellings must match exactly: no `Local\` prefix here unless the
; header grows one too.
AppMutex=Feijian.SingleInstance

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole staging directory, which is the point of the exercise: `data/` holds
; the compiled Dart program, the ICU data and every asset, and the three
; msvcp140/vcruntime140 DLLs beside the exe are the C++ runtime. `recursesubdirs`
; and `createallsubdirs` are what carry `data/flutter_assets/**` across.
;
; `ignoreversion` because an upgrade replaces files whose version number has
; changed -- which is all of them, every time. Without it Setup asks the user to
; confirm each overwrite it considers a downgrade.
Source: "..\build\feijian-stage\feijian\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Feijian"; Filename: "{app}\feijian.exe"
Name: "{autodesktop}\Feijian"; Filename: "{app}\feijian.exe"; Tasks: desktopicon

[Run]
; `runasoriginaluser` is load-bearing. Setup is elevated, so a program launched
; from here without it starts elevated too -- and Windows' UIPI refuses
; drag-and-drop from a normal, non-elevated Explorer window into an elevated
; one. The user would install Feijian, drag a file onto it, and watch nothing
; happen, with nothing on screen to connect the two. Dropping files in is the
; main way files get sent.
Filename: "{app}\feijian.exe"; Description: "{cm:LaunchProgram,Feijian}"; Flags: nowait postinstall skipifsilent runasoriginaluser

; Deliberately absent: anything that deletes the user's data.
;
; %APPDATA%\com.feijian\Feijian\ holds the message history, the settings and the
; device id that identifies this machine to every peer on the network. An
; uninstall is a decision about the program, not about that. Removing it is a
; thing a person can do by hand in Explorer, which is where a decision with
; this consequence belongs.

[Code]
const
  FirewallRuleName = 'Feijian';

  // `kDiscoveryPort` in lib/core/constants.dart. UDP carries discovery, TCP
  // carries transfers; nothing else in the program opens a port.
  FirewallPort = '24250';

  // Named for two reasons. A line that starts with `#13#10` is read as a
  // preprocessor directive rather than a character code ("unknown preprocessor
  // directive"), and a line that starts with `[` is read as a section header
  // ("invalid section tag") -- which is why nothing below wraps an argument
  // list onto its own line and why `Format(..., [x])` is not used here. Both
  // are one-line mistakes that cost a compile to find.
  LineBreak = #13#10;

// Runs a netsh command and reports, but does not propagate, whether it worked.
//
// Ignoring the outcome is the point rather than laziness, and it is why this is
// here instead of a line in [Run]. Every one of these commands has a legitimate
// reason to exit non-zero: the delete finds nothing to delete on a first
// install, and the adds fail outright when the Windows Firewall service is
// stopped or the rules are managed by group policy. A machine where the rules
// cannot be added is still a machine where the program installed successfully.
// Setup's [Run] section has no way to say that: `ignoreerrors` is a [Files]
// flag and is not accepted there.
//
// The log keeps the exit codes, because "is the firewall rule there" is a
// question someone will eventually have to answer, and this is the only record
// of whether Setup tried.
function RunNetsh(const Parameters: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\netsh.exe'), Parameters, '', SW_HIDE,
                 ewWaitUntilTerminated, ResultCode);
  if Result and (ResultCode <> 0) then
    Result := False;
  if Result then
    Log(Format('netsh %s -> ok', [Parameters]))
  else
    Log(Format('netsh %s -> failed (exit code %d)', [Parameters, ResultCode]));
end;

// Brings the firewall rules to the state they should be in: the two below, and
// nothing else named Feijian.
//
// The delete comes first, and it is idempotence rather than tidiness.
// `netsh advfirewall firewall add rule` appends a rule every time it is run --
// it does not replace one of the same name -- so installing twice, or
// installing over a version that already added them, would leave two rules,
// then three. Deleting first means the result depends on this script and not on
// what the machine happened to be in before.
//
// Returns whether the rules are in place afterwards.
function SetFirewallRules(const Add: Boolean): Boolean;
begin
  RunNetsh('advfirewall firewall delete rule name="' + FirewallRuleName + '"');
  if not Add then
  begin
    Result := True;
    Exit;
  end;

  // Private and domain only, and this is the whole reason the rules are written
  // out by hand rather than left to the "allow on all networks" prompt Windows
  // shows on first run. That prompt also allows the public profile -- the one
  // that applies in a cafe, an airport or a hotel -- and Feijian's answer to a
  // stranger on that network would be to announce itself and listen.
  Result := RunNetsh('advfirewall firewall add rule name="' + FirewallRuleName
    + '" dir=in action=allow protocol=UDP localport=' + FirewallPort
    + ' profile=private,domain');
  if not RunNetsh('advfirewall firewall add rule name="' + FirewallRuleName
      + '" dir=in action=allow protocol=TCP localport=' + FirewallPort
      + ' profile=private,domain') then
    Result := False;
end;

procedure CurStepChanged(const CurStep: TSetupStep);
begin
  // Before the [Run] entry launches the program, so the copy the user is looking
  // at can find the other machines right away rather than after a firewall
  // prompt.
  if CurStep = ssPostInstall then
  begin
    if not SetFirewallRules(True) then
    begin
      // Said out loud rather than only written to the log, because of what the
      // failure looks like from the outside: the program installs, starts, and
      // then finds no devices no matter what the user tries. Nothing on screen
      // would connect that to a rule that was never added, and the question
      // would be asked of the wrong thing entirely.
      //
      // A warning and not an abort: the program is already on the disk and
      // works on the outbound side, and an administrator can add the rules by
      // hand from the command in the message.
      SuppressibleMsgBox(
        'Feijian could not open its firewall rules, so other devices on this '
        + 'network may not be able to find or reach this computer.'
        + LineBreak + LineBreak
        + 'The program is installed and will work for sending. An '
        + 'administrator can add the rules from an elevated command prompt:'
        + LineBreak + LineBreak
        + 'netsh advfirewall firewall add rule name="Feijian" dir=in '
        + 'action=allow protocol=UDP localport=' + FirewallPort
        + ' profile=private,domain'
        + LineBreak
        + 'netsh advfirewall firewall add rule name="Feijian" dir=in '
        + 'action=allow protocol=TCP localport=' + FirewallPort
        + ' profile=private,domain',
        mbInformation, MB_OK, IDOK);
    end;
  end;
end;

procedure CurUninstallStepChanged(const CurUninstallStep: TUninstallStep);
begin
  // Removing the program should remove the hole it opened. A reinstall after an
  // uninstall then starts from the same place a first install does.
  if CurUninstallStep = usUninstall then
    SetFirewallRules(False);
end;
