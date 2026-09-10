; KırtasiyePOS Windows kurulum paketi (Inno Setup 6/7 uyumlu).
; Derleme: ISCC.exe windows/installer.iss   (calisma dizini: windows/)
; Girdi: ..\build\windows\x64\runner\Release\  (flutter build windows --release)
; Çıktı: ..\dist\KirtasiyePOS-Kurulum-<surum>.exe
#define MyAppName "KırtasiyePOS"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "KırtasiyePOS"
#define MyAppExeName "kirtasiye_app.exe"

[Setup]
AppId={{3B7A9C2D-5E4F-4A8B-9C1D-2E3F4A5B6C7D}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\KirtasiyePOS
DefaultGroupName=KırtasiyePOS
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=KirtasiyePOS-Kurulum-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayName=KırtasiyePOS {#MyAppVersion}
VersionInfoVersion=1.0.0.1
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "Masaüstü simgesi oluştur"; GroupDescription: "Ek kısayollar:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\KırtasiyePOS"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\KırtasiyePOS"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "KırtasiyePOS'u çalıştır"; Flags: nowait postinstall skipifsilent
