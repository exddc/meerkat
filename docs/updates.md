# App Updates

Meerkat uses [Sparkle 2](https://sparkle-project.org/documentation/) for automatic and manual updates. The release workflow notarizes each DMG, signs it with Sparkle's EdDSA key, and attaches it to a GitHub Release. The app reads available versions from `https://exddc.github.io/meerkat/appcast.xml`.

## One-Time Repository Setup

1. Generate a Sparkle EdDSA key pair with Sparkle's `generate_keys --account com.exddc.meerkat` command.
2. Add the printed public key as the `SPARKLE_PUBLIC_KEY` GitHub Actions secret.
3. Export the private key with `generate_keys --account com.exddc.meerkat -x sparkle_private_key`, then add the file contents as the `SPARKLE_PRIVATE_KEY` secret.
4. Add `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` secrets for Developer ID signing and notarization.
5. After the first release, configure GitHub Pages to deploy from the `gh-pages` branch root.

## Publish a Release

Push a version tag matching the app's marketing version:

```sh
git tag v0.0.1
git push origin v0.0.1
```

The release workflow builds the app, creates and notarizes the DMG, publishes it as a GitHub Release asset, updates the signed appcast, and publishes the appcast to GitHub Pages.
