# iOS TestFlight Checklist

## One-time Setup

1. The Account Holder requests App Store Connect API access under **Users and
   Access → Integrations → App Store Connect API** and accepts Apple's API-use
   agreement.
2. Create a team API key with the app-management access needed for TestFlight,
   then download its `.p8` file. Apple only offers that download once.
3. Store the key as GitHub Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
   `ASC_PRIVATE_KEY_P8_B64`. Keep the `.p8` file outside the repository.
4. Configure the distribution certificate and every provisioning-profile secret
   named by `.github/workflows/mobile-release.yml`.

The release preflight parses the private key and makes an authenticated app
lookup before native compilation. Missing, malformed, expired, or unauthorized
credentials therefore fail before the expensive iOS build.

## Release Checklist

1. Confirm `apps/ios/project.yml` bundle ID/version/build settings are correct.
2. Update `docs/releases/testflight-whats-new.md` with changelog bullets for this build.
3. Keep `docs/releases/testflight-beta-description.txt` populated with the evergreen Beta App Description.
4. Upload via `./apps/ios/scripts/testflight-upload.sh`. The script regenerates the project, archives, exports, and uploads the IPA; it also applies the Beta App Description and What to Test notes, assigns internal and external beta groups, submits Beta App Review by default, and auto-bumps to the next patch version if the committed repo version has already shipped live.
5. Validate processing in App Store Connect.
6. Confirm the build is attached to both internal and external TestFlight groups.
7. Confirm Beta App Review submission/approval state for the external build, then verify release notes and tester instructions.
8. If the workflow advanced to a new beta patch version, confirm `apps/ios/project.yml` and `docs/releases/testflight-whats-new.md` were updated for the next cycle.
9. Smoke test install + login/session/message flow.

If upload succeeds but metadata or review submission fails, rerun only the
finalization stage with the `iOS TestFlight Finalize` workflow and the existing
marketing version/build number. Do not rebuild the IPA.

The finalizer reuses Beta App Review contact details already present in
TestFlight, or copies them from an existing App Store version without logging
them. If neither source is populated, set the optional release secrets
`TESTFLIGHT_REVIEW_CONTACT_FIRST_NAME`, `TESTFLIGHT_REVIEW_CONTACT_LAST_NAME`,
`TESTFLIGHT_REVIEW_CONTACT_EMAIL`, and `TESTFLIGHT_REVIEW_CONTACT_PHONE`.
