# CI and releases

Two GitHub Actions workflows, both on a `macos-26` runner with Xcode 26.6:

| Workflow | Runs on | Does |
| --- | --- | --- |
| [CI](../.github/workflows/ci.yml) | every pull request and push to main (not docs-only changes) | `swift build --build-tests`, `swift test` |
| [Release](../.github/workflows/release.yml) | a `v*` tag, or **Actions → Release → Run workflow** | builds Shout.app, checks it starts, packages `Shout-<version>.dmg` and publishes a GitHub Release with it |

The Release workflow also runs on pull requests that change the packaging (`scripts/`, `Resources/`, `Vendor/`,
`Package.swift`, the workflow itself). Those runs publish nothing: the disk image is attached to the run for 7 days.

## Making a release

```sh
git tag v1.2.0 && git push origin v1.2.0
```

Or open **Actions → Release → Run workflow**, pick the branch and type the version: the workflow tags that commit.
A version with a suffix (`1.2.0-beta.1`) becomes a prerelease. The app's version (Settings, About) is the number
part; its build number is the commit count. The release notes list the merged pull requests, with install steps
and the disk image's SHA-256.

The same steps run locally:

```sh
SHOUT_VERSION=1.2.0 scripts/build-app.sh   # dist/Shout.app; signs with your Developer ID or Apple Development identity
scripts/make-dmg.sh                         # dist/Shout-1.2.0.dmg and .sha256 (add --notarize with the APPLE_* variables)
```

## Signing

What someone downloading the release sees depends on the secrets set in **Settings → Secrets and variables →
Actions**:

| Secrets | Signature | Opening the download | Permissions after an update |
| --- | --- | --- | --- |
| none | ad-hoc | blocked once: System Settings → Privacy & Security → **Open Anyway** | asked again every update |
| certificate | Apple Development or Developer ID | blocked once, the same way | kept |
| certificate + notarization | Developer ID, notarized | opens normally | kept |

macOS ties Accessibility, Microphone and Screen Recording to the signature, which is why an ad-hoc build loses them
on every update.

**Certificate** (`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`): in Keychain Access, find the "Developer ID
Application" (or "Apple Development") certificate under My Certificates, right-click → Export → `.p12` with a
password, then:

```sh
base64 -i Certificates.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD   # the .p12's password
rm Certificates.p12
```

A Developer ID certificate needs the paid Apple Developer Program: developer.apple.com → Certificates → + →
Developer ID Application (the account holder creates it). With both identities in the keychain, the build prefers
Developer ID.

**Notarization** (`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`): your Apple Account email, the team ID from
developer.apple.com → Membership details, and an app-specific password from account.apple.com → Sign-In and
Security → App-Specific Passwords. Notarization needs a Developer ID certificate; with an Apple Development one the
release fails and says so. A tag build waits for Apple, usually a few minutes.

## Notes

- `Shout --version` prints the version and quits without opening a window. The build runs it after signing, so a
  signature that stops the frameworks loading fails the build instead of the download.
- Ad-hoc builds are signed without the hardened runtime: with it, macOS refuses to load the embedded llama and
  whisper frameworks for an ad-hoc signed app (it only allows frameworks from the same team). The hardened runtime
  is only needed for notarization.
- The repository is public, so anyone can download a release. CI skips docs-only changes, and a new push cancels the
  run it replaces.
