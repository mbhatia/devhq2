# GitHub DMG signing setup

The `Build macOS installer` workflow builds an arm64 DMG for pull requests,
manual runs, and tags matching `v*`. Pull requests use ad-hoc signing and do not
receive repository signing secrets. Manual and tagged builds require a
Developer ID Application certificate and Apple notarization credentials.

## Apple Developer setup

1. Join the Apple Developer Program and note the 10-character Team ID shown in
   the developer account membership details.
2. In Certificates, Identifiers & Profiles, create a **Developer ID
   Application** certificate. A Developer ID Installer certificate is not used.
3. Install the certificate on a Mac, then export the certificate and its private
   key from Keychain Access as a password-protected `.p12` file. Record:
   - the `.p12` export password;
   - the complete signing identity, such as
     `Developer ID Application: Example Name (TEAMID)`.
4. For the Apple ID that will submit notarization requests, enable two-factor
   authentication and create an app-specific password at
   <https://appleid.apple.com/>.
5. Generate a separate random password for the temporary CI keychain. It is not
   an Apple account password and does not need to be stored anywhere else.

## Required GitHub Actions secrets

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded contents of the exported Developer ID Application `.p12` file. |
| `APPLE_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` file. |
| `APPLE_KEYCHAIN_PASSWORD` | A random password used only for the temporary CI keychain. |
| `APPLE_SIGN_IDENTITY` | Full Developer ID Application identity from Keychain Access. |
| `APPLE_ID` | Apple ID email used for notarization. |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for the notarization Apple ID. |

Run these commands from a trusted Mac. `gh secret set` prompts for each value,
so values do not appear in shell history:

```sh
gh secret set APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64 -R mbhatia/devhq2
gh secret set APPLE_CERTIFICATE_PASSWORD -R mbhatia/devhq2
gh secret set APPLE_KEYCHAIN_PASSWORD -R mbhatia/devhq2
gh secret set APPLE_SIGN_IDENTITY -R mbhatia/devhq2
gh secret set APPLE_ID -R mbhatia/devhq2
gh secret set APPLE_TEAM_ID -R mbhatia/devhq2
gh secret set APPLE_APP_SPECIFIC_PASSWORD -R mbhatia/devhq2
```

Before entering the first secret, copy the base64 representation without line
breaks to the clipboard:

```sh
base64 < /path/to/DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
```

Paste that value at the first prompt. Enter the corresponding text value at
each remaining prompt. GitHub encrypts Actions secrets and does not expose them
to pull-request workflows from forks.

## Running and publishing

After all seven secrets exist, start a signed build from the Actions tab with
**Run workflow**. Release tags must use `v` followed by a numeric dotted
version, such as `v0.1.0`. Such a tag builds, signs, notarizes, staples, and
validates the DMG, then creates or updates the matching GitHub release with
`DevHQ-macos-arm64.dmg`.

Manual and tagged builds execute repository build scripts while the signing
certificate is available. Only trusted maintainers should be able to dispatch
this workflow or create `v*` tags. Protect release tags and limit repository
write access accordingly.

Pull-request builds stop after ad-hoc signing and verification. They deliberately
skip notarization because Apple credentials are not available to untrusted pull
request code.
