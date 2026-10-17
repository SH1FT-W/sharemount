#!/bin/zsh
# Baut ShareMount.app (Apple Silicon; Intel wird seit macOS 27 nicht mehr unterstützt).
# Die gemeinsamen Schritte liegen in Shared/tools/build-common.sh.
#   ./build.sh           → build/ShareMount.app
#   ./build.sh install   → zusätzlich nach /Applications und neu starten
#   ./build.sh test      → Selbsttests (tools/selftest.swift), baut keine App
#   ./build.sh snapshot  → Beispiel-Screenshots (Demo-Daten, eigenes Test-Home) nach docs/screenshots
#   ./build.sh release next ["Was ist neu"]
#                        → Version setzen, bauen, committen, taggen, pushen und als GitHub-Release
#                          (ShareMount.zip + .sha256) veröffentlichen; die Apps holen es sich per Update-Button
#                        Versionen = Kalender-Versionen YY.M.N (Shared/tools/next-version); jedes Release ist die nächste Nummer im Monat
set -e
cd "$(dirname "$0")"

APP=ShareMount
BUNDLE_ID=io.github.sh1ft-w.sharemount
REPO=SH1FT-W/sharemount
SIGN_KEY=""            # kein Ed25519 (siehe RELEASING.md), Updates sind über Prüfsumme + Code-Signatur geschützt
OUT=dist/release
source Shared/tools/build-common.sh

case "$1" in
    release) release_prepare "$2" ;;
    test) build_test ;;
    snapshot)
        # Rendert Menü, Update-Fenster und Einstellungen mit Beispiel-Freigaben in einem leeren Test-Home,
        # damit weder echte Einstellungen noch der Schlüsselbund berührt werden.
        mkdir -p docs/screenshots
        build_tool snapshot tools/snapshot.swift
        FAKE=$(mktemp -d)
        mkdir -p "$FAKE/Library/Application Support/ShareMount" "$FAKE/Library/Logs" "$FAKE/Library/Mobile Documents/com~apple~CloudDocs"
        echo '[]' > "$FAKE/Library/Application Support/ShareMount/shares.json"
        # Englisch für README/Website; SHAREMOUNT_LANG=de ./build.sh snapshot rendert die deutsche Oberfläche.
        export SHAREMOUNT_LANG="${SHAREMOUNT_LANG:-en}"
        CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" build/snapshot --demo docs/screenshots -AppleLocale "$([[ $SHAREMOUNT_LANG == de* ]] && echo de_DE || echo en_US)"
        rm -rf "$FAKE"
        exit 0 ;;
esac

build_app

if [[ "$1" == "install" ]]; then
    rm -rf ~/Applications/ShareMount.app   # alter Ort bis v1.2
    install_app
fi
[[ "$1" == "release" ]] && release_publish "$3"
exit 0
