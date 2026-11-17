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


italian.DependencyDownloading=Seaglass ha bisogno di %1. Lo scarico e lo installo (Windows può chiedere il permesso).
italian.DependencyFailed=%1 non è stato installato. Seaglass funziona, ma alcune funzioni (il karaoke, l'accesso a Spotify) potrebbero non partire finché non lo installi da %2.
english.DependencyDownloading=Seaglass needs %1. Downloading and installing it (Windows may ask for permission).
english.DependencyFailed=%1 wasn't installed. Seaglass works, but some features (karaoke, Spotify sign-in) may not start until you install it from %2.
french.DependencyDownloading=Seaglass a besoin de %1. Téléchargement et installation en cours (Windows peut demander l'autorisation).
french.DependencyFailed=%1 n'a pas été installé. Seaglass fonctionne, mais certaines fonctions (le karaoké, la connexion à Spotify) risquent de ne pas démarrer tant que vous ne l'installez pas depuis %2.
spanish.DependencyDownloading=Seaglass necesita %1. Se descarga y se instala (Windows puede pedir permiso).
spanish.DependencyFailed=No se instaló %1. Seaglass funciona, pero algunas funciones (el karaoke, el acceso a Spotify) pueden no iniciarse hasta que lo instales desde %2.
german.DependencyDownloading=Seaglass benötigt %1. Es wird heruntergeladen und installiert (Windows fragt eventuell nach einer Berechtigung).
german.DependencyFailed=%1 wurde nicht installiert. Seaglass funktioniert, aber einige Funktionen (Karaoke, die Spotify-Anmeldung) starten möglicherweise erst, wenn Sie es von %2 installieren.
portuguese.DependencyDownloading=O Seaglass precisa de %1. A transferir e a instalar (o Windows pode pedir permissão).
portuguese.DependencyFailed=%1 não foi instalado. O Seaglass funciona, mas algumas funções (o karaoke, o início de sessão no Spotify) podem não arrancar até o instalar a partir de %2.
japanese.DependencyDownloading=Seaglass には %1 が必要です。ダウンロードしてインストールします(Windows が許可を求める場合があります)。
japanese.DependencyFailed=%1 はインストールされませんでした。Seaglass は動作しますが、%2 からインストールするまで一部の機能(カラオケ、Spotify へのサインイン)が始まらない場合があります。
russian.DependencyDownloading=Для Seaglass нужен компонент %1. Он будет загружен и установлен (Windows может запросить разрешение).
russian.DependencyFailed=%1 не установлен. Seaglass работает, но некоторые функции (караоке, вход в Spotify) могут не запускаться, пока вы не установите его с %2.
turkish.DependencyDownloading=Seaglass için %1 gerekir. İndirilip kuruluyor (Windows izin isteyebilir).
turkish.DependencyFailed=%1 kurulmadı. Seaglass çalışır, ancak %2 adresinden kurana kadar bazı özellikler (karaoke, Spotify girişi) başlamayabilir.

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
  What Seaglass needs from Windows, fetched by setup when the computer lacks it, on a new install and
  on an update alike (the app's own silent one too):
    1. the Microsoft Visual C++ 2015-2022 runtime (x64), for ONNX Runtime's library (the karaoke);
    2. Microsoft Edge, which signs in to Spotify (every Windows 11 has it, a Windows 10 may not).
  Java, FFmpeg (with its own copy of the runtime's DLLs) and ONNX Runtime are in the app image.
  Each is Microsoft's own installer, downloaded over HTTPS, checked for Microsoft's signature, and run
  with Windows's permission prompt (they need administrator rights, which Seaglass itself doesn't).
  The wait for one is bounded and a failure only says so: setup goes on, so an update never leaves
  the app closed.
}
const
  DepVCRuntime = 1;
  DepEdge = 2;
  DepCount = 2;

var
  DependencyPage: TOutputMarqueeProgressWizardPage;

function DependencyName(Kind: Integer): String;
begin
  if Kind = DepVCRuntime then
    Result := 'Microsoft Visual C++ Runtime'
  else
    Result := 'Microsoft Edge';
end;

{ Where the user can get it by hand. }
function DependencyManualUrl(Kind: Integer): String;
begin
  if Kind = DepVCRuntime then
    Result := 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
  else
    Result := 'https://www.microsoft.com/edge';
end;

function DependencyDownloadUrl(Kind: Integer): String;
begin
  if Kind = DepVCRuntime then
    Result := 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
  else
    Result := 'https://go.microsoft.com/fwlink/?linkid=2109047';
end;

function DependencyFile(Kind: Integer): String;
begin
  if Kind = DepVCRuntime then
    Result := 'vc_redist.x64.exe'
  else
    Result := 'MicrosoftEdgeSetup.exe';
end;

function DependencyArguments(Kind: Integer): String;
begin
  if Kind = DepVCRuntime then
    Result := '/install /quiet /norestart'
  else
    Result := '/silent /install';
end;

function DependencyPresent(Kind: Integer): Boolean;
begin
  if Kind = DepVCRuntime then
    Result := FileExists(ExpandConstant('{sys}\vcruntime140_1.dll')) and FileExists(ExpandConstant('{sys}\msvcp140.dll'))
  else
    Result := FileExists(ExpandConstant('{commonpf32}\Microsoft\Edge\Application\msedge.exe')) or
      FileExists(ExpandConstant('{commonpf64}\Microsoft\Edge\Application\msedge.exe')) or
      FileExists(ExpandConstant('{localappdata}\Microsoft\Edge\Application\msedge.exe'));
end;

function OnDependencyProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  if DependencyPage <> nil then
    DependencyPage.Animate;
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

{ Downloads, checks and runs one dependency's installer, and waits (up to ten minutes) for it to be there. }
function InstallDependency(Kind: Integer): Boolean;
var
  Exe: String;
  ResultCode, Waited: Integer;
begin
  Result := False;
  Exe := ExpandConstant('{tmp}\') + DependencyFile(Kind);
  try
    DownloadTemporaryFile(DependencyDownloadUrl(Kind), DependencyFile(Kind), '', @OnDependencyProgress);
  except
    Log(DependencyName(Kind) + ' download failed: ' + GetExceptionMessage);
    Exit;
  end;
  if not SignedByMicrosoft(Exe) then
  begin
    Log('The downloaded ' + DependencyName(Kind) + ' installer is not signed by Microsoft: not run');
    Exit;
  end;
  { The permission prompt and the installer take their time (Edge downloads itself): no wait for its end, a wait for its result. }
  if not ShellExec('runas', Exe, DependencyArguments(Kind), '', SW_SHOW, ewNoWait, ResultCode) then
  begin
    Log(DependencyName(Kind) + ' installer did not start: ' + SysErrorMessage(ResultCode));
    Exit;
  end;
  Waited := 0;
  while (not DependencyPresent(Kind)) and (Waited < 600) do
  begin
    Sleep(1000);
    Waited := Waited + 1;
    if DependencyPage <> nil then
      DependencyPage.Animate;
  end;
  { Its last files are still being written when the first one is there. }
  if DependencyPresent(Kind) then
    Sleep(3000);
  if DependencyPresent(Kind) then
    Log(Format('%s: installed, %d s', [DependencyName(Kind), Waited]))
  else
    Log(Format('%s: still missing after %d s', [DependencyName(Kind), Waited]));
  Result := DependencyPresent(Kind);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Kind: Integer;
begin
  Result := '';
  for Kind := 1 to DepCount do
  begin
    if not DependencyPresent(Kind) then
    begin
      Log(DependencyName(Kind) + ' is missing: installing it');
      if not WizardSilent then
      begin
        DependencyPage := CreateOutputMarqueeProgressPage(DependencyName(Kind), FmtMessage(CustomMessage('DependencyDownloading'), [DependencyName(Kind)]));
        DependencyPage.Show;
      end;
      try
        if not InstallDependency(Kind) then
          { Said, not fatal: the install goes on. }
          SuppressibleMsgBox(FmtMessage(CustomMessage('DependencyFailed'), [DependencyName(Kind), DependencyManualUrl(Kind)]), mbInformation, MB_OK, IDOK);
      finally
        if DependencyPage <> nil then
        begin
          DependencyPage.Hide;
          DependencyPage := nil;
        end;
      end;
    end;
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
