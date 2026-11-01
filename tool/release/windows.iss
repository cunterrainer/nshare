#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
[Setup]
AppId={{DCA48BE3-4729-40AA-A13F-CBC09625010E}
AppName=nshare
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\nshare
DefaultGroupName=nshare
OutputDir={#OutputDir}
OutputBaseFilename=nshare-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ChangesEnvironment=yes
UninstallDisplayIcon={app}\gui\nshare_app.exe
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\nshare"; Filename: "{app}\gui\nshare_app.exe"
Name: "{group}\nshare CLI help"; Filename: "{cmd}"; Parameters: "/k ""{app}\nshare.exe"" --help"
[Tasks]
Name: "path"; Description: "Add nshare CLI to my PATH"
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var Current, AppDir: String;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('path') then begin
    RegQueryStringValue(HKCU, 'Environment', 'Path', Current);
    AppDir := ExpandConstant('{app}');
    if Pos(';' + Lowercase(AppDir) + ';', ';' + Lowercase(Current) + ';') = 0 then begin
      if Current <> '' then Current := Current + ';';
      RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Current + AppDir);
    end;
  end;
end;
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Current, Remaining, Item: String; Separator: Integer; More, Kept: Boolean;
begin
  if CurUninstallStep = usPostUninstall then begin
    if RegQueryStringValue(HKCU, 'Environment', 'Path', Current) then begin
      Remaining := ''; Kept := False;
      repeat
        Separator := Pos(';', Current);
        More := Separator <> 0;
        if not More then Separator := Length(Current) + 1;
        Item := Copy(Current, 1, Separator - 1);
        Delete(Current, 1, Separator);
        if CompareText(Item, ExpandConstant('{app}')) <> 0 then begin
          if Kept then Remaining := Remaining + ';';
          Remaining := Remaining + Item; Kept := True;
        end;
      until not More;
      RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Remaining);
    end;
  end;
end;
