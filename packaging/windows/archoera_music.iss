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
; 显示品牌欢迎页（左侧品牌横幅）
DisableWelcomePage=no
; 安装位置页始终显示，用户无需先选「自定义安装」即可改路径。
DisableDirPage=no
; 开始菜单文件夹固定为 DefaultGroupName；是否创建交由「附加任务」勾选。
DisableProgramGroupPage=yes
; 允许安装过程中取消：点击取消先确认一次，随后 Setup 会自动撤销已做的更改
; （Inno 的 native rollback；见 Setup.Install.pas「Rolling back changes」）。
AllowCancelDuringInstall=yes

; ── 品牌外观 ──
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
; 品牌横幅（欢迎页 / 完成页；浅 / 深两套，2x 供高 DPI）
WizardImageFile=brand\wizard-large-light.png,brand\wizard-large-light@2x.png
WizardImageFileDynamicDark=brand\wizard-large-dark.png,brand\wizard-large-dark@2x.png
WizardImageBackColor=#F7F2FA
WizardImageBackColorDynamicDark=#141218
; 右上角小图 = 应用图标（多尺寸适配 DPI）
WizardSmallImageFile=brand\wizard-small-64.png,brand\wizard-small-128.png,brand\wizard-small-256.png
WizardSmallImageFileDynamicDark=brand\wizard-small-64.png,brand\wizard-small-128.png,brand\wizard-small-256.png
; 运行时换帧（WizardSetBackImage）需先激活自定义背景；透明底图本身不可见。
WizardBackImageFile=brand\back-transparent.png
WizardBackImageFileDynamicDark=brand\back-transparent.png

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
; Inno Setup 6.4+ 官方安装包不再自带翻译文件，各语言 .isl 随仓库分发；
; 相对路径按脚本所在目录解析（见 [Languages] MessagesFile 文档）。
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"
Name: "chinesetrad"; MessagesFile: "ChineseTraditional.isl"
Name: "german"; MessagesFile: "German.isl"
Name: "spanish"; MessagesFile: "Spanish.isl"
Name: "french"; MessagesFile: "French.isl"
Name: "japanese"; MessagesFile: "Japanese.isl"
Name: "korean"; MessagesFile: "Korean.isl"

[Messages]
english.WelcomeLabel1=Welcome to [name] Setup
english.WelcomeLabel2=This will install [name/ver] on your computer.%n%nIt is recommended that you close all other applications before continuing.
chinesesimp.WelcomeLabel1=欢迎安装 [name]
chinesesimp.WelcomeLabel2=即将在你的电脑上安装 [name/ver]。%n%n建议先关闭其他正在运行的程序，然后继续。
chinesetrad.WelcomeLabel1=歡迎安裝 [name]
chinesetrad.WelcomeLabel2=即將在您的電腦上安裝 [name/ver]。%n%n建議先關閉其他正在執行的程式，然後繼續。
german.WelcomeLabel1=Willkommen beim Setup von [name]
german.WelcomeLabel2=Auf Ihrem Computer wird jetzt [name/ver] installiert.%n%nBitte schließen Sie alle anderen Anwendungen, bevor Sie fortfahren.
spanish.WelcomeLabel1=Bienvenido a la instalación de [name]
spanish.WelcomeLabel2=Se instalará [name/ver] en su equipo.%n%nSe recomienda cerrar el resto de aplicaciones antes de continuar.
french.WelcomeLabel1=Bienvenue dans l'installation de [name]
french.WelcomeLabel2=Cette installation va installer [name/ver] sur votre ordinateur.%n%nIl est recommandé de fermer les autres applications avant de continuer.
japanese.WelcomeLabel1=[name] セットアップへようこそ
japanese.WelcomeLabel2=[name/ver] をコンピューターにインストールします。%n%n続行する前に、他のアプリケーションをすべて終了することをお勧めします。
korean.WelcomeLabel1=[name] 설치에 오신 것을 환영합니다
korean.WelcomeLabel2=컴퓨터에 [name/ver]을(를) 설치합니다.%n%n계속하기 전에 다른 모든 응용 프로그램을 닫는 것이 좋습니다.

