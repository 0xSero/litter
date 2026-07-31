# Android Play Internal Checklist

## One-time Setup
1. In Play Console, create app `com.sigkitten.litter.android`.
2. Create a Service Account in Google Cloud and grant it Play Console access to the app.
3. Download the service-account JSON key.
4. Use the existing upload keystore. If it is unavailable, create a replacement
   upload key and complete the Play Console upload-key reset before uploading.
   Play App Signing keeps the app-signing key with Google; the local key is only
   the upload credential.

On macOS, create replacement upload-key material with:

```bash
./apps/android/scripts/setup-upload-key.sh
```

The script keeps the keystore under `~/.config/litter`, stores its passwords in
the login Keychain, writes a non-secret loader file, and exports the public PEM
certificate Play Console needs for an upload-key reset. It refuses to overwrite
existing key material.

## Required Environment Variables
- `LITTER_PLAY_SERVICE_ACCOUNT_JSON` = path to service-account JSON
- `LITTER_UPLOAD_STORE_FILE` = path to upload keystore (`.jks`)
- `LITTER_UPLOAD_STORE_PASSWORD` = keystore password
- `LITTER_UPLOAD_KEY_ALIAS` = key alias
- `LITTER_UPLOAD_KEY_PASSWORD` = key password
- Optional: `LITTER_PLAY_TRACK` (default: `internal`)

## Upload Command
```bash
./apps/android/scripts/play-upload.sh
```

The default is a draft on the internal track. It uploads the AAB without making
it available to testers. To make an internal build available after review:

```bash
LITTER_PLAY_RELEASE_STATUS=completed ./apps/android/scripts/play-upload.sh
```

Promotion to another track is always explicit:

```bash
LITTER_PLAY_RELEASE_STATUS=draft \
LITTER_PLAY_PROMOTE_TRACK=production \
./apps/android/scripts/play-upload.sh
```

The source internal release must be completed for Play promotion, so the script
does that automatically when `LITTER_PLAY_PROMOTE_TRACK` is set. The destination
still uses the requested status.

## Variant Selection
- Default variant: `OnDeviceRelease`
- To upload remote-only:
```bash
VARIANT=RemoteOnlyRelease ./apps/android/scripts/play-upload.sh
```

## Build Only (No Upload)
```bash
UPLOAD=0 ./apps/android/scripts/play-upload.sh
```
