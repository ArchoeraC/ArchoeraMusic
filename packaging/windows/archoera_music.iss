; ArchoeraMusic Windows Installer (Inno Setup 6.3+)
; per-user 安装：装到 %LOCALAPPDATA%\Programs，全程无需管理员/UAC（符合
; AGENTS.md「普通用户可完成、不请求提权」红线）。
; 用法（CI）：
;   ISCC.exe /DVersion=0.9.16+4 /DAppDir=<release目录> \
;     /DOutputDir=<输出目录> packaging\windows\archoera_music.iss

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef AppDir
  #define AppDir ""
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#define AppName "ArchoeraMusic"
#define AppExeName "archoera_music.exe"

[Setup]
; ── 应用标识（AppId 一旦发布不可更改：决定升级/卸载身份）──
AppId={{2EE05715-CB4C-4636-99BE-2C450858181B}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher=BetaStudio2

; ── 安装模式与向导 ──
; 最低权限 → 纯用户级安装，不弹 UAC、不写 HKLM（对齐 AGENTS.md）。
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
; 现代 Windows 11 外观，并随系统浅色/深色自动切换（Inno 6.3+ dynamic 模式）。
WizardStyle=modern windows11 dynamic
; 安装位置页始终显示，用户无需先选「自定义安装」即可改路径。
DisableDirPage=no
; 开始菜单文件夹固定为 DefaultGroupName；是否创建交由「附加任务」勾选。
DisableProgramGroupPage=yes
; 允许安装过程中取消：点击取消先确认一次，随后 Setup 会自动撤销已做的更改
; （Inno 的 native rollback；见 Setup.Install.pas「Rolling back changes」）。
AllowCancelDuringInstall=yes

; ── 外观 ──
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; ── 输出与压缩 ──
OutputDir={#OutputDir}
OutputBaseFilename=ArchoeraMusic-{#Version}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; ── 用户协议与免责声明（内容与软件内「关于 → 软件声明」一致）──
LicenseFile=EULA.txt

[Languages]
; 简体中文 .isl 随仓库分发（Inno Setup 6.4+ 官方安装包不再自带翻译文件）；
; 相对路径按脚本所在目录解析（见 [Languages] MessagesFile 文档）。
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[CustomMessages]
english.CreateStartMenuIcon=Create a &Start Menu shortcut
chinesesimp.CreateStartMenuIcon=创建开始菜单快捷方式
english.DiskSpaceHeader=Disk space
chinesesimp.DiskSpaceHeader=磁盘空间
english.DiskSpaceFree=Available at destination: %1
chinesesimp.DiskSpaceFree=目标位置可用：%1

[Tasks]
Name: "menuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; 整个 Release 目录递归装入（exe / data / native / 插件 dll）
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; 开始菜单目录内与桌面均为可选项（安装向导「附加任务」页勾选）。
; 应用会在首次运行时给开始菜单快捷方式就地补上 AppUserModelID（Toast 前提），
; 路径必须与此处一致；若用户未勾选，安装器会置 StartMenuShortcut=0 让其不重建。
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: menuicon
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; 安装标记：应用据此判定「安装版」（Inno 的自动卸载键名带 _is1 后缀，不宜依赖）。
Root: HKCU; Subkey: "Software\{#AppName}"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey
; 开始菜单快捷方式偏好：0 = 用户选择不创建（应用不得为 Toast 悄悄重建）。
Root: HKCU; Subkey: "Software\{#AppName}"; ValueType: dword; ValueName: "StartMenuShortcut"; ValueData: "1"; Tasks: menuicon
Root: HKCU; Subkey: "Software\{#AppName}"; ValueType: dword; ValueName: "StartMenuShortcut"; ValueData: "0"; Tasks: not menuicon

[InstallDelete]
; 旧版在开始菜单 Programs 根下留的散装快捷方式（与新的目录内快捷方式重复），清理掉。
Type: files; Name: "{autoprograms}\{#AppName}.lnk"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DiskFreeLabel: TNewStaticText;

function FormatSizeMB(const MB: Cardinal): String;
begin
  if MB >= 1024 then
    Result := Format('%.2f GB', [MB / 1024.0])
  else
    Result := Format('%d MB', [MB]);
end;

{ 目标目录可能尚不存在，退回所在盘符查询；仍失败则返回 False。 }
function TryGetFreeMB(const Dir: String; var FreeMB: Cardinal): Boolean;
var
  TotalMB: Cardinal;
  Drive: String;
begin
  FreeMB := 0;
  if Dir <> '' then
    if GetSpaceOnDisk(Dir, True, FreeMB, TotalMB) then
    begin
      Result := True;
      Exit;
    end;
  Drive := ExtractFileDrive(Dir);
  if Drive <> '' then
    Result := GetSpaceOnDisk(AddBackslash(Drive), True, FreeMB, TotalMB)
  else
    Result := False;
end;

function FreeSpaceText(const Dir: String): String;
var
  FreeMB: Cardinal;
begin
  if TryGetFreeMB(Dir, FreeMB) then
    Result := FormatSizeMB(FreeMB)
  else
    Result := '';
end;

procedure RefreshDiskFree;
var
  Free: String;
begin
  if DiskFreeLabel = nil then Exit;
  Free := FreeSpaceText(WizardForm.DirEdit.Text);
  if Free <> '' then
    DiskFreeLabel.Caption := ExpandConstant('{cm:DiskSpaceFree,' + Free + '}')
  else
    DiskFreeLabel.Caption := '';
end;

procedure DirEditChanged(Sender: TObject);
begin
  RefreshDiskFree;
end;

{ 安装位置页：在路径输入框下方实时显示目标磁盘可用空间
  （所需空间由 Inno 自带的 DiskSpaceLabel 显示）。 }
procedure InitializeWizard;
begin
  DiskFreeLabel := TNewStaticText.Create(WizardForm);
  DiskFreeLabel.Parent := WizardForm.SelectDirPage;
  DiskFreeLabel.Left := WizardForm.DirEdit.Left;
  DiskFreeLabel.Top := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(8);
  DiskFreeLabel.AutoSize := True;
  DiskFreeLabel.Caption := '';
  WizardForm.DirEdit.OnChange := @DirEditChanged;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectDir then
    RefreshDiskFree;
end;

function MemoBlock(const S, NewLine: String): String;
begin
  if S <> '' then
    Result := S + NewLine + NewLine
  else
    Result := '';
end;

{ 安装前总览：沿用 Inno 默认各节，并追加「磁盘空间」一栏
  （所需空间来自 Inno 的 DiskSpaceLabel，加上目标位置可用空间）。 }
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Free: String;
begin
  Result := MemoBlock(MemoUserInfoInfo, NewLine) + MemoBlock(MemoDirInfo, NewLine) +
    MemoBlock(MemoTypeInfo, NewLine) + MemoBlock(MemoComponentsInfo, NewLine) +
    MemoBlock(MemoGroupInfo, NewLine) + MemoBlock(MemoTasksInfo, NewLine);

  Result := Result + ExpandConstant('{cm:DiskSpaceHeader}') + NewLine;
  if WizardForm.DiskSpaceLabel.Caption <> '' then
    Result := Result + Space + WizardForm.DiskSpaceLabel.Caption + NewLine;
  Free := FreeSpaceText(WizardForm.DirEdit.Text);
  if Free <> '' then
    Result := Result + Space + ExpandConstant('{cm:DiskSpaceFree,' + Free + '}') + NewLine;
end;

{ 退出/取消前统一确认一次（Inno 默认行为，显式声明意图）。 }
procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  Confirm := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\{#AppName}');
    if DirExists(DataDir) then
      if MsgBox('是否删除用户数据（设置、缓存、下载索引）？' + #13#10 + #13#10 + DataDir,
                mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
