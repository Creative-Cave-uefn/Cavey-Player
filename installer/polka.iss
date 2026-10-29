; Установщик Полки (Inno Setup 6). Собирается в GitHub Actions после flutter build windows.
[Setup]
AppId={{8C1B6E2A-4F3D-4C7B-9E1A-5D2F7A3B9C10}
AppName=Полка
AppVersion=0.1.0
AppPublisher=Полка
DefaultDirName={localappdata}\Programs\Polka
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Polka-Setup
SetupIconFile=..\assets\app_icon.ico
UninstallDisplayIcon={app}\polka.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Полка"; Filename: "{app}\polka.exe"
Name: "{autodesktop}\Полка"; Filename: "{app}\polka.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\polka.exe"; Description: "{cm:LaunchProgram,Полка}"; Flags: nowait postinstall skipifsilent
