#!/usr/bin/env bash
# =====================================================================
#  构建「最小自包含 · 纯 LGPL · 仅音频」FFmpeg（Linux / macOS）。
#
#  目的（三条）：
#   1. 自包含：发行版自带的 FFmpeg 链接大量外部视频/图像库（libx264/x265/
#      vpx/aom/SvtAv1/rav1e/jxl/librsvg→libicudata …），内嵌闭包 +236MB，
#      而音乐播放用不到；Homebrew 的 ffmpeg 同理。自建最小版只依赖
#      libc/libm/libz，soname 固定，不受系统版本影响。
#   2. 许可证：本项目 AGPL-3.0，THIRD-PARTY-LICENSES 明确要求 FFmpeg 为
#      **纯 LGPL 构建**（CONFIG_GPL=0 / CONFIG_NONFREE=0）且仅动态链接。
#      Homebrew ffmpeg 默认 --enable-gpl（GPL-3.0），会破坏该「GPL 防火墙」；
#      这里显式 --disable-gpl --disable-nonfree，保持 LGPL-2.1+。
#   3. 仅音频：本软件只做音频解码 + 标签/元数据读取 + Opus/OGG 转码，
#      完全不碰视频/图像/字幕。故用 --disable-everything 后只白名单启用
#      **全部内部音频解码器** + 所需 demuxer/parser/protocol + OGG 封装，
#      并关掉 swscale/avfilter/avdevice 等库。
#      Opus 编码用外部 **libopus**（BSD-3-Clause，需系统 libopus 开发包）：
#      FFmpeg 自带 opus 编码器标记为 experimental 且仅支持 planar fltp，
#      而引擎按 libopus 的 interleaved flt 接口编写（见 src/encoder.c）。
#      实测内嵌库从 ~22MB 降到 ~6MB（全部视频解码器/编码器/滤镜不再编译）。
#      注意：FFmpeg **没有** `--disable-video` 选项，只能按组件白名单裁剪；
#      解码器名单由 FFmpeg 9.0.1 `libavcodec/allcodecs.c` 的内部解码器
#      与 `ffmpeg -decoders` 的音频类别求交集生成（升级 FFmpeg 时需同步）。
#
#  环境变量：
#    FFMPEG_VERSION  源码版本（默认 9.0.1）
#    FFMPEG_PREFIX   安装前缀（默认 $HOME/.local/ffmpeg-minimal）
#  用法: build-ffmpeg-minimal.sh
# =====================================================================
set -euo pipefail

VER="${FFMPEG_VERSION:-9.0.1}"
PREFIX="${FFMPEG_PREFIX:-$HOME/.local/ffmpeg-minimal}"
if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"; else JOBS="$(sysctl -n hw.ncpu)"; fi

if [[ -f "$PREFIX/lib/libavformat.so" || -f "$PREFIX/lib/libavformat.dylib" ]]; then
  echo "[build-ffmpeg-minimal] 已存在，跳过：$PREFIX"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "[build-ffmpeg-minimal] 下载 FFmpeg $VER 源码…"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "$work/ffmpeg.tar.xz"
tar -C "$work" -xf "$work/ffmpeg.tar.xz"
cd "$work/ffmpeg-$VER"

# 有 nasm/yasm 则启用 x86 汇编加速；否则退化（仍可正常解码）
x86asm=()
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
  echo "[build-ffmpeg-minimal] 未找到 nasm/yasm → --disable-x86asm（性能降级，功能不受影响）"
  x86asm=(--disable-x86asm)
fi

# 共享库 RUNPATH：Linux 用 $ORIGIN；macOS 用 @loader_path（同目录解析）
if [[ "$(uname -s)" == "Darwin" ]]; then
  extra_ldflags="-Wl,-rpath,@loader_path"
else
  extra_ldflags="-Wl,-z,origin -Wl,-rpath,\$ORIGIN"
fi

