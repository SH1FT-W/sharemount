# Releasing

`./build.sh release X.Y "What's new"` bumps the version, builds, runs the self tests, commits, tags, pushes and publishes `ShareMount.zip` plus `ShareMount.zip.sha256` as a GitHub release. Installed apps pick it up through their update check.
