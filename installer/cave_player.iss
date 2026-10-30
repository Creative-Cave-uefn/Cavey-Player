; Установщик Cave Player (Inno Setup 6). Собирается в GitHub Actions после flutter build windows.
#ifndef MyVersion
  #define MyVersion "0.0.0"
#endif

[Setup]
AppId={{806F3744-0035-43B4-B655-A423BF019A3B}
AppName=Cave Player
AppVersion={#MyVersion}
VersionInfoVersion={#MyVersion}
AppPublisher=Creative Cave
DefaultDirName={localappdata}\Programs\Cave Player
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=CavePlayer-Setup
SetupIconFile=..\assets\app_icon.ico
UninstallDisplayIcon={app}\cave_player.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Cave Player"; Filename: "{app}\cave_player.exe"
Name: "{autodesktop}\Cave Player"; Filename: "{app}\cave_player.exe"; Tasks: desktopicon

[Registry]
; Ссылки caveplayer://track/<id> открывают Cave Player на нужном треке (для текущего пользователя, права администратора не нужны)
Root: HKCU; Subkey: "Software\Classes\caveplayer"; ValueType: string; ValueName: ""; ValueData: "URL:Cave Player"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\caveplayer"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\caveplayer\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\cave_player.exe,0"
Root: HKCU; Subkey: "Software\Classes\caveplayer\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\cave_player.exe"" ""%1"""

[Run]
Filename: "{app}\cave_player.exe"; Description: "{cm:LaunchProgram,Cave Player}"; Flags: nowait postinstall skipifsilent
; При тихой установке (автообновление) снова открываем приложение
Filename: "{app}\cave_player.exe"; Flags: nowait; Check: WizardSilent