[CustomMessages]
english.CreateStartMenuIcon=Create a &Start Menu shortcut
chinesesimp.CreateStartMenuIcon=创建开始菜单快捷方式
chinesetrad.CreateStartMenuIcon=建立開始功能表捷徑
german.CreateStartMenuIcon=Eine &Startmenü-Verknüpfung erstellen
spanish.CreateStartMenuIcon=Crear un acceso directo en el &menú Inicio
french.CreateStartMenuIcon=Créer un raccourci dans le &menu Démarrer
japanese.CreateStartMenuIcon=スタートメニューのショートカットを作成(&S)
korean.CreateStartMenuIcon=시작 메뉴 바로 가기 만들기(&S)

english.DiskSpaceHeader=Disk space
chinesesimp.DiskSpaceHeader=磁盘空间
chinesetrad.DiskSpaceHeader=磁碟空間
german.DiskSpaceHeader=Speicherplatz
spanish.DiskSpaceHeader=Espacio en disco
french.DiskSpaceHeader=Espace disque
japanese.DiskSpaceHeader=ディスク容量
korean.DiskSpaceHeader=디스크 공간

english.DiskSpaceFree=Available at destination: %1
chinesesimp.DiskSpaceFree=目标位置可用：%1
chinesetrad.DiskSpaceFree=目標位置可用：%1
german.DiskSpaceFree=Verfügbar am Zielort: %1
spanish.DiskSpaceFree=Disponible en el destino: %1
french.DiskSpaceFree=Disponible à destination : %1
japanese.DiskSpaceFree=インストール先の空き容量: %1
korean.DiskSpaceFree=설치 위치의 사용 가능 공간: %1

english.UninstallDeleteUserData=Delete user data (settings, cache, download index)?%n%n%1
chinesesimp.UninstallDeleteUserData=是否删除用户数据（设置、缓存、下载索引）？%n%n%1
chinesetrad.UninstallDeleteUserData=是否刪除使用者資料（設定、快取、下載索引）？%n%n%1
german.UninstallDeleteUserData=Benutzerdaten löschen (Einstellungen, Cache, Download-Index)?%n%n%1
spanish.UninstallDeleteUserData=¿Eliminar los datos de usuario (ajustes, caché, índice de descargas)?%n%n%1
french.UninstallDeleteUserData=Supprimer les données utilisateur (paramètres, cache, index de téléchargement) ?%n%n%1
japanese.UninstallDeleteUserData=ユーザーデータ（設定・キャッシュ・ダウンロード索引）を削除しますか？%n%n%1
korean.UninstallDeleteUserData=사용자 데이터(설정, 캐시, 다운로드 인덱스)를 삭제할까요?%n%n%1

[Tasks]
Name: "menuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; 整个 Release 目录递归装入（exe / data / native / 插件 dll）
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; 安装页动态背景帧（aurora，浅/深两套；仅运行时 ExtractTemporaryFile 使用，不落盘）
Source: "brand\anim\*.png"; Flags: dontcopy noencryption

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

[UninstallDelete]
; 快捷方式兜底：应用会就地重写开始菜单 .lnk（补 AUMID），可能不在 Inno 的
; [Icons] 记录里，故卸载时按固定路径再清一遍（桌面 + 开始菜单目录内）。
; （散装 `{autoprograms}\ArchoeraMusic.lnk` 已在安装时由 [InstallDelete] 清理，
;   新版安装器不再产生，无需在卸载阶段处理。）
Type: files; Name: "{autoprograms}\{#AppName}\{#AppName}.lnk"
Type: files; Name: "{autodesktop}\{#AppName}.lnk"
Type: dirifempty; Name: "{autoprograms}\{#AppName}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// ⚠️ 编码红线：Inno 把编译后的 [Code] 以 AnsiString 交给卸载程序的 Pascal Script
// 引擎（Setup.Uninstall.pas 的 ExtractCompiledCodeText），**非 ASCII 字符串字面量
// 在卸载程序里会乱码**（已实测）。因此 [Code] 内：
//   - 字符串字面量只写 ASCII；
//   - 一切本地化文案走 [Messages] / [CustomMessages] + CustomMessage()/ExpandConstant('{cm:…}')。
// 注意：[Code] 内只能用 Pascal 注释（// 或 { }），不能用 `;`。
const
  AnimFrameCount = 90;
  AnimIntervalMs = 33;

var
  DiskFreeLabel: TNewStaticText;
  AnimFrames: TArrayOfGraphic;
  AnimFrameIndex: Integer;
  AnimImage: TBitmapImage;
  AnimTimerID: Longword;
  AnimCallback: Longword;

