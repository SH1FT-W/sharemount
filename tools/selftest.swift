// Kleine Selbsttests ohne Xcode: ./build.sh test
import Foundation

@main
struct SelfTest {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what) (Zeile \(line))") }
    }

    @MainActor static func main() {
        print("Adressen")
        var p = Share.parse(address: "smb://alex@192.168.1.10/Media")
        expect(p?.host == "192.168.1.10" && p?.share == "Media" && p?.user == "alex", "smb://user@host/share")
        p = Share.parse(address: "  //nas.local/Fotos/2024 ")
        expect(p?.host == "nas.local" && p?.share == "Fotos" && p?.user == nil, "//host/share/unterordner")
        p = Share.parse(address: "smb://WORKGROUP;Alex:secret@nas/Mein%20Ordner")
        expect(p?.user == "Alex" && p?.share == "Mein Ordner", "Domäne, Passwort und %20")
        p = Share.parse(address: "\\\\nas\\backup")
        expect(p?.host == "nas" && p?.share == "backup", "Windows-Schreibweise")
        p = Share.parse(address: "smb://user@host/a@b")
        expect(p?.user == "user" && p?.host == "host" && p?.share == "a@b", "@ im Freigabenamen")
        p = Share.parse(address: "smb://host:445/share")
        expect(p?.host == "host", "Port fällt weg")
        expect(Share.normalizeHost("My NAS._smb._tcp.local") == "My-NAS.local", "Bonjour-Dienstname → .local")
        expect(Share.normalizeHost("nas.local.") == "nas.local", "Punkt am Ende")
        expect(Share.normalizeHost("fe80::1") == "fe80::1", "IPv6 bleibt")
        expect(Share(host: "NAS.local", share: "x", user: "u").matches(host: "NAS._smb._tcp.local", share: "X"), "Finder-Mount wird erkannt")
        expect(Share.parse(address: "smb://nas") == nil, "ohne Freigabe → nil")
        expect(Share.parse(address: "") == nil, "leer → nil")

        print("Mount-Tabelle")
        let m = Mounter.parse(from: "//Alex@192.168.1.10/My%20Projects", path: "/Volumes/My Projects")
        expect(m?.user == "Alex" && m?.share == "My Projects", "mntfromname mit %20")
        let s = Share(host: "192.168.1.10", share: "Projects", user: "Alex")
        let mounts = [MountInfo(host: "192.168.1.10", share: "projects", user: "Alex", path: "/Volumes/Projects-1"),
                      MountInfo(host: "192.168.1.10", share: "Projects", user: "Alex", path: "/Volumes/Projects")]
        expect(Mounter.find(s, in: mounts)?.path == "/Volumes/Projects", "sauberer Pfad gewinnt")
        expect(Mounter.find(s, in: [mounts[0]])?.path == "/Volumes/Projects-1", "Groß/Klein egal")

        print("Konfiguration")
        let old = #"[{"host":"h","share":"s","user":"u","enabled":false,"id":"80957294-8D27-4619-8EC7-D2C2AE1AA73C"}]"#
        let decoded = try? JSONDecoder().decode([Share].self, from: Data(old.utf8))
        expect(decoded?.first?.enabled == false && decoded?.first?.name == nil, "Datei von 1.x lesbar")
        let minimal = try? JSONDecoder().decode([Share].self, from: Data(#"[{"host":"h","share":"s"}]"#.utf8))
        expect(minimal?.first?.user == NSUserName(), "fehlender Benutzer → Mac-Benutzer")
        var named = Share(host: "h", share: "s", user: "u", name: "NAS")
        let json = String(decoding: try! Store.encode([named]), as: UTF8.self)
        expect(json.contains("\"name\""), "Anzeigename wird gespeichert")
        named.name = "  "
        expect(!String(decoding: try! Store.encode([named]), as: UTF8.self).contains("\"name\""), "leerer Name fällt weg")
        expect(named.displayName == "s", "leerer Name → Freigabename")

        print("Updates")
        expect(Updater.isNewer("2.0", than: "1.7"), "2.0 > 1.7")
        expect(Updater.isNewer("1.10", than: "1.9"), "1.10 > 1.9")
        expect(!Updater.isNewer("1.7", than: "1.7.0"), "1.7 = 1.7.0")
        expect(!Updater.isNewer("1.6.9", than: "1.7"), "1.6.9 < 1.7")
        expect(AppInfo.bundleID == "io.github.sh1ft-w.sharemount", "Updater erwartet die Bundle-ID der App")
        expect(Updater.cleanNotes("## Neu\n- **Fix** `x`\n\n\n\nEnde") == "Neu\n• Fix x\n\nEnde", "Markdown → Text")

        print("Fehlertexte")
        expect(MountError(code: EAUTH).isAuth && MountError(code: EACCES).isAuth, "Auth-Fehler erkannt")
        expect(!MountError(code: ETIMEDOUT).isAuth, "Timeout ist kein Auth-Fehler")
        expect(MountError(code: -128).isCancel, "Abbruch erkannt")
        expect(Engine.duration(30) == "30 s" && Engine.duration(900) == "15 min", "Wartezeit-Text")
        expect(RelTime.short(Date().addingTimeInterval(-7200)) == L("2 Std.", "2 h"), "relative Zeit")
        expect(RelTime.connected(since: Date().addingTimeInterval(-10)) == L("seit gerade eben", "connected just now"), "verbunden seit")

        print("Sprache: \(Lang.isGerman ? "Deutsch" : "Englisch")")

        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }
}
