# Releasing

`./build.sh release next "What's new"` sets the version, builds, runs the self tests, commits, tags, pushes and publishes `ShareMount.zip`, `ShareMount.zip.sha256` and `ShareMount.zip.sig` as a GitHub release. Installed apps pick it up through their update check.

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

## Signing

The update button installs a release only if its Ed25519 signature matches `Updater.publicKey` in `Sources/Updater.swift` (same scheme as AgentBar, verified by `UpdateCore.verifyEd25519`); a release without `ShareMount.zip.sig` is not offered at all, one with a wrong signature is offered but discarded before anything is unpacked. `build.sh release` signs `ShareMount.zip` with the private key from `~/Library/Application Support/ShareMount Release/ed25519.key` (`Shared/tools/release-key.swift`, called as `release-key ShareMount ...`), which never lives in the repo. Releasing from another Mac needs a copy of that file there (folder 0700, file 0600). If the public key printed by `build/release-key ShareMount public` does not match `SIGN_KEY` (read from `Updater.publicKey` in `build.sh`), the release is aborted.

Transition: versions up to 26.10.7 do not know the key and check only the SHA-256 checksum, which every release still carries. They therefore install the first signed release like any other; from then on every update must be signed. Until an installation has been updated once, it is still only as safe as the checksum.