{ SetTimer/KillTimer：Inno 的 [Code] 无内置定时器，用 user32 定时器 + CreateCallback
  实现「时间驱动」的平滑动画（对齐 Inno 6.7 官方 Examples/CodeDll.iss，用 Longword）。 }
function SetTimer(hWnd, nIDEvent, uElapse, lpTimerFunc: Longword): Longword;
external 'SetTimer@user32.dll stdcall';
function KillTimer(hWnd, nIDEvent: Longword): Bool;
external 'KillTimer@user32.dll stdcall';

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

  // 安装页动态背景控件（垫底、铺满 Installing 页；帧在 ssInstall 时载入）
  AnimImage := TBitmapImage.Create(WizardForm);
  AnimImage.Parent := WizardForm.InstallingPage;
  AnimImage.Stretch := True;
  AnimImage.Visible := False;
  AnimImage.SendToBack;
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

{ ── 安装页动态背景（控件叠加 + 时间驱动换帧，似 QQ 安装器）──────────────
  在 Installing 页放一个铺满的 TBitmapImage（SendToBack 垫底），定时器每
  AnimIntervalMs 毫秒 Assign 下一帧（90 帧全幅 aurora，约 3s 循环）。
  相比 WizardSetBackImage（内部 RDW_ERASE|RDW_ALLCHILDREN 会整窗擦除并重绘
  所有子控件 → 切帧闪烁），控件叠加只重绘该控件本身，闪烁明显更少。 }
procedure AnimTimerProc(Arg1, Arg2, Arg3, Arg4: Longword);
begin
  try
    if Length(AnimFrames) = 0 then Exit;
    AnimFrameIndex := (AnimFrameIndex + 1) mod Length(AnimFrames);
    AnimImage.PngImage.Assign(AnimFrames[AnimFrameIndex]);
    AnimImage.Invalidate;
  except
    { 回调内异常不得冒泡打断安装 }
  end;
end;

procedure AnimLoadFrames(const Prefix: String);
var
  I: Integer;
  Name: String;
begin
  SetLength(AnimFrames, AnimFrameCount);
  for I := 0 to AnimFrameCount - 1 do
  begin
    Name := Prefix + Format('%.2d.png', [I]);
    ExtractTemporaryFile(Name);
    AnimFrames[I] := TPngImage.Create;
    AnimFrames[I].LoadFromFile(ExpandConstant('{tmp}\') + Name);
  end;
end;

procedure AnimStart;
begin
  if WizardSilent then Exit;  // 静默安装无向导，跳过
  // 浅/深两套 aurora 帧，按当前安装模式选择（动态深色在启动时已确定）。
  if IsDarkInstallMode then
    AnimLoadFrames('dark_')
  else
    AnimLoadFrames('light_');
  AnimFrameIndex := 0;
  AnimImage.Left := 0;
  AnimImage.Top := 0;
  AnimImage.Width := WizardForm.InstallingPage.Width;
  AnimImage.Height := WizardForm.InstallingPage.Height;
  AnimImage.PngImage.Assign(AnimFrames[0]);
  AnimImage.Invalidate;
  AnimImage.SendToBack;
  AnimImage.Visible := True;
  AnimCallback := CreateCallback(@AnimTimerProc);
  AnimTimerID := SetTimer(0, 0, AnimIntervalMs, AnimCallback);
end;

procedure AnimStop;
var
  I: Integer;
begin
  if AnimTimerID <> 0 then
  begin
    KillTimer(0, AnimTimerID);
    AnimTimerID := 0;
  end;
  if AnimImage <> nil then
    AnimImage.Visible := False;
  for I := 0 to Length(AnimFrames) - 1 do
    if AnimFrames[I] <> nil then
      AnimFrames[I].Free;
  SetLength(AnimFrames, 0);
  AnimFrameIndex := -1;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    AnimStart
  else if CurStep = ssPostInstall then
    AnimStop;
end;

procedure DeinitializeSetup;
begin
  AnimStop;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
  Prompt: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { 用户数据目录：%LOCALAPPDATA%\ArchoeraMusic（与 app 的 data_dir 一致）}
    DataDir := ExpandConstant('{localappdata}\{#AppName}');
    if DirExists(DataDir) then
    begin
      Prompt := FmtMessage(CustomMessage('UninstallDeleteUserData'), [DataDir]);
      if MsgBox(Prompt, mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
  end;
end;
