#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData-Custom"
identity="TypeWhisper Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"
target="/Applications/TypeWhisper.app"

if ! security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
  echo "Creating local TypeWhisper signing identity..." >&2
  temporary="$(mktemp -d)"
  trap 'rm -rf "$temporary"' EXIT
  openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$temporary/key.pem" -out "$temporary/cert.pem" \
    -subj "/CN=$identity" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$temporary/key.pem" -in "$temporary/cert.pem" \
    -out "$temporary/id.p12" -name "$identity" -passout pass:twtemp \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
  security import "$temporary/id.p12" -k "$keychain" -P twtemp \
    -A -T /usr/bin/codesign >/dev/null
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-16.2.app/Contents/Developer}" \
  xcodebuild build \
    -project "$repo_root/TypeWhisper.xcodeproj" \
    -scheme TypeWhisper \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_IDENTITY='-' \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION=1.5.1 \
    CURRENT_PROJECT_VERSION=928 \
    APP_GROUP_ID=2D8ALY3LCL.com.typewhisper.mac

app="$derived_data/Build/Products/Release/TypeWhisper.app"
if [[ ! -d "$app" ]]; then
  echo "error: built TypeWhisper.app was not found" >&2
  exit 1
fi

# A custom build must not replace itself with an official Sparkle update.
/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :NSDocumentsFolderUsageDescription' "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSDocumentsFolderUsageDescription string TypeWhisper accesses recordings saved in your Documents folder.' "$app/Contents/Info.plist"
printf 'source=%s\nbranch=%s\ncommit=%s\n' \
  "$repo_root" \
  "$(git -C "$repo_root" branch --show-current)" \
  "$(git -C "$repo_root" rev-parse --short HEAD)" \
  > "$app/Contents/Resources/CustomBuildSource.txt"

entitlements="$(mktemp)"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

xattr -cr "$app"
codesign --force --deep --options runtime --sign "$identity" "$app"
codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

osascript -e 'tell application id "com.typewhisper.mac" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -x TypeWhisper >/dev/null || break
  sleep 0.25
done
if pgrep -x TypeWhisper >/dev/null; then
  echo "error: TypeWhisper did not quit" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/TypeWhisper.app"
rm -rf "$target"
ditto "$stage/TypeWhisper.app" "$target"
open "$target"
echo "Installed optimized custom build: $target"
