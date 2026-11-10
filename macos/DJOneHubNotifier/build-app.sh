#!/bin/zsh

set -eu

root="${0:A:h}"
build_root="${root}/.build"
output_root="${root}/dist"
app="${output_root}/DJOneHubNotifier.app"
cache_root="${build_root}/local-cache"

cd "${root}"
mkdir -p "${cache_root}/clang" "${cache_root}/swiftpm"
export CLANG_MODULE_CACHE_PATH="${cache_root}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${cache_root}/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="${cache_root}/swiftpm"
configuration="${CONFIGURATION:-release}"
swift build --disable-sandbox -c "${configuration}"
"${build_root}/${configuration}/DJOneHubNotifier" --self-test

rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "${build_root}/${configuration}/DJOneHubNotifier" "${app}/Contents/MacOS/DJOneHubNotifier"
cp "${root}/Info.plist" "${app}/Contents/Info.plist"
cp "${root}/Resources/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
chmod 755 "${app}/Contents/MacOS/DJOneHubNotifier"
pocket_dir="${POCKET_TTS_DIR:-${root}/../../.local/pocket-tts}"
if [ -d "${pocket_dir}" ]; then
  mkdir -p "${app}/Contents/Resources/PocketTTS"
  for name in pocket-tts LICENSE english.yaml model.safetensors alba.safetensors tokenizer.json; do
    test -f "${pocket_dir}/${name}"
    cp "${pocket_dir}/${name}" "${app}/Contents/Resources/PocketTTS/${name}"
  done
fi
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
plutil -lint "${app}/Contents/Info.plist"

print -r -- "${app}"
