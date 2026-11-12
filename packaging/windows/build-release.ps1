<#
.SYNOPSIS
  ArchoeraMusic Windows 发布脚本（**Windows 专用，自包含**）。

.DESCRIPTION
  规则（AGENTS.md「禁止脚本混合」）：
    - Windows 的装配 / 校验 / 打包只在本文件与 packaging/windows/ 内，
      不调用其它平台的脚本，也不依赖 app/tool 下的检查脚本；
    - 只用 Windows 工具：PowerShell / Inno Setup (iscc) / 可选 dumpbin。

  子命令：
    bundle   检查 Flutter Release 目录并放入防伪公钥
    verify   必需文件齐全（kernel / mediaengine / scraper / scanner / indexer /
             e_sqlite3 / vault）；可用时用 dumpbin 检查导入表只指向系统 DLL
    package  便携 zip + Inno Setup 安装器（默认 per-user 免 UAC）
    all      bundle → verify → package（任一步失败即整体失败）

  本脚本不含任何测试：测试全部在本地按 AGENTS.md「提交前必跑」执行。

.EXAMPLE
  pwsh -File packaging/windows/build-release.ps1 all
  pwsh -File packaging/windows/build-release.ps1 verify -Release app/build/windows/x64/runner/Release
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('bundle', 'verify', 'package', 'all')]
    [string]$Step = 'all',

    [string]$Release = 'app\build\windows\x64\runner\Release',
    [string]$OutDir = 'build\windows-extra',
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    Write-Error '本脚本只能在 Windows 上运行（需要 Inno Setup / PowerShell）'
    exit 2
}

# packaging/windows/ → 仓库根
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $Root

function Write-Log([string]$Message) { Write-Host "[windows] $Message" }
function Stop-WithError([string]$Message) { Write-Host "::error::$Message"; exit 1 }

if (-not $Version) {
    $line = Select-String -Path 'app\pubspec.yaml' -Pattern '^version:' | Select-Object -First 1
    $Version = ($line.Line -split '\s+')[1].Trim()
}
# Inno 的 VersionInfoVersion 必须四段数字：1.0.6+4 → 1.0.6.4
$verParts = $Version -split '\+'
$verNum = if ($verParts.Count -ge 2) { "$($verParts[0]).$($verParts[1])" } else { "$($verParts[0]).0" }

function Invoke-Bundle {
    if (-not (Test-Path $Release)) {
        Stop-WithError "找不到 Flutter Release 目录：$Release（先跑 flutter build windows --release）"
    }
    # 防伪公钥随包分发（私钥绝不入库/入包）
    Copy-Item 'app\tool\watermark_pub.pem' (Join-Path $Release 'ARCHOERA_PUBKEY.pem') -Force
    Write-Log 'bundle 完成（native/ 由 CMake install 目标填充）'
}

function Invoke-Verify {
    if (-not (Test-Path $Release)) { Stop-WithError "找不到 Release 目录：$Release" }

    # 名称与 app/windows/CMakeLists.txt 的 install 目标一一对应：
    # archoera_kernel.dll 在 exe 根（Windows 加载器按 exe 目录解析），其余在 native/。
    $required = @(
        'archoera_music.exe',
        'archoera_kernel.dll',
        'native\archoera_mediaengine.dll',
        'native\archoera_scraper.dll',
        'native\scanner-ffi.dll',
        'native\indexer-ffi.dll',
        'native\e_sqlite3.dll',
        'native\archoera-vault.exe'
    )
    $missing = @()
    foreach ($rel in $required) {
        $p = Join-Path $Release $rel
        if (-not (Test-Path $p)) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
        Stop-WithError ("缺少发布必需文件：" + ($missing -join ', '))
    }
    Write-Log "必需文件齐全（$($required.Count) 项）"

    # 完整性清单必须覆盖 native/ 下的 DLL（Dart 侧按清单 fail-closed 校验）
    $manifest = Join-Path $Release 'native\ARCHOERA-NATIVE-MANIFEST.txt'
    if (-not (Test-Path $manifest)) { Stop-WithError '缺少 native\ARCHOERA-NATIVE-MANIFEST.txt' }
    $manifestText = Get-Content $manifest -Raw
    Get-ChildItem (Join-Path $Release 'native') -Filter *.dll | ForEach-Object {
        if ($manifestText -notmatch [regex]::Escape("  $($_.Name)")) {
            Stop-WithError "完整性清单缺少 $($_.Name)"
        }
    }
    Write-Log '完整性清单覆盖 native/ 全部 DLL'

    # 导入表检查（dumpbin 可用时）：不得依赖构建机绝对路径的 DLL
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($null -eq $dumpbin) {
        foreach ($base in @('C:\Program Files\Microsoft Visual Studio', 'C:\Program Files (x86)\Microsoft Visual Studio')) {
            if (Test-Path $base) {
                $hit = Get-ChildItem $base -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($null -ne $hit) { $dumpbin = $hit; break }
            }
        }
    }
    if ($null -eq $dumpbin) {
        Write-Log '提示: 未找到 dumpbin，跳过导入表检查'
        return
    }

    $binaries = @(Get-ChildItem $Release -Filter *.exe) +
        @(Get-ChildItem $Release -Filter *.dll) +
        @(Get-ChildItem (Join-Path $Release 'native') -Filter *.dll)
    $bad = @()
    foreach ($bin in $binaries) {
        $imports = & $dumpbin /dependents $bin.FullName 2>$null
        foreach ($line in $imports) {
            $t = $line.Trim()
            if ($t -match '^[A-Za-z]:\\|^\\\\') { $bad += "$($bin.Name) → $t" }
        }
    }
    if ($bad.Count -gt 0) {
        Stop-WithError ("存在构建机绝对路径依赖：" + ($bad -join '; '))
    }
    Write-Log 'PE 导入表检查通过'
}

function Invoke-Package {
    if (-not (Test-Path $Release)) { Stop-WithError "找不到 Release 目录：$Release" }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    # 便携 zip：Release 目录整体（含 native/、data/、插件 dll）
    $zip = Join-Path $OutDir "ArchoeraMusic-$Version-windows-x64-portable.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $Release '*') -DestinationPath $zip -Force
    Write-Log "portable zip: $zip"

    # Inno Setup 安装器（优先 PATH 内 iscc，其次 6.x 默认安装目录）
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if ($null -eq $iscc) {
        $candidates = @(
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe'
        )
        foreach ($c in $candidates) { if (Test-Path $c) { $iscc = $c; break } }
    } else {
        $iscc = $iscc.Source
    }
    if ($null -eq $iscc) { Stop-WithError '未找到 iscc（Inno Setup 6），无法生成安装器' }

    & $iscc "/DVersion=$Version" "/DVersionNumeric=$verNum" `
        "/DAppDir=$PWD\$Release" "/DOutputDir=$PWD\$OutDir" `
        'packaging\windows\archoera_music.iss'
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Inno Setup 失败（rc=$LASTEXITCODE）" }
    Write-Log 'Inno Setup 安装器完成'
}

switch ($Step) {
    'bundle' { Invoke-Bundle }
    'verify' { Invoke-Verify }
    'package' { Invoke-Package }
    'all' {
        Invoke-Bundle
        Invoke-Verify
        Invoke-Package
    }
}