# ── 仅音频组件白名单（--disable-everything 后按需启用）──────────────────
# 解码器：FFmpeg 9.0.1 全部「内部音频解码器」（libavcodec/allcodecs.c 内部
#   解码器 ∩ `ffmpeg -decoders` 音频类别），不含任何视频/图像解码器。
#   升级 FFmpeg 版本时需重新生成（方法见文件头注释）。
AUDIO_DECODERS="aac,aac_fixed,aac_latm,ac3,ac3_fixed,adpcm_4xm,adpcm_adx,adpcm_afc,adpcm_agm,adpcm_aica,adpcm_argo,adpcm_circus,adpcm_ct,adpcm_dtk,adpcm_ea,adpcm_ea_maxis_xa,adpcm_ea_r1,adpcm_ea_r2,adpcm_ea_r3,adpcm_ea_xas,adpcm_ima_acorn,adpcm_ima_alp,adpcm_ima_amv,adpcm_ima_apc,adpcm_ima_apm,adpcm_ima_cunning,adpcm_ima_dat4,adpcm_ima_dk3,adpcm_ima_dk4,adpcm_ima_ea_eacs,adpcm_ima_ea_sead,adpcm_ima_escape,adpcm_ima_hvqm2,adpcm_ima_hvqm4,adpcm_ima_iss,adpcm_ima_magix,adpcm_ima_moflex,adpcm_ima_mtf,adpcm_ima_oki,adpcm_ima_pda,adpcm_ima_qt,adpcm_ima_rad,adpcm_ima_smjpeg,adpcm_ima_ssi,adpcm_ima_wav,adpcm_ima_ws,adpcm_ima_xbox,adpcm_ms,adpcm_mtaf,adpcm_n64,adpcm_psx,adpcm_psxc,adpcm_sanyo,adpcm_sbpro_2,adpcm_sbpro_3,adpcm_sbpro_4,adpcm_swf,adpcm_thp,adpcm_thp_le,adpcm_vima,adpcm_xa,adpcm_xmd,adpcm_yamaha,adpcm_zork,ahx,alac,als,amrnb,amrwb,anull,apac,ape,aptx,aptx_hd,atrac1,atrac3,atrac3al,atrac9,binkaudio_dct,binkaudio_rdft,bmv_audio,bonk,cbd2_dpcm,comfortnoise,cook,dca,derf_dpcm,dfpwm,dolby_e,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,dsicinaudio,dss_sp,dst,dvaudio,eac3,evrc,fastaudio,flac,ftr,g723_1,g728,g729,gremlin_dpcm,gsm,gsm_ms,hca,hcom,iac,ilbc,imc,interplay_dpcm,mace3,mace6,metasound,misc4,mlp,mp1,mp1float,mp2,mp2float,mp3,mp3adu,mp3adufloat,mp3float,mp3on4,mp3on4float,mpc7,mpc8,msnsiren,nellymoser,on2avc,opus,osq,paf_audio,pcm_alaw,pcm_bluray,pcm_dvd,pcm_f16le,pcm_f24le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_lxf,pcm_mulaw,pcm_s16be,pcm_s16be_planar,pcm_s16le,pcm_s16le_planar,pcm_s24be,pcm_s24daud,pcm_s24le,pcm_s24le_planar,pcm_s32be,pcm_s32le,pcm_s32le_planar,pcm_s64be,pcm_s64le,pcm_s8,pcm_s8_planar,pcm_sga,pcm_u16be,pcm_u16le,pcm_u24be,pcm_u24le,pcm_u32be,pcm_u32le,pcm_u8,pcm_vidc,qcelp,qdm2,qdmc,qoa,ralf,rka,roq_dpcm,s302m,sbc,sdx2_dpcm,shorten,sipr,siren,smackaud,sol_dpcm,speex,tak,truehd,truespeech,tta,twinvq,vmdaudio,vorbis,wady_dpcm,wavarc,wavpack,wmalossless,wmapro,wmav1,wmav2,wmavoice,ws_snd1,xan_dpcm,xma1,xma2"

