; ArchoeraMusic Windows Installer (NSIS 3+)
; 用法（CI）：
;   makensis.exe /DVERSION=0.9.12+3 /DAPP_DIR=<release目录> \
;     /DOUT_FILE=<安装器输出路径> packaging\windows\archoera_music.nsi

!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef APP_DIR
  !define APP_DIR ""
!endif
!ifndef OUT_FILE
  !define OUT_FILE "ArchoeraMusic-${VERSION}-win-setup.exe"
!endif

!define APP_EXE "archoera_music.exe"
!define APP_NAME "ArchoeraMusic"
!define APP_REG "ArchoeraMusic"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
InstallDir "$PROGRAMFILES64\ArchoeraMusic"
SetCompressor lzma
RequestExecutionLevel admin

!define MUI_ICON "..\..\app\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "..\..\app\windows\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "ArchoeraMusic" SecMain
  SetRegView 64
  SetOutPath "$INSTDIR"
  ; 整个 Release 目录递归装入（exe / data / native / 插件 dll）
  File /r "${APP_DIR}\*"

  ; 开始菜单与桌面快捷方式
  CreateDirectory "$SMPROGRAMS\${APP_REG}"
  CreateShortCut "$SMPROGRAMS\${APP_REG}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; 卸载项
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "Publisher" "BetaStudio2"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetRegView 64
  ; 快捷方式：桌面 + 开始菜单目录内 + 应用自建的 AUMID 快捷方式（Toast 用）
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_REG}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_REG}"

  ; 注册表：卸载项
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_REG}"

  ; 用户数据（%LOCALAPPDATA%\ArchoeraMusic：设置/缓存/下载索引）：
  ; **默认删除**，用户可选保留（默认按钮 = 是）。
  MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON1 \
    "是否删除用户数据（设置、缓存、下载索引）？$\r$\n$\r$\n$LOCALAPPDATA\ArchoeraMusic" \
    IDNO keep_userdata
  RMDir /r "$LOCALAPPDATA\ArchoeraMusic"
  keep_userdata:

  RMDir /r "$INSTDIR"
SectionEnd
