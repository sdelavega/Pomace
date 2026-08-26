# Releasing Pomace

Pomace ships as a notarized ZIP containing `Pomace.app`. A DMG is unnecessary for this
single-app product: users can unzip it and move the app to Applications themselves.

Before the first release, store an App Store Connect app-specific password in the local
keychain. Do not place the password, Apple ID, team ID, or certificate in the repository:

```bash
xcrun notarytool store-credentials "Pomace Notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

With the existing Developer ID certificate installed locally, create a release artifact:

```bash
POMACE_NOTARY_PROFILE="Pomace Notary" ./release/release.sh 0.1.0
```

The script signs with the existing `POMACE_SIGN_ID` default from `build-app.sh`, enables a
secure timestamp, submits an archive with `notarytool`, staples the resulting ticket to the
app, validates it, and writes `dist/Pomace-<version>.zip` plus its SHA-256 checksum.
Upload both files to the matching GitHub Release.