# 解复用器：本软件支持的全部音频容器 + 常见在线流（HLS/TS/FLV/RTP/RTSP）。
#   注意 dash/smoothstreaming 依赖 libxml2，未启用（--disable-autodetect）。
AUDIO_DEMUXERS="aac,ac3,ac4,acm,adx,aiff,amr,amrnb,amrwb,ape,asf,au,caf,dsf,dts,dtshd,eac3,ffmetadata,flac,flv,g722,g723_1,g726,g726le,g729,gsm,hls,ilbc,loas,matroska,mlp,mov,mp3,mpc,mpc8,mpegts,ogg,oma,rm,rtp,rtsp,sbc,sdp,shorten,sln,tak,truehd,tta,voc,vqf,w64,wav,wsaud,wv,xwma"

# 解析器：音频解析器（提升流探测与首帧准确度）。
AUDIO_PARSERS="aac,aac_latm,ac3,adx,amr,cook,dca,dolby_e,dvaudio,flac,ftr,g723_1,g729,gsm,misc4,mlp,mpegaudio,opus,sbc,sipr,tak,vorbis,xma"

# 协议：本地文件 + 网络流。不含 https/tls：本构建无 TLS 后端（与原构建一致，
#   在线源由 Dart 侧下载/缓存后交给引擎，或平台返回 http 直链）。
PROTOCOLS="file,pipe,http,httpproxy,tcp,udp,rtp,srtp,crypto,data,cache,concat"

echo "[build-ffmpeg-minimal] configure（纯 LGPL · 仅音频 · 共享库）…"
# --disable-autodetect：关闭所有外部库自动探测（zlib 除外，显式开启）
# --disable-gpl/nonfree：显式声明。注意 FFmpeg **没有** --enable-lgpl 选项：
#   LGPL-2.1+ 本就是默认（仅 --enable-gpl 会转 GPL，--enable-version3 会升
#   LGPLv3/GPLv3）。此配置产出 license="LGPL version 2.1 or later"
#   （可用 avutil_license() 验证），满足 AGPL-3.0 聚合分发的「GPL 防火墙」。
# --disable-programs   ：不出 ffmpeg/ffprobe 可执行文件，只出库
# --disable-swscale/avfilter/avdevice：音频管线用不到，直接不编译
#   （FFmpeg 9 已移除 postproc 库，无需/不可再传 --disable-postproc）
# --disable-everything ：先清空全部组件，再白名单启用——视频解码器即被砍掉
./configure \
  --prefix="$PREFIX" \
  --disable-autodetect \
  --enable-zlib \
  --disable-gpl \
  --disable-nonfree \
  --disable-programs \
  --disable-doc \
  --disable-static \
  --enable-shared \
  --disable-swscale \
  --disable-avfilter \
  --disable-avdevice \
  --disable-everything \
  --enable-decoder="$AUDIO_DECODERS" \
  --enable-libopus \
  --enable-encoder=libopus \
  --enable-muxer=ogg,opus \
  --enable-demuxer="$AUDIO_DEMUXERS" \
  --enable-parser="$AUDIO_PARSERS" \
  --enable-protocol="$PROTOCOLS" \
  "${x86asm[@]}" \
  --extra-ldflags="$extra_ldflags"

echo "[build-ffmpeg-minimal] make -j$JOBS …"
make -j"$JOBS"
make install

# LGPL 合规：随库附上 FFmpeg 许可文本（打包时一并分发）
mkdir -p "$PREFIX/share/licenses/ffmpeg"
cp -f COPYING.LGPLv2.1 "$PREFIX/share/licenses/ffmpeg/" 2>/dev/null || true
cp -f LICENSE.md "$PREFIX/share/licenses/ffmpeg/" 2>/dev/null || true
{
  echo "FFmpeg $VER — 纯 LGPL · 仅音频构建（--disable-gpl --disable-nonfree --disable-autodetect --disable-everything）"
  echo "源码：https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
} > "$PREFIX/share/licenses/ffmpeg/BUILD-CONFIG.txt"

echo "[build-ffmpeg-minimal] 安装完成：$PREFIX"
ls -1 "$PREFIX/lib"/libav*.so* "$PREFIX/lib"/libswresample.so* 2>/dev/null \
  || ls -1 "$PREFIX/lib"/libav*.dylib "$PREFIX/lib"/libswresample*.dylib 2>/dev/null || true
