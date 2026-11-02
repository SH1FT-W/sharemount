// Kleine Selbsttests ohne Xcode: ./build.sh test
import CryptoKit
import Foundation

@main
struct SelfTest {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what) (Zeile \(line))") }
    }

    /// Builds a neighbour table like sysctl NET_RT_FLAGS/RTF_LLINFO returns it (nil MAC = incomplete entry).
    static func neighbourTable(_ entries: [(ip: String, mac: [UInt8]?)]) -> [UInt8] {
        var out: [UInt8] = []
        for e in entries {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            _ = inet_pton(AF_INET, e.ip, &sin.sin_addr)
            var dl = sockaddr_dl()
            dl.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
            dl.sdl_family = sa_family_t(AF_LINK)
            dl.sdl_nlen = 3                                         // "en0"
            dl.sdl_alen = e.mac == nil ? 0 : 6
            var dlBytes = withUnsafeBytes(of: &dl) { Array($0) }
            for (i, c) in "en0".utf8.enumerated() { dlBytes[8 + i] = c }
            for (i, b) in (e.mac ?? []).enumerated() { dlBytes[11 + i] = b }
            let sinBytes = withUnsafeBytes(of: &sin) { Array($0) }
            var rtm = rt_msghdr()
            rtm.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + sinBytes.count + dlBytes.count)
            rtm.rtm_addrs = RTA_DST | RTA_GATEWAY
            rtm.rtm_flags = RTF_LLINFO
            out += withUnsafeBytes(of: &rtm) { Array($0) } + sinBytes + dlBytes
        }
        return out
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
        expect(Share.normalizeHost("[fe80::1]") == "fe80::1", "IPv6 ohne Klammern")
        expect(Share.normalizeHost("[fe80::1]:445") == "fe80::1", "IPv6 mit Port")
        expect(Share(host: "fe80::1", share: "x", user: "u").url?.absoluteString == "smb://[fe80::1]/x", "IPv6-URL in Klammern")
        expect(Share(host: "[fe80::1]", share: "x", user: "u").url?.absoluteString == "smb://[fe80::1]/x", "IPv6-URL mit Klammern")
        expect(Share(host: "nas.local", share: "x", user: "u").url?.absoluteString == "smb://nas.local/x", "Hostname-URL")
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
        expect(Mounter.current().allSatisfy { $0.owner == getuid() }, "nur eigene Mounts (Benutzerwechsel)")
        expect(getuid() == 0 || Mounter.isForeignMountPoint("/"), "fremder Einhängepunkt erkannt (/ gehört root)")
        expect(!Mounter.isForeignMountPoint("/gibt/es/nicht"), "kein Einhängepunkt → nicht fremd")

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

        print("Netz-Regeln")
        expect(NetworkIdentity.normalizeMAC("2:0:5e:10:0:1") == "02:00:5e:10:00:01", "MAC mit einstelligen Teilen → zweistellig")
        expect(NetworkIdentity.normalizeMAC("02-00-5E-10-00-01") == "02:00:5e:10:00:01", "MAC mit Bindestrichen, groß")
        expect(NetworkIdentity.normalizeMAC("0200.5e10.0001") == "02:00:5e:10:00:01", "MAC in Cisco-Schreibweise")
        expect(NetworkIdentity.normalizeMAC(" 02005E100001 ") == "02:00:5e:10:00:01", "MAC ohne Trenner")
        expect(NetworkIdentity.normalizeMAC("02:00:5e:10:00") == nil, "MAC zu kurz → nil")
        expect(NetworkIdentity.normalizeMAC("02:00:5e:10:00:0g") == nil, "kein Hex → nil")
        expect(NetworkIdentity.normalizeMAC("ff:ff:ff:ff:ff:ff") == nil && NetworkIdentity.normalizeMAC("0:0:0:0:0:0") == nil, "Broadcast/Null → nil")
        let table = neighbourTable([("192.168.1.1", [0x02, 0x00, 0x5e, 0x10, 0x00, 0x01]), ("192.168.1.20", nil), ("10.0.0.1", [0, 0x11, 0x32, 0xaa, 0xbb, 0xcc])])
        let parsed = NetworkIdentity.parseNeighbours(table)
        expect(parsed["192.168.1.1"] == "02:00:5e:10:00:01", "Nachbartabelle → Router-MAC")
        expect(parsed["10.0.0.1"] == "00:11:32:aa:bb:cc", "mehrere Einträge")
        expect(parsed["192.168.1.20"] == nil, "Eintrag ohne MAC (unvollständig) → fehlt")
        expect(NetworkIdentity.parseNeighbours(Array(table.prefix(40))).isEmpty && NetworkIdentity.parseNeighbours([]).isEmpty, "abgeschnittene/leere Tabelle → nichts, kein Absturz")
        expect(NetworkIdentity.isIPv4("192.168.1.1") && !NetworkIdentity.isIPv4("fe80::1") && !NetworkIdentity.isIPv4("nas.local"), "nur IPv4-Gateways")
        let home = KnownNetwork(name: "Heimnetz", router: "02-00-5E-10-00-01")
        expect(home.router == "02:00:5e:10:00:01", "Netz speichert normalisierte Router-MAC")
        expect(NetworkIdentity.allows([], current: nil), "keine Netze → überall (auch ohne Router)")
        expect(NetworkIdentity.allows([home], current: ["02:00:5e:10:00:01"]), "im Heimnetz → verbinden")
        expect(!NetworkIdentity.allows([home], current: ["aa:bb:cc:dd:ee:ff"]), "anderer Router → unterwegs")
        expect(!NetworkIdentity.allows([home], current: nil) && !NetworkIdentity.allows([home], current: []), "Router unbekannt → unterwegs")
        expect(NetworkIdentity.allows([KnownNetwork(name: "Büro", router: "11:22:33:44:55:66"), home], current: ["aa:bb:cc:dd:ee:ff", "02:00:5e:10:00:01"]),
               "eines von mehreren Netzen, mehrere Gateways")
        var roaming = Share(host: "nas.local", share: "Media", user: "u")
        roaming.networks = [home]
        roaming.wakeMAC = "00:11:32:aa:bb:cc"
        let roamJSON = try! Store.encode([roaming])
        let back = try? JSONDecoder().decode([Share].self, from: roamJSON)
        expect(back?.first?.networks == [home] && back?.first?.wakeMAC == "00:11:32:aa:bb:cc", "Netze und WoL-MAC in shares.json")
        let plain = String(decoding: try! Store.encode([Share(host: "h", share: "s", user: "u")]), as: UTF8.self)
        expect(!plain.contains("networks") && !plain.contains("wakeMAC"), "ohne Netze/WoL bleibt shares.json wie bisher")
        let broken = try? JSONDecoder().decode([Share].self, from: Data(#"[{"host":"h","share":"s","networks":"kaputt"}]"#.utf8))
        expect(broken?.first?.networks == [], "kaputte Netz-Liste → überall statt Datei unlesbar")
        let lossy = try? JSONDecoder().decode([Share].self, from: Data(#"[{"host":"h","share":"s","networks":[{"name":"A","router":"02-00-5E-10-00-01"},{"router":"kaputt"},"Müll",{"name":"Doppelt","router":"02:00:5e:10:00:01"},{"name":"B","router":"02:00:5e:10:00:02"}]}]"#.utf8))
        expect(lossy?.first?.networks.map(\.router) == ["02:00:5e:10:00:01", "02:00:5e:10:00:02"],
               "von Hand bearbeitet: MAC normalisiert, kaputte Einträge und Doppelte fallen weg, Rest bleibt")
        var shortDL = neighbourTable([("192.168.1.1", [0x02, 0x00, 0x5e, 0x10, 0x00, 0x01])])
        shortDL.removeLast(6)                                   // sockaddr_dl ends before the MAC
        expect(NetworkIdentity.parseNeighbours(shortDL).isEmpty, "zu kurze Link-Adresse → nichts, kein Lesen über das Ende")
        let net = KnownNetwork(name: "Heimnetz", router: "02:00:5e:10:00:01")
        expect(Engine.mayWake(networks: [net], current: ["02:00:5e:10:00:01"]), "WoL im eigenen Netz")
        expect(!Engine.mayWake(networks: [net], current: ["aa:bb:cc:dd:ee:01"]), "WoL nicht unterwegs (Netz-Regel)")
        expect(!Engine.mayWake(networks: [net], current: nil) && !Engine.mayWake(networks: [net], current: []), "WoL nicht ohne erkannten Router (VPN, offline)")
        expect(!Engine.mayWake(networks: [], current: ["02:00:5e:10:00:01"]), "WoL ohne Netz-Regel nie, auch nicht im Heimnetz")
        expect(!Engine.mayWake(networks: [], current: nil), "WoL ohne Netz-Regel und ohne Router nie")
        expect(ShareStatus.away.text == L("Unterwegs, pausiert", "Away, paused") && !ShareStatus.away.isProblem, "unterwegs ist kein Fehler")

        print("Wake on LAN")
        let magic = WakeOnLAN.packet(mac: "00-11-32-AA-BB-CC")
        expect(magic?.count == 102, "Magic Packet: 102 Bytes")
        expect(magic.map { Array($0.prefix(6)) == [UInt8](repeating: 0xFF, count: 6) } == true, "beginnt mit 6 × FF")
        let macBytes: [UInt8] = [0x00, 0x11, 0x32, 0xAA, 0xBB, 0xCC]
        expect(magic.map { d in (0..<16).allSatisfy { Array(d[(6 + $0 * 6)..<(12 + $0 * 6)]) == macBytes } } == true, "dann 16 × die MAC")
        expect(WakeOnLAN.packet(mac: "nas.local") == nil && WakeOnLAN.packet(mac: "") == nil, "ungültige MAC → kein Paket")
        let engineShares = [Share(host: "NAS.local", share: "a", user: "u"), { var x = Share(host: "nas.local.", share: "b", user: "u"); x.wakeMAC = "001132aabbcc"; return x }()]
        expect(Engine.wakeMAC(for: "nas.local", in: engineShares) == "00:11:32:aa:bb:cc", "WoL-MAC gilt für den ganzen Server")
        expect(Engine.wakeMAC(for: "other.local", in: engineShares) == nil, "anderer Server → keine MAC")
        // Saving one share: the MAC spreads only on a deliberate change, an empty field never wipes the others.
        var a = Share(host: "nas.local", share: "a", user: "u"); a.wakeMAC = "00:11:32:aa:bb:cc"
        var b = Share(host: "NAS.local", share: "b", user: "u"); b.wakeMAC = "00:11:32:aa:bb:cc"
        let other = Share(host: "pi.local", share: "c", user: "u")
        let fresh = Share(host: "nas.local", share: "new", user: "u")
        var synced = Engine.syncWakeMAC([a, b, other, fresh], edited: fresh.id, previous: nil)
        expect(synced[0].wakeMAC == "00:11:32:aa:bb:cc" && synced[3].wakeMAC == "00:11:32:aa:bb:cc", "neue Freigabe ohne MAC übernimmt die des Servers, löscht nichts")
        a.wakeMAC = "00-11-32-AA-BB-DD"
        synced = Engine.syncWakeMAC([a, b, other], edited: a.id, previous: "00:11:32:aa:bb:cc")
        expect(synced[0].wakeMAC == "00:11:32:aa:bb:dd" && synced[1].wakeMAC == "00:11:32:aa:bb:dd" && synced[2].wakeMAC == nil, "geänderte MAC gilt für den Server, nicht für andere")
        a.wakeMAC = ""
        synced = Engine.syncWakeMAC([a, b, other], edited: a.id, previous: "00:11:32:aa:bb:cc")
        expect(synced[0].wakeMAC == nil && synced[1].wakeMAC == nil, "bewusst geleert → für den Server aus")
        // Editor showed b's MAC as pre-fill for c (c had none stored), user cleared it: counts as a change.
        var c = Share(host: "nas.local", share: "c", user: "u")
        b.wakeMAC = "00:11:32:aa:bb:cc"
        expect(ShareEditor.prefilledWakeMAC(c, others: [b]) == "00:11:32:aa:bb:cc", "Editor zeigt die MAC des Servers")
        c.wakeMAC = ""
        synced = Engine.syncWakeMAC([b, c], edited: c.id, previous: .some("00:11:32:aa:bb:cc"))
        expect(synced[0].wakeMAC == nil && synced[1].wakeMAC == nil, "vorbefüllte MAC geleert → bleibt geleert")

        print("Updates")
        expect(UpdateCore.isNewer("2.0", than: "1.7"), "2.0 > 1.7")
        expect(UpdateCore.isNewer("1.10", than: "1.9"), "1.10 > 1.9")
        expect(!UpdateCore.isNewer("1.7", than: "1.7.0"), "1.7 = 1.7.0")
        expect(!UpdateCore.isNewer("1.6.9", than: "1.7"), "1.6.9 < 1.7")
        expect(UpdateCore.isNewer("26.10.4", than: "2.5"), "Kalender-Version 26.10.4 > 2.5")
        expect(UpdateCore.isNewer("26.10.10", than: "26.10.9"), "26.10.10 > 26.10.9")
        expect(!UpdateCore.isNewer("26.10.9", than: "26.10.10"), "26.10.9 < 26.10.10")
        expect(UpdateCore.isNewer("26.10.1", than: "26.9.12"), "26.10.1 > 26.9.12")
        expect(UpdateCore.isNewer("27.1.1", than: "26.12.30"), "27.1.1 > 26.12.30")
        // Tags are the bare version since 26.11; older releases carry "v". Both must be read the same way.
        expect((try? GitHubRelease(json: ["tag_name": "26.11.1"]))?.version == "26.11.1", "Tag ohne v → 26.11.1")
        expect((try? GitHubRelease(json: ["tag_name": "v26.10.14"]))?.version == "26.10.14", "alter Tag mit v → 26.10.14")
        expect((try? GitHubRelease(json: ["tag_name": "26.11.1"])).map { UpdateCore.isNewer($0.version, than: "26.10.14") } == true,
               "Tag ohne v ist neuer als installierte 26.10.14")
        expect(AppInfo.bundleID == "io.github.sh1ft-w.sharemount", "Updater erwartet die Bundle-ID der App")
        expect(ReleaseNotes.cleanNotes("## Neu\n- **Fix** `x`\n\n\n\nEnde") == "Neu\n• Fix x\n\nEnde", "Markdown → Text")
        expect(ReleaseNotes.cleanNotes("* a\n  * b  ") == "• a\n• b", "Sternchen-Listen, eingerückt")
        expect(ReleaseNotes.cleanNotes("\n\n# Titel\n\n") == "Titel", "Leerzeilen am Rand fallen weg")
        expect(ReleaseNotes.cleanNotes("") == "", "leer bleibt leer")

        print("Update-Signatur (Ed25519)")
        let testKey = Curve25519.Signing.PrivateKey()
        let testPublic = testKey.publicKey.rawRepresentation.base64EncodedString()
        let zipData = Data("ShareMount.zip".utf8)
        let sum = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined() + "  ShareMount.zip\n"
        let goodSig = try! testKey.signature(for: zipData).base64EncodedString()
        func accepted(_ data: Data, _ sig: String, key: String) -> Bool {
            (try? Updater.verify(zip: data, checksumText: sum, signatureText: sig, publicKey: key)) != nil
        }
        expect(accepted(zipData, goodSig + "\n", key: testPublic), "gültige Signatur → angenommen")
        let otherSig = try! Curve25519.Signing.PrivateKey().signature(for: zipData).base64EncodedString()
        expect(!accepted(zipData, otherSig, key: testPublic), "Signatur eines fremden Schlüssels → verworfen")
        expect(!accepted(zipData, goodSig, key: Updater.publicKey), "Signatur passt nicht zum App-Schlüssel → verworfen")
        expect((try? Updater.verify(zip: zipData, checksumText: sum, signatureText: goodSig)) == nil,
               "Standardaufruf wie in install() prüft gegen Updater.publicKey → fremde Signatur verworfen")
        expect(!accepted(zipData, "", key: testPublic), "fehlende (leere) Signatur → verworfen")
        expect(!accepted(zipData, "kein base64", key: testPublic), "kaputte Signatur → verworfen")
        let otherZip = Data("ShareMount.zip, ausgetauscht".utf8)
        let otherZipSig = try! testKey.signature(for: otherZip).base64EncodedString()
        expect(!accepted(otherZip, otherZipSig, key: testPublic), "Prüfsumme passt nicht → verworfen, trotz Signatur")
        expect(Data(base64Encoded: Updater.publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil,
               "Updater.publicKey ist ein gültiger Ed25519-Schlüssel")
        func release(_ names: [String]) -> GitHubRelease {
            try! GitHubRelease(json: ["tag_name": "v26.11.1", "assets": names.map {
                ["name": $0, "url": "https://api.github.com/repos/SH1FT-W/sharemount/releases/assets/\($0.count)"] }])
        }
        expect((try? Updater.assets(of: release(["ShareMount.zip", "ShareMount.zip.sha256", "ShareMount.zip.sig"]))) != nil,
               "Release mit .zip/.sha256/.sig → wird angeboten")
        expect((try? Updater.assets(of: release(["ShareMount.zip", "ShareMount.zip.sha256"]))) == nil,
               "Release ohne .sig (unsigniert) → nicht angeboten")

        print("Verbindungslogik")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        expect(!Engine.shouldUnmount(strikes: 1, since: t0, now: t0, cacheOnly: false), "1. Fehlschlag: noch nicht lösen")
        expect(!Engine.shouldUnmount(strikes: 2, since: t0, now: t0.addingTimeInterval(10), cacheOnly: false), "2 Fehlschläge in 10 s: zu kurz")
        expect(Engine.shouldUnmount(strikes: 2, since: t0, now: t0.addingTimeInterval(20), cacheOnly: false), "2 Fehlschläge über 20 s: lösen")
        expect(!Engine.shouldUnmount(strikes: 2, since: t0, now: t0.addingTimeInterval(120), cacheOnly: true), "Server stumm, Mount liest: 2 reichen nicht")
        expect(!Engine.shouldUnmount(strikes: 3, since: t0, now: t0.addingTimeInterval(60), cacheOnly: true), "3 Fehlschläge in 60 s: zu kurz")
        expect(Engine.shouldUnmount(strikes: 3, since: t0, now: t0.addingTimeInterval(90), cacheOnly: true), "3 Fehlschläge über 90 s: lösen")
        expect(Engine.nextRetryDelay(after: nil) == 30, "erste Wartezeit 30 s")
        expect(Engine.nextRetryDelay(after: 30) == 60 && Engine.nextRetryDelay(after: 60) == 120, "verdoppelt sich")
        expect(Engine.nextRetryDelay(after: 480) == 900 && Engine.nextRetryDelay(after: 900) == 900, "höchstens 15 min")
        var v = Engine.pathVerdict(path: "/Volumes/Daten", clean: "/Volumes/Daten", cleanExists: true, cleanIsMountPoint: true, cleanIsForeign: false)
        expect(v.misplaced == nil && !v.blocked, "sauberer Pfad: kein Hinweis")
        v = Engine.pathVerdict(path: "/Volumes/Daten-1", clean: "/Volumes/Daten", cleanExists: false, cleanIsMountPoint: false, cleanIsForeign: false)
        expect(v.misplaced == "/Volumes/Daten-1" && !v.blocked, "Name-1, Name frei: Pfad korrigieren")
        v = Engine.pathVerdict(path: "/Volumes/Daten-1", clean: "/Volumes/Daten", cleanExists: true, cleanIsMountPoint: false, cleanIsForeign: false)
        expect(v.misplaced == nil && v.blocked, "Name-1, verwaister Ordner unter Name: blockiert")
        v = Engine.pathVerdict(path: "/Volumes/Daten-1", clean: "/Volumes/Daten", cleanExists: true, cleanIsMountPoint: true, cleanIsForeign: true)
        expect(v.misplaced == nil && !v.blocked, "Name-1, Name gehört anderem Benutzer: richtig so")
        v = Engine.pathVerdict(path: "/Volumes/Daten-1", clean: "/Volumes/Daten", cleanExists: true, cleanIsMountPoint: true, cleanIsForeign: false)
        expect(v.misplaced == nil && !v.blocked, "Name-1, Name ist eigener Mount: kein Hinweis")

        print("Protokoll")
        expect(LogTab.isProblem("2026-10-17 12:00:00  [!] NAS: Lösen fehlgeschlagen"), "Kennzeichen erkannt")
        expect(!LogTab.isProblem("2026-10-17 12:00:00  NAS: verbunden → /Volumes/NAS"), "normale Zeile")
        expect(LogTab.isProblem("2026-10-17 12:00:00  NAS: Server nicht erreichbar"), "alte Zeile ohne Kennzeichen über Wortliste")
        expect(LogTab.isProblem("2026-10-17 12:00:00  NAS: mount failed"), "alte englische Zeile über Wortliste")

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
