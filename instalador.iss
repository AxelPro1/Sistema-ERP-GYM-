; ============================================================
; Instalador de Thor Gym ERP (Flutter Windows)
; Guardar este archivo en la raíz del proyecto:
; C:\Users\USER\Desktop\Thor Gym ERP\gym_pos_desktop\instalador.iss
; Las rutas de [Files] y SetupIconFile son relativas a esa carpeta.
; ============================================================

#define MyAppName "Thor Gym ERP"
#define MyAppVersion "1.0.0"
#define MyAppExe "gym_pos_desktop.exe"
#define MyAppPublisher "Thor Gym"

[Setup]
; Mantén este AppId fijo: permite que las futuras versiones actualicen la instalación existente.
AppId={{B7D2F4A1-3C58-4E9B-A6D0-5F1E8C2A9D47}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=instalador
OutputBaseFilename=ThorGymERP_Setup_{#MyAppVersion}
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos:"
Name: "iniciar"; Description: "Iniciar {#MyAppName} automáticamente al encender la PC"; GroupDescription: "Inicio automático:"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon
Name: "{commonstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: iniciar

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "Abrir {#MyAppName}"; Flags: nowait postinstall skipifsilent
