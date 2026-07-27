# Cairn notarization authentication

Read this reference whenever `notarytool` authentication fails or the release
uses `ASC_KEY_*`.

## Authentication matrix

| Method | Required variables | Must be absent |
| --- | --- | --- |
| Keychain profile | `CAIRN_NOTARY_PROFILE` | all `ASC_KEY_*` |
| Team API Key | `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | `CAIRN_NOTARY_PROFILE` |

Apple documents that Individual API keys cannot use `notarytool`. Use a Team
API key with its Issuer UUID, or a keychain profile. Source:
<https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api>.

The release scripts reject mixed profile/API configuration. This prevents a
stale `CAIRN_NOTARY_PROFILE` from silently taking precedence while an agent
believes it is testing an API Key.

The release entry points use `#!/bin/zsh -f`. This is intentional: ordinary
non-interactive zsh reads `~/.zshenv`, which can silently repopulate old
`ASC_KEY_PATH`, `ASC_KEY_ID`, or `ASC_ISSUER_ID` values after an agent unsets
them in its parent environment. Keep release authentication explicit; do not
remove `-f`.

## Meaning of each value

- `ASC_KEY_PATH`: absolute, readable path to the one-time-downloaded `.p8`
  private key. A quoted value such as `~/Downloads/AuthKey_....p8` does not
  expand; use an absolute path.
- `ASC_KEY_ID`: App Store Connect API Key ID, usually at least 10 alphanumeric
  characters. It is not the Team ID.
- `ASC_ISSUER_ID`: App Store Connect API Issuer ID in UUID form. It is not the
  Apple Developer Team ID shown in the signing certificate.

Do not infer an Issuer ID from the filename, Team ID, certificate, bundle ID,
or Apple ID. Read it from the same App Store Connect account and key type.

## Safe preflight

Run:

```bash
.agents/skills/cairn-release/scripts/preflight.sh credentials
```

The script checks without submitting an archive:

- exactly one authentication method is configured;
- API Key variables are complete for the selected key type;
- path is absolute, readable, and points to a private-key PEM;
- Key ID and Issuer ID have plausible shapes;
- Developer ID identity exists;
- `xcrun notarytool history` authenticates successfully.

`notarytool history` success is the credential gate. A file existing on disk
does not prove that the key is active, belongs to the intended account, or has
sufficient access.

## Common failures

### Key path fails before authentication

Symptoms: file not found, `ASC_KEY_PATH does not point to a file`, or preflight
rejects a relative path.

Check that the environment contains the absolute `.p8` path. Do not copy the
key into the repository. If the original one-time download is lost, create a
new App Store Connect key and revoke the lost key.

### Team ID was used as Issuer ID

A Team ID is commonly 10 alphanumeric characters. An Issuer ID is a UUID.
Replace `ASC_ISSUER_ID` with the App Store Connect Issuer ID; do not change the
Developer ID signing identity to make the formats match.

### An Individual API Key was selected

Individual API keys cannot use `notarytool`. Create or select a Team API key
under App Store Connect Users and Access, then use its exact Key ID, one-time
downloaded `.p8`, and Issuer UUID. Alternatively, use a verified keychain
profile.

### Key ID and `.p8` do not belong together

The default filename is `AuthKey_<KEY_ID>.p8`. Renaming is allowed, so filename
mismatch is a warning rather than proof, but a wrong Key ID produces invalid
credentials. Match the ID to the exact downloaded key.

### Key was revoked, belongs to another account, or lacks access

The local file can be valid PEM while server authentication still fails.
Confirm the key remains active and has access to the intended App Store Connect
team. Prefer replacing/revoking keys in App Store Connect over editing private
key contents.

### Authentication succeeds but submission is rejected

Authentication and package acceptance are separate gates. Record the submission
ID and retrieve Apple's diagnostic:

```bash
xcrun notarytool log <submission-id> <the same authentication arguments>
```

Inspect the JSON issues for signing, hardened runtime, nested code, entitlement,
or bundle problems. Do not rotate a working API Key to fix a package-validation
error.

### Keychain profile fallback

When API Key ownership or type cannot be established safely, use a verified
keychain profile instead:

```bash
unset ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID
export CAIRN_NOTARY_PROFILE=<profile>
.agents/skills/cairn-release/scripts/preflight.sh credentials
```

Never print an app-specific password or persist it in repository files.

### Values reappear after `unset`

If a direct zsh probe shows `ASC_*` values that the agent removed, inspect
`~/.zshenv` without printing values. Cairn's release scripts intentionally use
zsh `-f` to avoid this startup-file injection. Do not source shell startup
files manually inside the release process.
