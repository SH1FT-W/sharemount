# Releasing

`./build.sh release next "What's new"` sets the version, builds, runs the self tests, commits, tags, pushes and publishes `ShareMount.zip` plus `ShareMount.zip.sha256` as a GitHub release. Installed apps pick it up through their update check.

Versions are calendar versions `YY.M.N`: two-digit year, month without a leading zero, and the running number of the release within that month, starting at 1 (every GitHub release published that month counts, including older `X.Y.Z` ones; bare tags without a release do not). A new month starts again at `.1`. `tools/next-version` computes the next one (tag `vYY.M.N`); `next` uses it, and any other version is refused unless `ALLOW_VERSION=1` is set. Version checks compare the numbers part by part, so `26.10.10` is newer than `26.10.9` and any calendar version is newer than `2.x`.
