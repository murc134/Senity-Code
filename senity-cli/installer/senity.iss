; ============================================================================
;  senity.iss - Inno Setup Script fuer die senity-CLI (Windows)
;
;  Erzeugt senity-setup.exe. Die setup.exe:
;    1. installiert die senity-CLI-Dateien nach {autopf}\Senity
;    2. erzeugt den senity.bat-Shim
;    3. traegt {app} in den System-PATH ein (ChangesEnvironment)
;    4. startet am Ende den Reboot-faehigen Prereq-Bootstrapper
;       (senity-prereqs.ps1), der WSL2 + Docker Desktop mit Neustarts einrichtet
;
;  Deinstallation entfernt Dateien, PATH-Eintrag und RunOnce-Resume.
;  Die Benutzerdaten unter %USERPROFILE%\.senity bleiben erhalten.
;
;  Build:  ISCC.exe senity.iss   (oder build.ps1)
; ============================================================================

#define AppName        "Senity CLI"
#define AppPublisher   "Senity"
#define AppVersion     "1.0.0"
#define AppExeId       "senity"
#define AppUrl         "https://git.senity.ai/senity-admin/senity-claude-code"

[Setup]
AppId={{8F3A6C21-7E44-4B9D-9C2E-A1B2C3D4E5F6}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
DefaultDirName={autopf}\Senity
DefaultGroupName=Senity
DisableProgramGroupPage=yes
DisableDirPage=auto
; Admin noetig: PATH (System), dism, winget Docker/WSL.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=senity-setup
OutputDir=dist
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\senity.bat
SetupLogging=yes

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Files]
; CLI-Wrapper (liegt eine Ebene ueber dem installer-Ordner).
Source: "..\senity.ps1";        DestDir: "{app}"; Flags: ignoreversion
; cmd/pwsh-Shim, damit `senity` ueberall funktioniert.
Source: "senity.bat";           DestDir: "{app}"; Flags: ignoreversion
; Reboot-faehiger Prereq-Bootstrapper.
Source: "senity-prereqs.ps1";   DestDir: "{app}"; Flags: ignoreversion

[Tasks]
Name: "prereqs"; Description: "WSL2 und Docker Desktop jetzt einrichten (empfohlen, kann Neustarts ausloesen)"; GroupDescription: "Voraussetzungen:"

[Run]
; Prereq-Bootstrapper starten (nur wenn Task gewaehlt). Laeuft bereits elevated.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\senity-prereqs.ps1"""; \
  Tasks: prereqs; Flags: postinstall; \
  Description: "WSL2 + Docker Desktop einrichten"; \
  StatusMsg: "Starte Voraussetzungs-Setup..."

[UninstallRun]
; RunOnce-Resume + Setup-State entfernen, falls Deinstallation mitten im
; Prereq-Ablauf erfolgt.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\senity-prereqs.ps1"" -Reset"; \
  Flags: runhidden; RunOnceId: "SenityPrereqReset"

[Code]
const
  EnvKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

function NeedsAddPath(const Dir: string): Boolean;
var
  Paths: string;
begin
  if not RegQueryStringValue(HKLM, EnvKey, 'Path', Paths) then
  begin
    Result := True;
    exit;
  end;
  // case-insensitiver Vergleich, von ';' umschlossen.
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Paths) + ';') = 0;
end;

procedure AddToPath(const Dir: string);
var
  Paths: string;
begin
  if not NeedsAddPath(Dir) then exit;
  if not RegQueryStringValue(HKLM, EnvKey, 'Path', Paths) then Paths := '';
  if (Paths <> '') and (Paths[Length(Paths)] <> ';') then Paths := Paths + ';';
  Paths := Paths + Dir;
  RegWriteExpandStringValue(HKLM, EnvKey, 'Path', Paths);
end;

procedure RemoveFromPath(const Dir: string);
var
  Paths: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKLM, EnvKey, 'Path', Paths) then exit;
  // Entferne ';Dir' bzw. 'Dir;' bzw. 'Dir' in jeder Position.
  P := Pos(';' + Uppercase(Dir), Uppercase(Paths));
  if P > 0 then
    Delete(Paths, P, Length(Dir) + 1)
  else
  begin
    P := Pos(Uppercase(Dir) + ';', Uppercase(Paths));
    if P > 0 then
      Delete(Paths, P, Length(Dir) + 1)
    else
    begin
      P := Pos(Uppercase(Dir), Uppercase(Paths));
      if P > 0 then Delete(Paths, P, Length(Dir));
    end;
  end;
  RegWriteExpandStringValue(HKLM, EnvKey, 'Path', Paths);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddToPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
