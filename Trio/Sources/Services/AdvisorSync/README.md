# Advisor Sync (Diabetics Advisor CloudKit export)

Exports Trio settings + recent treatment/glucose data as `AdvisorExport` JSON to the user's
**private CloudKit** database, for the companion **Diabetics Advisor** macOS app to read and
analyse on-device. Read-only w.r.t. Trio's data; advisory use only.

- `AdvisorExport.swift` — JSON schema. **Must stay identical** to the Mac app's copy
  (`~/Dev/diabetics-advisor-ai/Sources/Shared/AdvisorExport.swift`); bump `schemaVersion` on change.
- `AdvisorSyncManager.swift` — builds + pushes the export, debounced after each loop and at launch.

## One-time provisioning setup (required)

CloudKit needs the App ID to own/associate the container, which the App Store Connect API can't do.
Do this once (Trio must be signed under the **same Apple team** as the Mac app — `A42SG7SSPP`):

1. **Create the container** `iCloud.com.robcoenen.diabeticsadvisor` under team `A42SG7SSPP`
   (the Diabetics Advisor Mac app does this automatically on its first Xcode run, or create it in
   the CloudKit dashboard).
2. **Associate it with the Trio App ID** (`$(BUNDLE_ID)`): in the Apple Developer portal (or Xcode
   → Trio target → Signing & Capabilities → iCloud → CloudKit), enable iCloud/CloudKit and check
   `iCloud.com.robcoenen.diabeticsadvisor`.
3. **Regenerate signing**: run the **Create Certificates** workflow / `fastlane certs` (with match
   `force: true` once) so the App Store provisioning profile includes the container entitlement.
4. Re-run **Build Trio**.

The `fastlane prepare` lane enables the **iCloud capability** automatically (`configure_bundle_id`);
only the container association in step 2 is manual.
