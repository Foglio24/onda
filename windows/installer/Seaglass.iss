; Seaglass for Windows's installer (Inno Setup 6), built by .github/workflows/windows.yml around
; the app image Compose makes (Seaglass.exe, app\, runtime\):
;   iscc /DAppVersion=1.0.0 /DAppDir=<app image> /O<output folder> installer\Seaglass.iss
; It installs for the current user, without administrator rights (so updates install silently),
; asks whether to put an icon on the desktop, registers the address the account page uses to
; hand the sign-in back to the app, and leaves the library (%APPDATA%\Seaglass) when uninstalling.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppDir
  #define AppDir "..\app\build\compose\binaries\main-release\app\Seaglass"
#endif

[Setup]
AppId={{8C4E2A71-5B3D-4F0A-9E62-1D7C3B9A4E58}
AppName=Seaglass
AppVersion={#AppVersion}
AppVerName=Seaglass {#AppVersion}
AppPublisher=Seaglass
AppPublisherURL=https://seaglass.mystudioappweb.com
AppSupportURL=https://github.com/Foglio24/onda/issues
AppUpdatesURL=https://github.com/Foglio24/onda/releases?q=windows-v
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Seaglass
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputBaseFilename=Seaglass-Setup
SetupIconFile=..\app\src\main\resources\icon.ico
UninstallDisplayIcon={app}\Seaglass.exe
UninstallDisplayName=Seaglass
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1809 or later (Windows 11 included).
MinVersion=10.0.17763
CloseApplications=force
RestartApplications=no
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[CustomMessages]
italian.AutoStart=Avvia Seaglass con Windows (nell'area di notifica)
english.AutoStart=Start Seaglass with Windows (in the notification area)
french.AutoStart=Lancer Seaglass avec Windows (dans la zone de notification)
spanish.AutoStart=Iniciar Seaglass con Windows (en el área de notificación)
german.AutoStart=Seaglass mit Windows starten (im Infobereich)
portuguese.AutoStart=Iniciar o Seaglass com o Windows (na área de notificação)
japanese.AutoStart=Windows の起動時に Seaglass を開始（通知領域）
russian.AutoStart=Запускать Seaglass вместе с Windows (в области уведомлений)
turkish.AutoStart=Seaglass'ı Windows ile başlat (bildirim alanında)

[Tasks]
; The desktop icon is a choice, checked by default; starting with Windows is unchecked.
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "{cm:AutoStart}"; Flags: unchecked

[InstallDelete]
; An update replaces the app and its Java runtime whole: no old library is left beside the new one.
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\runtime"

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Seaglass"; Filename: "{app}\Seaglass.exe"
Name: "{autodesktop}\Seaglass"; Filename: "{app}\Seaglass.exe"; Tasks: desktopicon

[Registry]
; The account page hands the sign-in back on com.onda.player.auth:/callback (as on the iPhone).
Root: HKCU; Subkey: "Software\Classes\com.onda.player.auth"; ValueType: string; ValueName: ""; ValueData: "URL:Seaglass"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\com.onda.player.auth"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\com.onda.player.auth\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\Seaglass.exe,0"
Root: HKCU; Subkey: "Software\Classes\com.onda.player.auth\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Seaglass.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Seaglass"; ValueData: """{app}\Seaglass.exe"" --background"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
; After a normal install: a checkbox to open Seaglass. After a silent update (the app's own): it opens again.
Filename: "{app}\Seaglass.exe"; Description: "{cm:LaunchProgram,Seaglass}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Seaglass.exe"; Flags: nowait skipifnotsilent; Check: ShouldLaunch

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v Seaglass /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"

[Code]
{ CI installs silently to test the installer with /NOLAUNCH: nothing is opened then. }
function ShouldLaunch: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/NOLAUNCH') = 0 then
      Result := False;
end;
