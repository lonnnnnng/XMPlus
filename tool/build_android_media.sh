#!/usr/bin/env bash
# long: Linux/macOS 共用锁定源码和 NDK 配方，主机差异不改变 Android 产物。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$ROOT}"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
MANIFEST="$SOURCE_ROOT/tool/media_sources.json"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:?Set ANDROID_HOME or ANDROID_NDK_HOME}/ndk/28.2.13676358}}"
BUILD="$ROOT/build/android-media"
case "$(uname -s)" in
    Darwin) HOST_TAG=darwin-x86_64; JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}";;
    Linux) HOST_TAG=linux-x86_64; JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}";;
    *) echo 'Build requires macOS or Linux' >&2; exit 1;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
# long: macOS 自带 shasum，避免为相同摘要算法安装第二套 coreutils。
sha256_file() { shasum -a 256 "$1" | cut -d' ' -f1; }
ABIS=(arm64-v8a armeabi-v7a x86_64)
if (( $# > 1 )); then echo "Usage: bash tool/build_android_media.sh [arm64-v8a|armeabi-v7a|x86_64]" >&2; exit 2; fi
if (( $# == 1 )); then
    case "$1" in arm64-v8a|armeabi-v7a|x86_64) ABIS=("$1");; *) echo "Unsupported ABI: $1" >&2; exit 2;; esac
fi
for command in jq make tar shasum; do command -v "$command" >/dev/null; done
[[ "$HOST_TAG" != linux-x86_64 || "$(uname -m)" == x86_64 ]] || { echo 'Linux build requires x86_64' >&2; exit 1; }
[[ -x "$TOOLCHAIN/bin/clang" ]] || { echo "Missing NDK toolchain: $TOOLCHAIN" >&2; exit 1; }
[[ "$(< "$NDK/source.properties")" == *'28.2.13676358'* ]] || { echo 'NDK 28.2.13676358 required' >&2; exit 1; }
mkdir -p "$BUILD/sources"
cp "$MANIFEST" "$BUILD/media_sources.json"

# No downloading and no inferred version/hash: use the exact archived inputs.
for component in ffmpeg lame; do
    entry="$(jq -ce --arg name "$component" '[.components[] | select(.name == $name)] | if length == 1 then .[0] else error("Missing/duplicate source") end' "$MANIFEST")"
    archive="$SOURCE_ROOT/$(jq -r '.file' <<< "$entry")"
    digest="$(jq -r '.sha256' <<< "$entry")"
    [[ "$(sha256_file "$archive")" == "$digest" ]] || { echo "Source hash mismatch: $archive" >&2; exit 1; }
    version="$(jq -r '.version' <<< "$entry")"
    destination="$BUILD/sources/$component-$version"
    # Re-extract verified source so stale or edited unpacked trees cannot enter a build.
    rm -rf "$destination"
    mkdir -p "$destination"
    tar -xf "$archive" -C "$destination" --strip-components=1 --exclude='[Rr][Ee][Aa][Dd][Mm][Ee]*'
    if [[ "$component" == ffmpeg ]]; then FFMPEG_SOURCE="$destination"; else LAME_SOURCE="$destination"; fi
done

export PATH="$TOOLCHAIN/bin:$PATH"
export AR="$TOOLCHAIN/bin/llvm-ar"
export NM="$TOOLCHAIN/bin/llvm-nm"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export AS="$TOOLCHAIN/bin/clang"
export PKG_CONFIG_LIBDIR=/nonexistent
export PKG_CONFIG_PATH=

for abi in "${ABIS[@]}"; do
    case "$abi" in
        arm64-v8a) target=aarch64-linux-android; host=aarch64-linux-android; arch=aarch64; cpu=armv8-a;;
        armeabi-v7a) target=armv7a-linux-androideabi; host=arm-linux-androideabi; arch=arm; cpu=armv7-a;;
        x86_64) target=x86_64-linux-android; host=x86_64-linux-android; arch=x86_64; cpu=x86-64; command -v nasm >/dev/null;;
    esac
    export CC="$TOOLCHAIN/bin/${target}24-clang"
    export CXX="$TOOLCHAIN/bin/${target}24-clang++"
    export CFLAGS='-O2 -fPIC'
    export CPPFLAGS=
    export LDFLAGS='-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384'
    export LIBS=
    WORK="$BUILD/$abi"
    rm -rf "$WORK"
    mkdir -p "$WORK/lame" "$WORK/ffmpeg" "$WORK/receipt/lame" "$WORK/receipt/ffmpeg"
    "$CC" --version > "$WORK/receipt/compiler-version.txt"
    declare -p CC CXX AR NM RANLIB STRIP AS CFLAGS CPPFLAGS LDFLAGS LIBS PKG_CONFIG_LIBDIR PKG_CONFIG_PATH > "$WORK/receipt/environment.txt"
    PREFIX="$WORK/prefix"
    (
        cd "$WORK/lame"
        args=("$LAME_SOURCE/configure" "--host=$host" "--prefix=$PREFIX"
              --disable-shared --enable-static --with-pic --disable-frontend --disable-decoder --disable-nasm)
        printf '%q ' "${args[@]}" > "$WORK/receipt/lame/configure-command.txt"
        printf '\n' >> "$WORK/receipt/lame/configure-command.txt"
        "${args[@]}"
        cp config.log config.h "$WORK/receipt/lame/"
        cp "$LAME_SOURCE/configure" "$WORK/receipt/lame/configure"
        make -j"$JOBS"
        make install
    )
    (
        cd "$WORK/ffmpeg"
        # This set mirrors MediaProcessor: audio transcode/remux/hash plus cover
        # decode and null-output validation. FFmpeg selects its core graph helpers.
        args=("$FFMPEG_SOURCE/configure" "--prefix=$PREFIX" --target-os=android
              "--arch=$arch" "--cpu=$cpu" --enable-cross-compile
              "--cc=$CC" "--cxx=$CXX" "--ar=$AR" "--nm=$NM" "--ranlib=$RANLIB" "--strip=$STRIP"
              --disable-everything --disable-autodetect --disable-network
              --enable-static --disable-shared --enable-pic --enable-libmp3lame --enable-zlib
              --enable-ffmpeg --enable-ffprobe --enable-protocol=file,pipe
              --enable-demuxer=aac,mp3,mov,flac,ogg,wav,image2,image2pipe,image_png_pipe,image_jpeg_pipe
              --enable-muxer=mp3,mov,mp4,ipod,flac,ogg,wav,null,hash
              --enable-decoder=aac,alac,mp3,mp3float,flac,vorbis,opus,png,mjpeg
              --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_s64le,pcm_s64be,pcm_u16le,pcm_u16be,pcm_u24le,pcm_u24be,pcm_u32le,pcm_u32be,pcm_f16le,pcm_f24le,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be
              --enable-encoder=libmp3lame,aac,flac,pcm_s16le,wrapped_avframe,mjpeg
              --enable-parser=aac,flac,mpegaudio,opus,vorbis,png,mjpeg
              --enable-bsf=aac_adtstoasc --enable-filter=anull,aresample,aformat,format,scale
              --disable-avdevice --disable-indevs --disable-outdevs --disable-ffplay --disable-doc --disable-debug
              "--extra-cflags=-O2 -fPIE -I$PREFIX/include"
              "--extra-ldflags=-L$PREFIX/lib -pie -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
              --extra-libs=-lm)
        printf '%q ' "${args[@]}" > "$WORK/receipt/ffmpeg/configure-command.txt"
        printf '\n' >> "$WORK/receipt/ffmpeg/configure-command.txt"
        "${args[@]}"
        cp ffbuild/config.log config.h config_components.h "$WORK/receipt/ffmpeg/"
        cp "$FFMPEG_SOURCE/configure" "$WORK/receipt/ffmpeg/configure"
        make -j"$JOBS" ffmpeg ffprobe
    )
    output="$ROOT/android/app/src/main/jniLibs/$abi"
    mkdir -p "$output"
    for tool in ffmpeg ffprobe; do
        "$STRIP" --strip-all -o "$output/libxmplus_$tool.so" "$WORK/ffmpeg/$tool"
        chmod 755 "$output/libxmplus_$tool.so"
        "$TOOLCHAIN/bin/llvm-readelf" -h -l -d "$output/libxmplus_$tool.so" > "$WORK/receipt/$tool.elf.txt"
        shasum -a 256 "$output/libxmplus_$tool.so" >> "$WORK/receipt/outputs.sha256"
    done
    jq -n --arg abi "$abi" --arg cc "$CC" --arg sourceRoot "$SOURCE_ROOT" \
        --arg ffmpeg "$(sha256_file "$output/libxmplus_ffmpeg.so")" \
        --arg ffprobe "$(sha256_file "$output/libxmplus_ffprobe.so")" \
        --slurpfile sources "$MANIFEST" \
        '{schemaVersion:1, abi:$abi, api:24, ndk:"28.2.13676358", compiler:$cc,
          sourceRoot:$sourceRoot, sources:$sources[0], executableType:"Android PIE (ET_DYN, not JNI)",
          elfMaxPageSizeRequested:16384, systemRuntimeAllowlist:["libc.so","libm.so","libdl.so","libz.so"],
          outputs:{"libxmplus_ffmpeg.so":$ffmpeg,"libxmplus_ffprobe.so":$ffprobe}}' > "$WORK/receipt/build-manifest.json"
    printf 'Built %s: %s\n' "$abi" "$output"
done
