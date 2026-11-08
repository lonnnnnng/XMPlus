#!/usr/bin/env bash
# long: 保持 Flutter 默认产物目录，分发包统一放在既有 dist 中。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
flutter pub get --enforce-lockfile
bash tool/build_macos_media.sh
flutter build macos --release --no-pub --target lib/main.dart
APP="$ROOT/build/macos/Build/Products/Release/XMPlus.app"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/licenses/media" "$ROOT/dist" "$ROOT/Temp"
cp build/macos-media/universal/ffmpeg build/macos-media/universal/ffprobe "$APP/Contents/Helpers/"
cp LICENSE NOTICE "$APP/Contents/Resources/licenses/"
cp licenses/media/licenses/* "$APP/Contents/Resources/licenses/media/"
cp licenses/media/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/licenses/media/"
cp licenses/fonts/HarmonyOS_Sans_SC_LICENSE.txt "$APP/Contents/Resources/licenses/"

# long: 只检查和签名实际运行文件；源码、静态库和构建日志不得进入应用包。
python3 - "$APP" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
blocked = {'.dart', '.swift', '.c', '.cc', '.cpp', '.m', '.mm', '.h', '.hpp', '.a', '.o', '.log', '.zip', '.gz', '.xz'}
for path in app.rglob('*'):
    if path.is_file() and path.suffix in blocked:
        raise SystemExit(f'Development input in app: {path.relative_to(app)}')
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            subprocess.run(['lipo', str(path), '-verify_arch', 'arm64', 'x86_64'], check=True)
            links = subprocess.check_output(['otool', '-L', str(path)], text=True)
            for line in links.splitlines():
                if line.startswith('\t') and not line.strip().startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/', '@executable_path/')):
                    raise SystemExit(f'Nonportable library dependency: {path}: {line.strip()}')
for name in ('MacOS/XMPlus', 'Helpers/ffmpeg', 'Helpers/ffprobe', 'Frameworks/App.framework/App'):
    subprocess.run(['lipo', str(app / 'Contents' / name), '-verify_arch', 'arm64', 'x86_64'], check=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.lonnnnnng.xmplus':
    raise SystemExit('Unexpected bundle identifier')
receipt = {
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'architectures': ['arm64', 'x86_64'], 'minimumMacOS': info['LSMinimumSystemVersion'],
    'sourceRepository': 'https://github.com/lonnnnnng/XMPlus',
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'sourceDirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
    'nativeSources': json.loads(Path('tool/media_sources.json').read_text()),
    'signing': 'ad-hoc', 'notarized': False,
}
(app / 'Contents/Resources/build-receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
PY
codesign --force --deep --sign - --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="XMPlus-$VERSION-macos-universal"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"

STAGING="$(mktemp -d "$ROOT/Temp/macos-dmg.XXXXXX")"
ditto "$APP" "$STAGING/XMPlus.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname XMPlus -srcfolder "$STAGING" -format UDZO -ov "dist/$NAME.dmg"
hdiutil verify "dist/$NAME.dmg"
(cd dist && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS-macos)
# long: 只清理由本脚本刚创建的打包副本，构建产物和用户数据均不在此范围。
python3 - "$ROOT" "$STAGING" <<'PY'
import shutil, sys
from pathlib import Path
root, staging = map(lambda value: Path(value).resolve(), sys.argv[1:])
if staging.parent != root / 'Temp' or not staging.name.startswith('macos-dmg.'):
    raise SystemExit('Unexpected staging directory')
shutil.rmtree(staging)
PY
cat dist/SHA256SUMS-macos
