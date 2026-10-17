import Foundation

/// Was der gemeinsame Code (Shared/Sources) über diese App wissen muss.
enum AppConfig: SharedAppConfig {
    /// Sprache zum Testen und für Screenshots überschreiben: `SHAREMOUNT_LANG=de|en`.
    static let langEnvVar = "SHAREMOUNT_LANG"
}
