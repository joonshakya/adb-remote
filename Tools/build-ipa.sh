#!/bin/zsh
# Bumps the app version, builds a Release IPA (ad-hoc signed, for sideloading) and
# writes dist/AdbRemote-<version>.ipa plus a .zip of it.
#   Tools/build-ipa.sh          0.2 -> 0.3
#   Tools/build-ipa.sh 1.0      sets the version to 1.0
set -euo pipefail

ROOT=${0:A:h:h}
APP=$ROOT/App
DIST=$ROOT/dist

current=$(grep -m1 'MARKETING_VERSION:' $APP/project.yml | sed -E 's/.*"(.*)".*/\1/')
build=$(grep -m1 'CURRENT_PROJECT_VERSION:' $APP/project.yml | sed -E 's/.*"(.*)".*/\1/')
if [[ $# -ge 1 ]]; then
  version=$1
else
  major=${current%%.*}
  minor=${current#*.}
  minor=${minor%%.*}
  version="$major.$((minor + 1))"
fi
build=$((build + 1))

# App and share extension must carry the same version.
sed -i '' -E "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$version\"/; s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$build\"/" $APP/project.yml
(cd $APP && xcodegen generate --quiet)
echo "Building $version ($build)"

cd $APP
xcodebuild -project AdbRemote.xcodeproj -scheme AdbRemote -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build-device CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

W=$(mktemp -d)
mkdir $W/Payload
cp -R build-device/Build/Products/Release-iphoneos/AdbRemote.app $W/Payload/
A=$W/Payload/AdbRemote.app
for d in $A/Frameworks/*.dylib(N); do codesign -f -s - $d 2>/dev/null; done
codesign -f -s - --entitlements $APP/ShareExtension/SendToTV.entitlements $A/PlugIns/SendToTV.appex 2>/dev/null
codesign -f -s - --entitlements $APP/Sources/AdbRemote.entitlements $A 2>/dev/null
codesign --verify --deep $A

mkdir -p $DIST
name=AdbRemote-$version
rm -f $DIST/$name.ipa $DIST/$name-ipa.zip
(cd $W && zip -qry $DIST/$name.ipa Payload)
(cd $DIST && zip -q $name-ipa.zip $name.ipa)
rm -rf $W
ls -la $DIST/$name.ipa $DIST/$name-ipa.zip
