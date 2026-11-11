# ShareMount – Projektregeln

Mac-Menüleisten-App (SwiftUI, Apple Silicon), hält SMB-Freigaben verbunden. Repo SH1FT-W/sharemount, Projektseite
https://sh1ft-w.github.io/sharemount/. Allgemeine Regeln (Versionen, Release-Ablauf, Labels, Fehler beheben):
`~/.claude/CLAUDE.md`, hier nur das Repo-Eigene.

- Repo ist **öffentlich**: nichts Persönliches in Code, Commits, Bilder (keine Namen, lokalen Pfade, Server-, Freigabe-
  oder Hostnamen, IPs). Vor jedem Release scannen (`git ls-files | grep …`, `strings` auf Bilder).
- README, CHANGELOG, RELEASING.md, Release-Notizen und Commit-Texte auf Englisch. Oberfläche zweisprachig über
  `L("de","en")` (`SHAREMOUNT_LANG`); Code-Kommentare englisch (bestehende deutsche nur bei Änderungen an der Datei
  mit übersetzen).
- **Screenshots nur mit Demo-Daten:** `./build.sh snapshot` rendert mit Beispiel-Freigaben in einem leeren Test-Home
  nach `docs/screenshots` (englisch; `SHAREMOUNT_LANG=de` für deutsch). Nie Bilder mit echten Freigaben.
- Lokal committen ok; installieren, pushen und releasen nur nach Rückfrage.
- Passwörter liest die App nicht selbst: NetFS mit `password=nil`, macOS-NetAuth nimmt das Internet-Passwort aus dem
  Schlüsselbund. So bleibt es (keine eigenen Passwörter, keine Schlüsselbund-Nachfragen nach Updates).
- Gemeinsamer Code (Updater, Menü-Bausteine, Sprache, Bau-Werkzeuge) liegt in `Shared/` als subtree von
  SH1FT-W/swift-shared: dort ändern (`tools/check.sh`), dann `git subtree pull` (siehe RELEASING.md), nie direkt in
  `Shared/` oder als Kopie in `Sources/`.

## Bauen und prüfen
- Ohne Xcode: swiftc gegen das macOS-26.5-SDK der Command Line Tools (SDK 27 scheitert am SwiftUI-Macro-Plugin),
  nur arm64, ad-hoc signiert.
- `./build.sh` → `build/ShareMount.app`, `./build.sh install` → nach `/Applications` und neu starten.
- `./build.sh test` = Selbsttests (`tools/selftest.swift`), läuft auch in `.github/workflows/build.yml`.
- Die Claude-Sandbox darf iCloud Drive nicht lesen: Tests und Fehlerzustände mit Fake-Home
  (`CFFIXED_USER_HOME=<scratch>` + eigene `shares.json`). Log der App: `~/Library/Logs/ShareMount.log`.

## Release
- `./build.sh release next "What's new"` (RELEASING.md): Bau, Selbsttests, Commit, Tag, Push, GitHub-Release mit
  `ShareMount.zip` + `.sha256` + `.sig`. Fixes vorher committen. Tags ohne „v“ seit 26.11.1 (ältere `v`-Tags zählen mit).
- Ed25519-Schlüssel nur lokal in `~/Library/Application Support/ShareMount Release/`, nie ins Repo.
- CHANGELOG: `## Unreleased` zur Versionsnummer, README-Zeile „New in …“ und Screenshots prüfen, Datenschutz-Scan.

## Pflege
- Monatliche Fix-Runde mit dem HA-Beta-Check: Worktree `sharemount-fixrunde`, Zweig `fixrunde-YYYY-MM`. Ablauf: Log
  auf wiederholte/unerwartete Einträge lesen, installierte Version prüfen, Sources sichten, kleine sichere Fixes +
  `./build.sh test` + Bau, lokal committen, Release erst nach OK.
