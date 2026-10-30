#!/bin/zsh
set -eu
SOURCE_DIR="${0:A:h}"
DELIVERY_DIR="${SIDECAR_BUILD_DIR:-${SOURCE_DIR}/build}"
ICON_ASSETS="${DELIVERY_DIR}/icon-assets"
CACHE_DIR="${TMPDIR:-/tmp}/sidecar-keys-swift-cache"
APP_DIR="${DELIVERY_DIR}/Sidecar On-Screen Keyboard.app"
BUNDLE_ID="${SIDECAR_BUNDLE_ID:-local.danielhanna.SidecarKeys}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${CACHE_DIR}" "${ICON_ASSETS}"
swiftc -swift-version 5 -O -module-cache-path "${CACHE_DIR}" -framework AppKit "${SOURCE_DIR}/src/AppBrand.swift" "${SOURCE_DIR}/tools/main.swift" -o "${CACHE_DIR}/sidecar-icon-renderer"
"${CACHE_DIR}/sidecar-icon-renderer" "${ICON_ASSETS}"
iconutil -c icns "${ICON_ASSETS}/AppIcon.iconset" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp "${ICON_ASSETS}/AppIcon-preview.png" "${DELIVERY_DIR}/AppIcon-preview.png"
cp "${ICON_ASSETS}/AppIcon-1024.png" "${DELIVERY_DIR}/AppIcon-1024.png"
cp "${SOURCE_DIR}/assets/AppIcon.svg" "${DELIVERY_DIR}/AppIcon.svg"
swiftc -swift-version 5 -O -module-cache-path "${CACHE_DIR}" -target arm64-apple-macos27.0 -framework AppKit -framework ApplicationServices -framework PencilKit -framework Vision "${SOURCE_DIR}"/src/*.swift -o "${APP_DIR}/Contents/MacOS/SidecarKeys"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SidecarKeys</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>Sidecar On-Screen Keyboard</string>
<key>CFBundleDisplayName</key><string>Sidecar On-Screen Keyboard</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>22</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
SIGN_IDENTITY="${SIDECAR_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}")
if [[ "${SIDECAR_HARDENED_RUNTIME:-0}" == "1" ]]; then
    SIGN_OPTIONS+=(--options runtime)
fi
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    SIGN_OPTIONS+=(--timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "${APP_DIR}"
print -r -- "Built ${APP_DIR}"
