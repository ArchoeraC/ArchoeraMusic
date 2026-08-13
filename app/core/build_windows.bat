@echo off
rem =====================================================================
rem  ArchoeraMusic Windows 全模块一站式构建引导（bat 全量接管）
rem
rem  在单个 cmd 会话内完成：
rem    1. vswhere 定位 VS + call vcvars64.bat（MSVC/cl.exe/link.exe 环境）
rem    2. audio-engine : cargo tempo staticlib + cl 直编 fft.dll / archoera_mediaengine.dll
rem    3. scraper      : CMake + vcpkg toolchain（Windows 保留 CMake）
rem    4. scanner      : dotnet publish (NativeAOT) + e_sqlite3.dll
rem    5. downloader   : cargo build --release (cdylib)
rem    6. subsonic     : cargo transcoder + go c-shared + go standalone
rem    7. vault        : dotnet publish (NativeAOT 凭据保险库)
rem
rem  依赖（vcpkg FFmpeg、MSVC、Rust、Go、.NET、CMake）由 CI workflow 提前安装，
rem  本脚本只做编译引导；vcpkg FFmpeg headers 缺失时会自动 install 兜底
rem （幂等），本地开发无需手动预装。产物布局与 app/windows/CMakeLists.txt
rem  install 引用对齐。
rem =====================================================================
setlocal enabledelayedexpansion

rem ---- 路径 ----
set "ROOT=%~dp0"                        rem app/core/
set "TRIPLET=%VCPKG_TARGET_TRIPLET%"
if "%TRIPLET%"=="" set "TRIPLET=x64-windows-release"
set "VCPKG_PREFIX=%ROOT%..\vcpkg_installed\%TRIPLET%"
if "%VCPKG_ROOT%"=="" set "VCPKG_ROOT=C:\vcpkg"
set "VCPKG_TOOLCHAIN=%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake"

echo [build_windows] vcpkg prefix: %VCPKG_PREFIX%
echo [build_windows] vcpkg toolchain: %VCPKG_TOOLCHAIN%

rem 依赖幂等兜底：FFmpeg headers 缺失时自动 vcpkg install（manifest 模式，见 app/vcpkg.json）。
rem 本地开发无需手动预装；CI 已显式 install（仅为 vcpkg_installed 缓存加速）会跳过此处。
set "VCPKG_EXE=vcpkg"
if exist "%VCPKG_ROOT%\vcpkg.exe" set "VCPKG_EXE=%VCPKG_ROOT%\vcpkg.exe"
if not exist "%VCPKG_PREFIX%\include\libavformat\avformat.h" (
    echo [build_windows] FFmpeg headers not found — 自动执行 vcpkg install ^(manifest 模式, triplet=%TRIPLET%^)...
    pushd "%ROOT%.."
    call "%VCPKG_EXE%" install --triplet "%TRIPLET%"
    if errorlevel 1 (
        echo [build_windows] ERROR: vcpkg install 失败
        exit /b 1
    )
    popd
    if not exist "%VCPKG_PREFIX%\include\libavformat\avformat.h" (
        echo [build_windows] ERROR: vcpkg install 后仍缺 FFmpeg headers ^(检查 %VCPKG_PREFIX%^)
        exit /b 1
    )
)

rem =====================================================================
rem  1. 定位 Visual Studio 并初始化 MSVC 环境（全会话生效）
rem =====================================================================
set "VSROOT="
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if not defined VSROOT (
    echo [build_windows] ERROR: vswhere 未找到 VS C++ 工具集
    exit /b 1
)
echo [build_windows] Visual Studio: %VSROOT%
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul

rem =====================================================================
rem  2. audio-engine：tempo staticlib + fft.dll + archoera_mediaengine.dll
rem =====================================================================
echo [build_windows] ===== audio-engine =====
pushd "%ROOT%audio-engine"
if not exist build mkdir build

echo [build_windows] 构建 Rust tempo staticlib...
cargo build --release --manifest-path tempo-rs\Cargo.toml --target-dir build\tempo-target
if errorlevel 1 exit /b 1

rem tempo staticlib 归一化：MSVC 输出 audio_tempo.lib 或 libaudio_tempo.lib
set "TEMPO_FOUND="
for /r build\tempo-target %%f in (*audio_tempo.lib) do (
    if not defined TEMPO_FOUND (
        copy /y "%%f" "build\libaudio_tempo.lib" >nul
        set "TEMPO_FOUND=1"
    )
)
if not defined TEMPO_FOUND (
    echo [build_windows] ERROR: tempo staticlib 未找到
    exit /b 1
)

rem .def 导出表（Dart FFI lookup 符号）
> build\archoera_mediaengine.def echo EXPORTS
>> build\archoera_mediaengine.def echo     archoera_mediaengine_create
>> build\archoera_mediaengine.def echo     archoera_mediaengine_command
>> build\archoera_mediaengine.def echo     archoera_mediaengine_poll_event
>> build\archoera_mediaengine.def echo     archoera_mediaengine_session_dir
>> build\archoera_mediaengine.def echo     archoera_mediaengine_is_done
>> build\archoera_mediaengine.def echo     archoera_mediaengine_destroy
> build\fft.def echo EXPORTS
>> build\fft.def echo     fft_create
>> build\fft.def echo     fft_set_enabled
>> build\fft.def echo     fft_process_frame
>> build\fft.def echo     fft_get_spectrum_norm_stereo
>> build\fft.def echo     fft_take_beat_strength
>> build\fft.def echo     fft_destroy

