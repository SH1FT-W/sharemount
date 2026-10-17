# Releasing

`./build.sh release next "What's new"` sets the version, builds, runs the self tests, commits, tags, pushes and publishes `ShareMount.zip` plus `ShareMount.zip.sha256` as a GitHub release. Installed apps pick it up through their update check.

Versions are calendar versions `YY.M.N`: two-digit year, month without a leading zero, and the running number of the release within that month, starting at 1 (every GitHub release published that month counts, including older `X.Y.Z` ones; bare tags without a release do not). A new month starts again at `.1`. `tools/next-version` computes the next one (tag `vYY.M.N`); `next` uses it, and any other version is refused unless `ALLOW_VERSION=1` is set. Version checks compare the numbers part by part, so `26.10.10` is newer than `26.10.9` and any calendar version is newer than `2.x`.

## Checks

`./build.sh test` runs the self tests (`tools/selftest.swift`); the release script runs them as well and refuses to release when they fail. The Build workflow (`.github/workflows/build.yml`) builds the app and runs the same tests on every push to `main` and on pull requests.

## Open: Ed25519 like AgentBar

Updates are currently protected by the SHA-256 checksum, the bundle ID, the version number and a valid ad hoc code signature. AgentBar additionally signs every `AgentBar.zip` with an Ed25519 key, so even a foreign release in the repo cannot be installed. Porting that needs a key from the maintainer, so it is not done yet. The steps:

1. Copy `tools/release-key.swift` from AgentBar. `release-key generate` creates the key pair and stores the private half in the local keychain only; `release-key public` prints the public half.
2. Put the public key into `Sources/Updater.swift` as `static let publicKey = "..."` and require the `ShareMount.zip.sig` asset in `check()`, next to the checksum.
3. In `install()`, verify the signature with `Curve25519.Signing.PublicKey(rawRepresentation:)` and `isValidSignature(_:for:)` over the downloaded zip before unpacking (see AgentBar `Updater.install`).
4. In `build.sh release`, compile `tools/release-key.swift`, compare `release-key public` with `Updater.publicKey` and abort on mismatch, sign the zip (`release-key sign ShareMount.zip > ShareMount.zip.sig`) and upload the `.sig` with the release.
5. Ship the public key in a release that still accepts unsigned releases, then require the signature from the next release on, so installed apps can still reach the first signed version.
