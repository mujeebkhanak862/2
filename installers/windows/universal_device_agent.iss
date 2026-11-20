; Inno Setup script — Universal Device Agent (Windows installer)
; Build:  flutter build windows --release
;         iscc installers\windows\universal_device_agent.iss
; Output: installers\windows\Output\UniversalDeviceAgent-Setup-<version>.exe
;
; Per-user install (admin ki zaroorat nahi) — agent HKCU Run key / tray
; use karta hai, isliye per-user hi sahi hai.

#define AppName "Universal Device Agent"
#ifndef AppVersion
#define AppVersion "0.1.0"
#endif
#define AppPublisher "Device Agent"
#define AppExeName "device_agent.exe"
#define BuildDir "..\..\shared_app\build\windows\x64\runner\Release"

[Setup]
AppId={{6E0B8F5A-3D4C-4A53-9B77-2D5C1A9E7F10}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=UniversalDeviceAgent-Setup-{#AppVersion}
OutputDir=Output
SetupIconFile=..\..\shared_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Desktop shortcut banao"; Flags: unchecked
Name: "autostart"; Description: "Windows login par agent apne aap chalu ho (tray mein)"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; App ke "Start at login" toggle jaisi hi value (autostart.dart ke saath consistent).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "UniversalDeviceAgent"; ValueData: """{app}\{#AppExeName}"" --background"; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Universal Device Agent kholo"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Tray mein chalta agent uninstall se pehle band karo.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExeName}"; Flags: runhidden; RunOnceId: "KillAgent"

; ---- Visual C++ runtime (Stage 9) ----------------------------------------
; Flutter Windows exe ko VC++ 2015-2022 x64 runtime chahiye; saaf machine par
; nahi hota. Release workflow `vc_redist.x64.exe` is folder mein download karta
; hai; file ho to installer use (agar pehle se installed na ho) chala deta hai.
#if FileExists(SourcePath + "vc_redist.x64.exe")
[Files]
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Visual C++ runtime install ho raha hai..."; Check: NeedsVCRedist; Flags: waituntilterminated
#endif

[Code]
function NeedsVCRedist: Boolean;
var
  Installed: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKLM64,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed)
    and (Installed = 1));
end;