echo [build_windows] 编译 fft.dll...
cl /nologo /O2 /MD /LD /I include /I src src\fft.c /Fe:build\fft.dll /link /DEF:build\fft.def
if errorlevel 1 exit /b 1

echo [build_windows] 编译 archoera_mediaengine.dll...
cl /nologo /O2 /MD /LD /I include /I src /I include\compat /I "%VCPKG_PREFIX%\include" ^
    src\mediaengine_lib.c src\tempo.c src\decoder.c src\resampler.c ^
    src\encoder.c src\equalizer.c src\loudness.c src\limiter.c ^
    src\pipeline.c src\pcm_uds.c src\player.c src\fft.c ^
    "%VCPKG_PREFIX%\lib\avformat.lib" "%VCPKG_PREFIX%\lib\avcodec.lib" ^
    "%VCPKG_PREFIX%\lib\avutil.lib" "%VCPKG_PREFIX%\lib\swresample.lib" ^
    build\libaudio_tempo.lib ntdll.lib ^
    /Fe:build\archoera_mediaengine.dll /link /DEF:build\archoera_mediaengine.def
if errorlevel 1 exit /b 1
popd

rem =====================================================================
rem  3. scraper：CMake + vcpkg toolchain
rem =====================================================================
echo [build_windows] ===== scraper =====
pushd "%ROOT%scraper"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release ^
    -DVCPKG_TARGET_TRIPLET=%TRIPLET% ^
    -DVCPKG_INSTALLED_DIR=%ROOT%..\vcpkg_installed ^
    "-DCMAKE_TOOLCHAIN_FILE=%VCPKG_TOOLCHAIN%"
if errorlevel 1 exit /b 1
cmake --build build --config Release
if errorlevel 1 exit /b 1

rem 产物从 build/Release/ 复制到 build/（与 windows/CMakeLists install 引用对齐）
copy /y build\Release\archoera_scraper.dll build\ >nul
for %%f in (build\Release\*.dll) do (
    if /i not "%%~nxf"=="archoera_scraper.dll" copy /y "%%f" build\ >nul
)
popd

rem =====================================================================
rem  4. scanner：dotnet publish (NativeAOT) + sqlite 原生库
rem =====================================================================
echo [build_windows] ===== scanner =====
pushd "%ROOT%scanner"
if not exist build mkdir build
dotnet publish scanner-ffi\scanner-ffi.csproj -c Release -r win-x64
if errorlevel 1 exit /b 1

rem csproj 的 CopyToScannerBuild target（AfterTargets=Publish）已把主库与
rem e_sqlite3.dll 复制到 build/（publish 目录含 x64 子目录，不在此硬编码路径）
if not exist "build\scanner-ffi.dll" (
    echo [build_windows] ERROR: scanner-ffi.dll 未复制到 build/
    exit /b 1
)
if not exist "build\e_sqlite3.dll" (
    echo [build_windows] ERROR: SQLitePCLRaw 原生库缺失 ^(e_sqlite3.dll^)
    exit /b 1
)
popd

rem =====================================================================
rem  5. downloader：cargo cdylib
rem =====================================================================
echo [build_windows] ===== downloader =====
pushd "%ROOT%downloader"
cargo build --release
if errorlevel 1 exit /b 1
popd

rem =====================================================================
rem  6. subsonic：cargo transcoder + go c-shared + go standalone
rem =====================================================================
echo [build_windows] ===== subsonic =====
pushd "%ROOT%subsonic"
if not exist build mkdir build

echo [build_windows] 构建转码器 (cargo cdylib)...
pushd transcoder
cargo build --release
if errorlevel 1 exit /b 1
popd

echo [build_windows] 构建服务端 (go c-shared)...
set CGO_ENABLED=1
go build -buildmode=c-shared -o build\libarchoera_subsonic.dll .
if errorlevel 1 exit /b 1

echo [build_windows] 构建独立可执行 (go -tags standalone)...
go build -tags standalone -o build\archoera-subsonic.exe .
if errorlevel 1 exit /b 1

rem Windows 下 cdylib 无 lib 前缀
set "TRANS_SRC=transcoder\target\release\archoera_transcoder.dll"
if not exist "%TRANS_SRC%" (
    echo [build_windows] ERROR: transcoder 产物缺失
    exit /b 1
)
copy /y "%TRANS_SRC%" build\ >nul
popd

rem =====================================================================
rem  7. vault：dotnet publish (NativeAOT 凭据保险库)
rem =====================================================================
echo [build_windows] ===== vault =====
pushd "%ROOT%vault"
if not exist build mkdir build
dotnet publish src\Vault.csproj -c Release -r win-x64
if errorlevel 1 exit /b 1
copy /y "src\bin\Release\net9.0\win-x64\publish\archoera-vault.exe" build\ >nul
if not exist "build\archoera-vault.exe" (
    echo [build_windows] ERROR: archoera-vault.exe 未复制到 build/
    exit /b 1
)
popd

echo [build_windows] 全部模块构建完成
exit /b 0
