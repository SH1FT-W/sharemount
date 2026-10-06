#!/bin/zsh
# Baut ShareMount.app (Apple Silicon – Intel wird seit macOS 27 nicht mehr unterstützt).
#   ./build.sh           → build/ShareMount.app
#   ./build.sh install   → zusätzlich nach /Applications und neu starten
#   ./build.sh test      → Selbsttests (tools/selftest.swift), baut keine App
#   ./build.sh snapshot  → Beispiel-Screenshots (Demo-Daten, eigenes Test-Home) nach docs/screenshots
#   ./build.sh release 1.3 ["Was ist neu"]
#                        → Version setzen, bauen, committen, taggen, pushen und als GitHub-Release
#                          (ShareMount.zip + .sha256) veröffentlichen – die Apps holen es sich per Update-Button
set -e
cd "$(dirname "$0")"

if [[ "$1" == "release" ]]; then
    VERSION="$2"
    [[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]] || { echo "Aufruf: ./build.sh release 1.3 [\"Was ist neu\"]"; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Erst alles committen – Arbeitsverzeichnis ist nicht sauber."; exit 1; }
    git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "Tag v$VERSION gibt es schon."; exit 1; }
    "$0" test || { echo "Selbsttests fehlgeschlagen – kein Release."; exit 1; }
    BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
fi

# Bevorzugt ein macOS-26-SDK der Command Line Tools (SDK 27 braucht das SwiftUI-Macro-Plugin aus Xcode);
# sonst das Standard-SDK. Eigenes SDK: SDK=/pfad/zum/sdk ./build.sh
if [[ -z "$SDK" ]]; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
    [[ -n "$SDK" ]] || SDK=$(xcrun --sdk macosx --show-sdk-path)
fi

if [[ "$1" == "test" ]]; then
    mkdir -p build
    swiftc -swift-version 5 -parse-as-library -D SNAPSHOT -sdk "$SDK" -target arm64-apple-macos14 \
        Sources/*.swift tools/selftest.swift -o build/selftest
    exec build/selftest
fi

if [[ "$1" == "snapshot" ]]; then
    # Rendert Menü, Update-Fenster und Einstellungen mit Beispiel-Freigaben – in einem leeren Test-Home,
    # damit weder echte Einstellungen noch der Schlüsselbund berührt werden.
    mkdir -p build docs/screenshots
    swiftc -swift-version 5 -parse-as-library -D SNAPSHOT -sdk "$SDK" -target arm64-apple-macos14 \
        Sources/*.swift tools/snapshot.swift -o build/snapshot
    FAKE=$(mktemp -d)
    mkdir -p "$FAKE/Library/Application Support/ShareMount" "$FAKE/Library/Logs" "$FAKE/Library/Mobile Documents/com~apple~CloudDocs"
    echo '[]' > "$FAKE/Library/Application Support/ShareMount/shares.json"
    # Englisch für README/Website; SHAREMOUNT_LANG=de ./build.sh snapshot rendert die deutsche Oberfläche.
    export SHAREMOUNT_LANG="${SHAREMOUNT_LANG:-en}"
    CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" build/snapshot --demo docs/screenshots -AppleLocale "$([[ $SHAREMOUNT_LANG == de* ]] && echo de_DE || echo en_US)"
    rm -rf "$FAKE"
    exit 0
fi
APP=build/ShareMount.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"   # Assets.car = Hell/Dunkel/Klar/Getönt (tools/fetch-icon.sh)
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done   # Texte der Info.plist (de/en)

swiftc -O -swift-version 5 -parse-as-library -sdk "$SDK" \
    -target arm64-apple-macos14 \
    Sources/*.swift -o "$APP/Contents/MacOS/ShareMount"

# Ad-hoc signiert (kein Zertifikat) – nach Updates fragt der Schlüsselbund einmal nach.
codesign --force --sign - "$APP"
echo "Gebaut: $APP ($(lipo -archs "$APP/Contents/MacOS/ShareMount"))"

if [[ "$1" == "install" ]]; then
    pkill -x ShareMount 2>/dev/null || true
    rm -rf ~/Applications/ShareMount.app   # alter Ort bis v1.2
    rm -rf /Applications/ShareMount.app
    cp -R "$APP" /Applications/
    open /Applications/ShareMount.app
    echo "Installiert: /Applications/ShareMount.app"
fi

if [[ "$1" == "release" ]]; then
    OUT=dist/release
    rm -rf "$OUT"; mkdir -p "$OUT"
    ditto -c -k --keepParent "$APP" "$OUT/ShareMount.zip"
    (cd "$OUT" && shasum -a 256 ShareMount.zip > ShareMount.zip.sha256)
    git add Info.plist
    git commit -q -m "v$VERSION"
    git tag "v$VERSION"
    git push -q origin HEAD "v$VERSION"
    NOTES="${3:-}"
    if [[ -n "$NOTES" ]]; then
        gh release create "v$VERSION" "$OUT/ShareMount.zip" "$OUT/ShareMount.zip.sha256" --title "v$VERSION" --notes "$NOTES"
    else
        gh release create "v$VERSION" "$OUT/ShareMount.zip" "$OUT/ShareMount.zip.sha256" --title "v$VERSION" --generate-notes
    fi
    echo "Release v$VERSION veröffentlicht – in den Apps: „Nach Updates suchen“"
fi
