#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=build/CardValet.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/CardValet "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"; cp CardValet.icns "$APP/Contents/Resources/"
./md2html.py README.md > "$APP/Contents/Resources/help.html"
cp -R docs/screenshots "$APP/Contents/Resources/screenshots"
# ad-hoc sign with a fixed identifier so the Accessibility grant is keyed to com.ronniemoore.cardvalet
codesign --force --sign - --identifier com.ronniemoore.cardvalet "$APP"
echo "built $APP"
