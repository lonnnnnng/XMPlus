#!/usr/bin/env bash
# long: 使用仓库锁定的源码构建双架构工具，成品只依赖 macOS 系统库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required' >&2; exit 1; }
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"
BUILD="$ROOT/build/macos-media"
mkdir -p "$BUILD" "$ROOT/Temp"

# long: 源码与配方变化后使用新的构建目录，不复用可能混入旧版本的中间文件。
RECIPE="$(cat tool/build_macos_media.sh tool/media_sources.json | shasum -a 256 | cut -d' ' -f1)"
WORK="$BUILD/$RECIPE"
mkdir -p "$WORK/sources" "$BUILD/universal"
python3 - "$ROOT" "$WORK/sources" <<'PY'
import hashlib, json, sys, tarfile
from pathlib import Path
root, output = map(Path, sys.argv[1:])
for item in json.loads((root / 'tool/media_sources.json').read_text())['components']:
    archive = root / item['file']
    if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit(f"Source hash mismatch: {item['name']}")
    target = output / f"{item['name']}-{item['version']}"
    if not target.exists():
        with tarfile.open(archive) as source:
            source.extractall(output, filter='data')
PY
FFMPEG_SOURCE="$WORK/sources/ffmpeg-9.0.2"
LAME_SOURCE="$WORK/sources/lame-3.100"

for arch in arm64 x86_64; do
    prefix="$WORK/$arch/prefix"
    mkdir -p "$WORK/$arch/lame" "$WORK/$arch/ffmpeg"
    if [[ ! -f "$WORK/$arch/complete" ]]; then
        (
            export CC="$CLANG -arch $arch -isysroot $SDK"
            export CFLAGS='-O2 -fPIC -mmacosx-version-min=12.0'
            export LDFLAGS='-mmacosx-version-min=12.0'
            export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
            export PKG_CONFIG_PATH=
            cd "$WORK/$arch/lame"
            hostarch="$arch"
            [[ "$arch" != arm64 ]] || hostarch=aarch64
            "$LAME_SOURCE/configure" --host="$hostarch-apple-darwin" --prefix="$prefix" \
                --disable-shared --enable-static --with-pic --disable-frontend --disable-decoder --disable-nasm
            make -j"$JOBS"
            make install
            cd "$WORK/$arch/ffmpeg"
            ffarch="$arch"
            [[ "$arch" != arm64 ]] || ffarch=aarch64
            # long: 上游通过 FFmetadata 文件写入标签，缺少解复用器会让默认下载在媒体处理阶段失败。
            "$FFMPEG_SOURCE/configure" --prefix="$prefix" --target-os=darwin --arch="$ffarch" \
                --enable-cross-compile --cc="$CLANG" --sysroot="$SDK" \
                --disable-everything --disable-autodetect --disable-network --disable-x86asm \
                --enable-static --disable-shared --enable-pic --enable-libmp3lame --enable-zlib \
                --enable-ffmpeg --enable-ffprobe --enable-protocol=file,pipe \
                --enable-demuxer=aac,mp3,mov,flac,ogg,wav,ffmetadata,image2,image2pipe,image_png_pipe,image_jpeg_pipe \
                --enable-muxer=mp3,mov,mp4,ipod,flac,ogg,wav,null,hash \
                --enable-decoder=aac,alac,mp3,mp3float,flac,vorbis,opus,png,mjpeg \
                --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_s64le,pcm_s64be,pcm_u16le,pcm_u16be,pcm_u24le,pcm_u24be,pcm_u32le,pcm_u32be,pcm_f16le,pcm_f24le,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be \
                --enable-encoder=libmp3lame,aac,flac,pcm_s16le,wrapped_avframe,mjpeg \
                --enable-parser=aac,flac,mpegaudio,opus,vorbis,png,mjpeg \
                --enable-bsf=aac_adtstoasc --enable-filter=anull,aresample,aformat,format,scale \
                --disable-avdevice --disable-indevs --disable-outdevs --disable-ffplay --disable-doc --disable-debug \
                --extra-cflags="-O2 -arch $arch -mmacosx-version-min=12.0 -I$prefix/include" \
                --extra-ldflags="-arch $arch -mmacosx-version-min=12.0 -L$prefix/lib"
            make -j"$JOBS" ffmpeg ffprobe
        )
        touch "$WORK/$arch/complete"
    fi
done

for executable in ffmpeg ffprobe; do
    lipo -create "$WORK/arm64/ffmpeg/$executable" "$WORK/x86_64/ffmpeg/$executable" \
        -output "$BUILD/universal/$executable"
    strip -x "$BUILD/universal/$executable"
    codesign --force --sign - "$BUILD/universal/$executable"
    lipo "$BUILD/universal/$executable" -verify_arch arm64 x86_64
    # long: 禁止把构建机 Homebrew 路径带入发布包，确保其他 Mac 也能启动工具。
    otool -L "$BUILD/universal/$executable" | awk '/^\t/ {print $1}' | while read -r dependency; do
        case "$dependency" in /usr/lib/*|/System/Library/*) ;; *) echo "Non-system dependency: $dependency" >&2; exit 1;; esac
    done
done
"$BUILD/universal/ffmpeg" -version | head -n 1
"$BUILD/universal/ffprobe" -version | head -n 1
