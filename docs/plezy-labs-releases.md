# Plezy Labs releases

Plezy Labs releases are built only from the `labs` branch. The branch starts at
an official published Plezy tag and receives later upstream code only by merging
another published tag through the **Sync Official Plezy Release** workflow.

## One-time repository setup

1. Push `labs` and make it the fork's default branch so the scheduled watcher
   runs from the Labs workflow definitions.
2. Run `scripts/generate-labs-updater-key.sh`, back up the private key, and set
   the printed `LABS_SPARKLE_PRIVATE_KEY` secret and
   `LABS_UPDATE_PUBLIC_KEY` repository variable.
3. Configure the same macOS Developer ID and notarization secrets used by the
   inherited desktop build: `MACOS_CERTIFICATE_BASE64`,
   `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`,
   `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.
4. In GitHub notification settings, select failed-workflow-only notifications.

The build deliberately fails instead of publishing unsigned macOS or unsigned
Sparkle/WinSparkle update artifacts when any required value is missing.

## Publishing

- Run **Build Plezy Labs Release** for a normal Labs change. It computes the
  next revision and updater build, then creates a draft GitHub prerelease.
- Edit the generated GitHub Release description if desired and publish the
  draft. That description is the only release-notes source used by the app and
  native updater.
- The daily watcher runs at 8:00 AM in `America/New_York`. It can also be run
  manually. A clean new official release sync automatically publishes revision
  1; conflicts create an issue and publish nothing.

Official-to-Labs and Labs-to-official transitions are replacement installs.
Only Labs-to-Labs updates use the native updater.
