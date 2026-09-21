; ArchoeraMusic Windows Installer (Inno Setup 6.3+)
; 双安装模式（默认 per-user 免提权，符合 AGENTS.md「最小权限」红线及其 Windows
; 安装向导唯一例外）：
;   - 仅为我安装：默认 %LOCALAPPDATA%\Programs，全程无需管理员/UAC；
;   - 为所有用户安装：默认 Program Files，需用户在向导内显式选择并经 UAC 提权。
; 更新（同 AppId 旧版已安装）时沿用旧版的安装模式与目录（由 Inno 读卸载注册表
; 自动识别，无需自存位置）；模式不一致则以失败退出。
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
; Toast 前提：安装器建快捷方式时写入的 AUMID，须与 app 的
; backend_windows.cpp kAumid / watermark 侧常量一致。
#define Aumid "Archoera.ArchoeraMusic"

[Setup]
; ── 应用标识（AppId 一旦发布不可更改：决定升级/卸载身份）──
AppId={{2EE05715-CB4C-4636-99BE-2C450858181B}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher=BetaStudio2

; ── 安装模式与向导 ──
; 默认最低权限（per-user，免 UAC）；允许用户在向导内显式改选「为所有用户安装」
; （由 Inno 触发 UAC 提权）。提权只发生在向导内，且必须由用户确认。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; 更新时不让 Inno 静默沿用旧模式，而是照常弹出模式选择对话框（提权前提醒 +
; 用户确认）；真正的模式一致性由 [Code] 校验，不一致以失败退出。
; 静默更新 per-machine 版本须显式传 /ALLUSERS，否则 [Code] 判定模式不符而失败。
UsePreviousPrivileges=no
; {autopf}：per-user → %LOCALAPPDATA%\Programs，per-machine → Program Files。
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
; 现代 Windows 11 外观，并随系统浅色/深色自动切换（Inno 6.3+ dynamic 模式）。
WizardStyle=modern windows11 dynamic
; 显示品牌欢迎页（左侧品牌横幅）
DisableWelcomePage=no
; 首装显示安装位置页；检测到旧版（更新）时隐藏并沿用旧目录（更新与首装分开）。
DisableDirPage=auto
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

; ── 更新模式（识别到旧版时的向导文案与模式校验提示）──
english.UpdateWelcomeLabel1=Updating [name]
chinesesimp.UpdateWelcomeLabel1=正在更新 [name]
chinesetrad.UpdateWelcomeLabel1=正在更新 [name]
german.UpdateWelcomeLabel1=ArchoeraMusic wird aktualisiert
spanish.UpdateWelcomeLabel1=Actualizando [name]
french.UpdateWelcomeLabel1=Mise à jour de [name]
japanese.UpdateWelcomeLabel1=[name] を更新しています
korean.UpdateWelcomeLabel1=[name] 업데이트 중

english.UpdateWelcomeLabel2=Setup will update [name] from version %1 to %2.%n%nIt is recommended that you close all other applications before continuing.
chinesesimp.UpdateWelcomeLabel2=即将把 [name] 从版本 %1 更新到 %2。%n%n建议先关闭其他正在运行的程序，然后继续。
chinesetrad.UpdateWelcomeLabel2=即將把 [name] 從版本 %1 更新到 %2。%n%n建議先關閉其他正在執行的程式，然後繼續。
german.UpdateWelcomeLabel2=Setup aktualisiert [name] von Version %1 auf %2.%n%nBitte schließen Sie alle anderen Anwendungen, bevor Sie fortfahren.
spanish.UpdateWelcomeLabel2=La instalación actualizará [name] de la versión %1 a la %2.%n%nSe recomienda cerrar el resto de aplicaciones antes de continuar.
french.UpdateWelcomeLabel2=L'installation va mettre à jour [name] de la version %1 vers la version %2.%n%nIl est recommandé de fermer les autres applications avant de continuer.
japanese.UpdateWelcomeLabel2=[name] をバージョン %1 から %2 に更新します。%n%n続行する前に、他のアプリケーションをすべて終了することをお勧めします。
korean.UpdateWelcomeLabel2=[name]을(를) 버전 %1에서 %2(으)로 업데이트합니다.%n%n계속하기 전에 다른 모든 응용 프로그램을 닫는 것이 좋습니다.

english.UpdateNeedsAdmin=ArchoeraMusic is currently installed for all users. Updating it requires administrative privileges: choose "Install for all users" in the wizard and approve the UAC prompt.
chinesesimp.UpdateNeedsAdmin=检测到 ArchoeraMusic 已为所有用户安装。更新需要管理员权限：请在向导中选择「为所有用户安装」，并确认 UAC 提示。
chinesetrad.UpdateNeedsAdmin=偵測到 ArchoeraMusic 已為所有使用者安裝。更新需要系統管理員權限：請在精靈中選擇「為所有使用者安裝」，並確認 UAC 提示。
german.UpdateNeedsAdmin=ArchoeraMusic ist derzeit für alle Benutzer installiert. Für das Update sind Administratorrechte erforderlich: Wählen Sie im Setup "Für alle Benutzer installieren" und bestätigen Sie die UAC-Abfrage.
spanish.UpdateNeedsAdmin=ArchoeraMusic está instalado para todos los usuarios. La actualización requiere privilegios administrativos: seleccione "Instalar para todos los usuarios" y confirme el aviso de UAC.
french.UpdateNeedsAdmin=ArchoeraMusic est installé pour tous les utilisateurs. La mise à jour nécessite des privilèges administrateur : choisissez « Installer pour tous les utilisateurs » et confirmez l'invite UAC.
japanese.UpdateNeedsAdmin=ArchoeraMusic は現在すべてのユーザー用にインストールされています。更新には管理者権限が必要です。セットアップで「すべてのユーザー用にインストール」を選び、UAC の確認を承認してください。
korean.UpdateNeedsAdmin=ArchoeraMusic이(가) 모든 사용자용으로 설치되어 있습니다. 업데이트에는 관리자 권한이 필요합니다. 설치 마법사에서 "모든 사용자용으로 설치"를 선택하고 UAC 확인을 승인하세요.

english.UpdateModeMismatch=ArchoeraMusic is currently installed for the current user only. To keep this installation, choose "Install for me only". To install for all users, uninstall the existing version first.
chinesesimp.UpdateModeMismatch=检测到 ArchoeraMusic 仅安装在当前用户下。若要保留此安装，请选择「仅为我安装」；若要为所有用户安装，请先卸载现有版本。
chinesetrad.UpdateModeMismatch=偵測到 ArchoeraMusic 僅安裝在目前使用者下。若要保留此安裝，請選擇「僅為我安裝」；若要為所有使用者安裝，請先解除安裝現有版本。
german.UpdateModeMismatch=ArchoeraMusic ist derzeit nur für den aktuellen Benutzer installiert. Um diese Installation beizubehalten, wählen Sie "Nur für mich installieren". Für eine Installation für alle Benutzer deinstallieren Sie bitte zuerst die vorhandene Version.
spanish.UpdateModeMismatch=ArchoeraMusic está instalado solo para el usuario actual. Para conservar esta instalación, seleccione "Instalar solo para mí". Para instalar para todos los usuarios, desinstale primero la versión existente.
french.UpdateModeMismatch=ArchoeraMusic est installé uniquement pour l'utilisateur actuel. Pour conserver cette installation, choisissez « Installer pour moi uniquement ». Pour installer pour tous les utilisateurs, désinstallez d'abord la version existante.
japanese.UpdateModeMismatch=ArchoeraMusic は現在、現在のユーザー用にのみインストールされています。このインストールを維持するには「自分のみにインストール」を選んでください。すべてのユーザー用にインストールするには、先に既存のバージョンをアンインストールしてください。
korean.UpdateModeMismatch=ArchoeraMusic이(가) 현재 사용자용으로만 설치되어 있습니다. 이 설치를 유지하려면 "나만 설치"를 선택하세요. 모든 사용자용으로 설치하려면 기존 버전을 먼저 제거하세요.

[Tasks]
Name: "menuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; 整个 Release 目录递归装入（exe / data / native / 插件 dll）
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; 开始菜单目录内与桌面均为可选项（安装向导「附加任务」页勾选）。
; 安装器直接写入 AppUserModelID（Toast 前提，per-user/per-machine 都适用）；
; app 侧 ensureToastShortcut 仅作兜底，路径须与此处一致（见 backend_windows.cpp）。
; 若用户未勾选，安装器置 StartMenuShortcut=0，app 不得为 Toast 悄悄重建。
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: menuicon; AppUserModelID: "{#Aumid}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon; AppUserModelID: "{#Aumid}"

[Registry]
; HKA（HKEY_AUTO）：per-user → HKCU，per-machine → HKLM（随安装模式自动选择）。
; 安装标记：应用据此判定「安装版」（Inno 的自动卸载键名带 _is1 后缀，不宜依赖）。
; uninsdeletekey：卸载时删除整个 Software\ArchoeraMusic（含下方 StartMenuShortcut）；
; [Code] CurUninstallStepChanged 另做显式兜底删除，防止残留。
Root: HKA; Subkey: "Software\{#AppName}"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey
; 开始菜单快捷方式偏好：0 = 用户选择不创建（应用不得为 Toast 悄悄重建）。
Root: HKA; Subkey: "Software\{#AppName}"; ValueType: dword; ValueName: "StartMenuShortcut"; ValueData: "1"; Tasks: menuicon
Root: HKA; Subkey: "Software\{#AppName}"; ValueType: dword; ValueName: "StartMenuShortcut"; ValueData: "0"; Tasks: not menuicon

[InstallDelete]
; 旧版在开始菜单 Programs 根下留的散装快捷方式（与新的目录内快捷方式重复），清理掉。
Type: files; Name: "{autoprograms}\{#AppName}.lnk"

[UninstallDelete]
; 快捷方式兜底：安装器已直接写 AUMID，但 app 侧 ensureToastShortcut 仍可能就地
; 重写开始菜单 .lnk，未必都在 Inno 的 [Icons] 记录里，故卸载时按固定路径再清一遍。
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
// 注意：{ } 块注释不可嵌套——注释内不得出现花括号（如 cm: 常量写法），
//       否则内层 `}` 会提前闭合注释、其后的文字被当成代码而报 Syntax error；
//       也不得让注释某行去缩进后以 `[` 开头（会被当成 section 头）。
//       需要提及这类字符时，用 `//` 行注释或改写文字（见下方 ExpandAppNamePlaceholders）。
var
  DiskFreeLabel: TNewStaticText;
  PrevInstalled: Boolean;
  PrevPerMachine: Boolean;
  PrevPerUser: Boolean;
  PrevVersion: String;

{ Inno 的卸载注册表子键名 = AppId 展开 + _is1（AppId 见 [Setup]，此处保持 ASCII）。 }
function UninstallSubkey: String;
begin
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{2EE05715-CB4C-4636-99BE-2C450858181B}_is1';
end;

{ 识别旧版本：注册表根即安装模式（HKLM=为所有用户 / HKCU=仅当前用户）。
  Inno 读卸载注册表自动识别位置，无需自存安装路径。 }
procedure DetectPrevious;
begin
  PrevPerMachine := RegKeyExists(HKEY_LOCAL_MACHINE, UninstallSubkey);
  PrevPerUser := RegKeyExists(HKEY_CURRENT_USER, UninstallSubkey);
  PrevInstalled := PrevPerMachine or PrevPerUser;
  PrevVersion := '';
  if PrevPerMachine then
    RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstallSubkey, 'DisplayVersion', PrevVersion)
  else if PrevPerUser then
    RegQueryStringValue(HKEY_CURRENT_USER, UninstallSubkey, 'DisplayVersion', PrevVersion);
end;

{ 启动即校验：更新必须沿用旧版的安装模式，不一致直接失败退出（不写入任何文件）。
  per-machine 更新须用户在向导中选「为所有用户安装」并经 UAC 提权（见 [Setup]）。 }
function InitializeSetup(): Boolean;
begin
  DetectPrevious;
  if PrevPerMachine and not IsAdminInstallMode then
  begin
    { 静默更新请显式传 /ALLUSERS；否则以失败退出，不弹阻塞对话框。 }
    if not WizardSilent then
      MsgBox(CustomMessage('UpdateNeedsAdmin'), mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if PrevPerUser and not PrevPerMachine and IsAdminInstallMode then
  begin
    if not WizardSilent then
      MsgBox(CustomMessage('UpdateModeMismatch'), mbError, MB_OK);
    Result := False;
    Exit;
  end;
  Result := True;
end;

{ 更新时跳过许可页（首装已同意，沿用旧授权）。 }
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := PrevInstalled and (PageID = wpLicense);
end;

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

{ [CustomMessages] 文案不会展开内置消息占位符 [name]/[name/ver]：Inno 只对
  内置 Setup 消息替换这些前缀（cm: 常量与 CustomMessage() 均不处理），故此处手动
  展开——这样各语言「更新」文案可沿用 Inno 惯例占位符，且与内置消息行为一致。 }
function ExpandAppNamePlaceholders(const S: String): String;
var
  R: String;
begin
  R := S;
  StringChangeEx(R, '[name/ver]', '{#AppName} {#Version}', True);
  StringChangeEx(R, '[name]', '{#AppName}', True);
  Result := R;
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

  { 更新模式：欢迎页文案改为「正在更新 旧版本 → 新版本」。
    注意：文案里的 name / name-ver 占位符（即 [name]、[name/ver]）需手动展开，
    见 ExpandAppNamePlaceholders。行首不要直接以 [ 开头，否则会被
    Inno 的段落解析器当成 section 头而报 Invalid section tag。 }
  if PrevInstalled then
  begin
    WizardForm.WelcomeLabel1.Caption :=
      ExpandAppNamePlaceholders(CustomMessage('UpdateWelcomeLabel1'));
    WizardForm.WelcomeLabel2.Caption := ExpandAppNamePlaceholders(
      FmtMessage(CustomMessage('UpdateWelcomeLabel2'), [PrevVersion, '{#Version}']));
  end;
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
  Prompt: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { 删除安装器写入的注册表项 Software\ArchoeraMusic（HKA：per-user=HKCU /
      per-machine=HKLM）。两个根都显式清理：非特权的 per-user 卸载对 HKLM
      会静默失败（无权限，不弹 UAC），per-machine 卸载则能清 HKLM；
      应用自身不写注册表，故此处删除即为全部注册表足迹。 }
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\{#AppName}');
    RegDeleteKeyIncludingSubkeys(HKEY_LOCAL_MACHINE, 'Software\{#AppName}');

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
