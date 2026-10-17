# Releasing

`./build.sh release next "What's new"` sets the version, builds, runs the self tests, commits, tags, pushes and publishes `ShareMount.zip` plus `ShareMount.zip.sha256` as a GitHub release. Installed apps pick it up through their update check.

Versions are calendar versions `YY.M.N`: two-digit year, month without a leading zero, and the running number of the release within that month, starting at 1 (every GitHub release published that month counts, including older `X.Y.Z` ones; bare tags without a release do not). A new month starts again at `.1`. `Shared/tools/next-version` computes the next one (tag `vYY.M.N`); `next` uses it, and any other version is refused unless `ALLOW_VERSION=1` is set. Version checks compare the numbers part by part, so `26.10.10` is newer than `26.10.9` and any calendar version is newer than `2.x`.

## Checks

`./build.sh test` runs the self tests (`tools/selftest.swift`); the release script runs them as well and refuses to release when they fail. The Build workflow (`.github/workflows/build.yml`) builds the app and runs the same tests on every push to `main` and on pull requests.

## Shared code

`Shared/` is a git subtree of the private repository `SH1FT-W/swift-shared`: language helper, menu components, the updater core, the update window kit and the build tooling that ShareMount and AgentBar have in common. `build.sh` compiles `Shared/Sources/*.swift` together with `Sources/*.swift` and sources `Shared/tools/build-common.sh`. Pulling and pushing need a GitHub account with access to that repository (`gh auth status`).

```sh
# take the latest shared code
git subtree pull --prefix=Shared https://github.com/SH1FT-W/swift-shared.git main --squash
# give a change made in Shared/ back to the shared repository
git subtree push --prefix=Shared https://github.com/SH1FT-W/swift-shared.git main
```

Both need a clean working tree. After a pull, build, run the tests and compare the snapshots (`./build.sh snapshot`) before releasing: shared changes must not alter ShareMount's behaviour or look unless intended. The look of the shared menu components is pinned in `MenuView.swift` with `.menuLook(...)`.

## Open: Ed25519 like AgentBar

Updates are currently protected by the SHA-256 checksum, the bundle ID, the version number and a valid ad hoc code signature. AgentBar additionally signs every `AgentBar.zip` with an Ed25519 key, so even a foreign release in the repo cannot be installed. The verification itself is already shared (`UpdateCore.verifyEd25519`); porting needs a key from the maintainer, so it is not done yet. The steps:

1. `build/release-key ShareMount generate` (compiled from `Shared/tools/release-key.swift`) creates the key pair and stores the private half in `~/Library/Application Support/ShareMount Release/` only; `release-key ShareMount public` prints the public half.
2. Put the public key into `Sources/Updater.swift` as `static let publicKey = "..."`, require the `ShareMount.zip.sig` asset in `check()` next to the checksum, and call `UpdateCore.verifyEd25519(zipData, signatureText:, publicKey:)` in `install()` after the checksum.
3. In `build.sh`, set `SIGN_KEY` from `Updater.publicKey` (like AgentBar's `build.sh`); `release_publish` then signs the zip and uploads the `.sig`.
4. Ship the public key in a release that still accepts unsigned releases, then require the signature from the next release on, so installed apps can still reach the first signed version.
