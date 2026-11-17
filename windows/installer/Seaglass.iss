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

italian.VCRuntimeTitle=Runtime di Microsoft Visual C++
italian.VCRuntimeDownloading=Per il karaoke Seaglass ha bisogno del runtime di Microsoft Visual C++. Lo scarico e lo installo (Windows può chiedere il permesso).
italian.VCRuntimeFailed=Il runtime di Microsoft Visual C++ non è stato installato. Seaglass funziona lo stesso, ma il karaoke potrebbe non partire finché non lo installi da https://aka.ms/vs/17/release/vc_redist.x64.exe.
english.VCRuntimeTitle=Microsoft Visual C++ runtime
english.VCRuntimeDownloading=Karaoke needs the Microsoft Visual C++ runtime. Downloading and installing it (Windows may ask for permission).
english.VCRuntimeFailed=The Microsoft Visual C++ runtime wasn't installed. Seaglass works without it, but karaoke may not start until you install it from https://aka.ms/vs/17/release/vc_redist.x64.exe.
french.VCRuntimeTitle=Runtime Microsoft Visual C++
french.VCRuntimeDownloading=Le karaoké a besoin du runtime Microsoft Visual C++. Téléchargement et installation en cours (Windows peut demander l'autorisation).
french.VCRuntimeFailed=Le runtime Microsoft Visual C++ n'a pas été installé. Seaglass fonctionne quand même, mais le karaoké risque de ne pas démarrer tant que vous ne l'installez pas depuis https://aka.ms/vs/17/release/vc_redist.x64.exe.
spanish.VCRuntimeTitle=Runtime de Microsoft Visual C++
spanish.VCRuntimeDownloading=El karaoke necesita el runtime de Microsoft Visual C++. Se descarga y se instala (Windows puede pedir permiso).
spanish.VCRuntimeFailed=No se instaló el runtime de Microsoft Visual C++. Seaglass funciona igualmente, pero el karaoke puede no iniciarse hasta que lo instales desde https://aka.ms/vs/17/release/vc_redist.x64.exe.
german.VCRuntimeTitle=Microsoft Visual C++-Laufzeit
german.VCRuntimeDownloading=Karaoke benötigt die Microsoft Visual C++-Laufzeit. Sie wird heruntergeladen und installiert (Windows fragt eventuell nach einer Berechtigung).
german.VCRuntimeFailed=Die Microsoft Visual C++-Laufzeit wurde nicht installiert. Seaglass funktioniert trotzdem, aber Karaoke startet möglicherweise erst, wenn Sie sie von https://aka.ms/vs/17/release/vc_redist.x64.exe installieren.
portuguese.VCRuntimeTitle=Runtime do Microsoft Visual C++
portuguese.VCRuntimeDownloading=O karaoke precisa do runtime do Microsoft Visual C++. A transferir e a instalar (o Windows pode pedir permissão).
portuguese.VCRuntimeFailed=O runtime do Microsoft Visual C++ não foi instalado. O Seaglass funciona na mesma, mas o karaoke pode não arrancar até o instalar a partir de https://aka.ms/vs/17/release/vc_redist.x64.exe.
japanese.VCRuntimeTitle=Microsoft Visual C++ ランタイム
japanese.VCRuntimeDownloading=カラオケには Microsoft Visual C++ ランタイムが必要です。ダウンロードしてインストールします(Windows が許可を求める場合があります)。
japanese.VCRuntimeFailed=Microsoft Visual C++ ランタイムはインストールされませんでした。Seaglass は動作しますが、https://aka.ms/vs/17/release/vc_redist.x64.exe からインストールするまでカラオケが始まらない場合があります。
russian.VCRuntimeTitle=Среда выполнения Microsoft Visual C++
russian.VCRuntimeDownloading=Для караоке нужна среда выполнения Microsoft Visual C++. Она будет загружена и установлена (Windows может запросить разрешение).
russian.VCRuntimeFailed=Среда выполнения Microsoft Visual C++ не установлена. Seaglass работает и без неё, но караоке может не запускаться, пока вы не установите её с https://aka.ms/vs/17/release/vc_redist.x64.exe.
turkish.VCRuntimeTitle=Microsoft Visual C++ çalışma zamanı
turkish.VCRuntimeDownloading=Karaoke için Microsoft Visual C++ çalışma zamanı gerekir. İndirilip kuruluyor (Windows izin isteyebilir).
turkish.VCRuntimeFailed=Microsoft Visual C++ çalışma zamanı kurulmadı. Seaglass onsuz da çalışır, ancak https://aka.ms/vs/17/release/vc_redist.x64.exe adresinden kurana kadar karaoke başlamayabilir.

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
function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
      Result := True;
end;

{ CI installs silently to test the installer with /NOLAUNCH: nothing is opened then. }
function ShouldLaunch: Boolean;
begin
  Result := not HasParam('/NOLAUNCH');
end;

{
  The karaoke's ONNX Runtime library needs the Microsoft Visual C++ 2015-2022 runtime (x64). The app
  image carries Java, FFmpeg (whose JavaCPP build brings the runtime's DLLs along) and ONNX Runtime,
  but not the runtime for ONNX Runtime. So, on a new install, when vcruntime140_1.dll (VS 2019 or
  later) and msvcp140.dll aren't in System32, setup downloads Microsoft's own installer, checks that
  it is signed by Microsoft, and runs it (Windows asks for permission once: it needs administrator
  rights, which Seaglass itself doesn't). A computer that has it is not touched, and neither is an
  update (the app's silent one): see PrepareToInstall.
}
const
  VCRuntimeUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';

var
  VCRuntimePage: TOutputMarqueeProgressWizardPage;

function VCRuntimePresent: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\vcruntime140_1.dll')) and FileExists(ExpandConstant('{sys}\msvcp140.dll'));
end;

function OnVCRuntimeProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  if VCRuntimePage <> nil then
    VCRuntimePage.Animate;
  Result := True;
end;

{ True when [Exe] carries a valid Microsoft signature. }
function SignedByMicrosoft(const Exe: String): Boolean;
var
  Command: String;
  ResultCode: Integer;
begin
  Command := '-NoProfile -NonInteractive -WindowStyle Hidden -Command "' +
    '$s = Get-AuthenticodeSignature -LiteralPath ''' + Exe + '''; ' +
    'if ($s.Status -eq ''Valid'' -and $s.SignerCertificate.Subject -like ''*O=Microsoft Corporation*'') { exit 0 } else { exit 1 }"';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

{ Downloads, checks and installs the runtime; False if any step fails. }
function InstallVCRuntime: Boolean;
var
  Exe: String;
  ResultCode: Integer;
begin
  Result := False;
  Exe := ExpandConstant('{tmp}\vc_redist.x64.exe');
  try
    DownloadTemporaryFile(VCRuntimeUrl, 'vc_redist.x64.exe', '', @OnVCRuntimeProgress);
  except
    Log('VC++ runtime download failed: ' + GetExceptionMessage);
    Exit;
  end;
  if not SignedByMicrosoft(Exe) then
  begin
    Log('The downloaded VC++ runtime installer is not signed by Microsoft: not run');
    Exit;
  end;
  { 0 installed, 3010 installed (a restart is advised, not needed here), 1638 a newer one is there. }
  if not ShellExec('runas', Exe, '/install /quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('VC++ runtime installer did not start: ' + SysErrorMessage(ResultCode));
    Exit;
  end;
  Log(Format('VC++ runtime installer exit code %d', [ResultCode]));
  Result := (ResultCode = 0) or (ResultCode = 3010) or (ResultCode = 1638);
  if Result then
    Result := VCRuntimePresent;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  { Never in the app's own silent update: a permission prompt out of nowhere, and a failure there
    would leave the app closed. Seaglass runs without it; only the karaoke needs it. }
  if HasParam('/SEAGLASSUPDATE=1') or VCRuntimePresent then
    Exit;
  Log('The Microsoft Visual C++ runtime is missing: installing it');
  if not WizardSilent then
  begin
    VCRuntimePage := CreateOutputMarqueeProgressPage(CustomMessage('VCRuntimeTitle'), CustomMessage('VCRuntimeDownloading'));
    VCRuntimePage.Show;
  end;
  try
    if not InstallVCRuntime then
      { Said, not fatal: the install goes on. }
      SuppressibleMsgBox(CustomMessage('VCRuntimeFailed'), mbInformation, MB_OK, IDOK);
  finally
    if VCRuntimePage <> nil then
      VCRuntimePage.Hide;
  end;
end;

{
  The app's updater starts this installer from inside the app, and the app's launcher keeps its
  processes in a Windows job that kills everything in it when the app exits. The installer closes
  the app (/CLOSEAPPLICATIONS), so it was killed halfway through copying, leaving the app without
  its files ("Error opening ... Seaglass.cfg"). So an update starts itself again through WMI, which
  makes a process outside any job, and this copy stops. If that fails, it installs as before.
}
{ False while a running Seaglass (its launcher or the app it starts) keeps Seaglass.exe open. }
function AppClosed(const Exe: String): Boolean;
var
  Stream: TFileStream;
begin
  Result := True;
  if not FileExists(Exe) then
    Exit;
  try
    Stream := TFileStream.Create(Exe, fmOpenReadWrite or fmShareExclusive);
    Stream.Free;
  except
    Result := False;
  end;
end;

{
  The updater starts the update and then the app quits, which takes it some seconds. Windows can't
  close Seaglass for the installer (Restart Manager asks for a reboot instead), and the files it
  still holds can't be replaced: the install stopped after deleting the others. So an update waits
  for the app to have quit, up to two minutes, before touching anything.
}
procedure WaitForAppToQuit;
var
  Dir: String;
  Waited: Integer;
begin
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8C4E2A71-5B3D-4F0A-9E62-1D7C3B9A4E58}_is1', 'InstallLocation', Dir) then
    Dir := ExpandConstant('{localappdata}\Programs\Seaglass');
  Waited := 0;
  while (not AppClosed(AddBackslash(Dir) + 'Seaglass.exe')) and (Waited < 120000) do
  begin
    Sleep(500);
    Waited := Waited + 500;
  end;
  Log(Format('Waited %d ms for Seaglass to quit', [Waited]));
end;

function InitializeSetup: Boolean;
var
  Exe, Arguments, Command: String;
  ResultCode: Integer;
begin
  Result := True;
  if not HasParam('/SEAGLASSUPDATE=1') then
    Exit;
  if HasParam('/SEAGLASSDETACHED') then
  begin
    WaitForAppToQuit;
    Exit;
  end;
  Exe := ExpandConstant('{srcexe}');
  { A single quote in the path, doubled for PowerShell's single-quoted string. }
  StringChangeEx(Exe, '''', '''''', True);
  Arguments := ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /SEAGLASSUPDATE=1 /SEAGLASSDETACHED';
  if HasParam('/NOLAUNCH') then
    Arguments := Arguments + ' /NOLAUNCH';
  Command := '-NoProfile -NonInteractive -WindowStyle Hidden -Command "' +
    '$line = [char]34 + ''' + Exe + ''' + [char]34 + ''' + Arguments + '''; ' +
    '$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $line }; ' +
    'exit [int]$result.ReturnValue"';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Command, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
    Result := False;
end;
