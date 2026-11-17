# Kyro Feature Tracking Matrix

**Last Updated:** 2026-11-17  
**Tracking System Version:** 1.1.0

---

## 1. Feature Identification & Status Matrix

| Feature ID | Feature Name | Platform | Implementation Status | Canonical Branch & Commit | Device Test Status | Integration Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `FEAT-CAT-84` | Categories Navigation & Layouts | iOS | Complete | `kyro/m1-rebrand` (`7f9224e5`) | **Accepted** (Physical iPhone, Tag `kyro-v1.0.0-build84-stable`) | Base for all active branches |
| `FEAT-SET-86` | Settings Redesign & Diagnostics Move | iOS | Complete | `kyro/m1-rebrand` (`94d9ad78`) | Unverified on device (Unit/Integration tests pass) | Present in iOS mainline & `kyro/ios-pairing-b86`; missing from tvOS |
| `FEAT-BAK-88` | Settings Backup & Restore (`.kyrosettings`) | iOS | Complete (Checkpoint) | `kyro/m1-rebrand` (`557ee779`) | 14 unit test cases pass; physical device test pending for import-picker | Committed on `kyro/m1-rebrand`; missing from all other branches |
| `FEAT-PAIR-CORE` | Live TV Pairing Protocol Core (X25519/ChaChaPoly) | Shared (iOS & tvOS) | Complete | `kyro/ios-pairing-b86` (`0eb83a71`) / `kyro/tvos` (`72c6a81a`) | Verified via unit tests (`LiveTVPairingTests`) | Identical implementations on `kyro/ios-pairing-b86` and `kyro/tvos` |
| `FEAT-PAIR-IOS` | iPhone Live TV Pairing Sender & UI | iOS | Complete | `kyro/ios-pairing-b86` (`4bf10084`) | Packaged in Build 89; unverified on physical hardware | Present on `kyro/ios-pairing-b86`; missing from `kyro/m1-rebrand` & tvOS |
| `FEAT-PAIR-TV` | Apple TV Pairing Receiver & Approval Flow | tvOS | Complete | `kyro/tvos` (`c9371b79`) | Packaged in Build 84 Phase 3/3A; unverified on physical Apple TV | Present on `kyro/tvos` & `kyro/tvos-phase3a`; missing from iOS branches |
| `FEAT-TV-NATIVE` | tvOS Native App Foundation & Top Shelf | tvOS | Complete | `kyro/tvos` (`4482a88a`, `8118b2f1`) | Packaged in Build 84 TopShelfFix; unverified on physical hardware | Present on `kyro/tvos` & `kyro/tvos-phase3a`; missing from iOS branches |
| `FEAT-TV-LIVETV` | tvOS Native Live TV Experience | tvOS | Complete | `kyro/tvos` (`bd323e54`) | Packaged in Build 84 Phase 1; unverified on physical hardware | Present on `kyro/tvos` & `kyro/tvos-phase3a`; missing from iOS branches |
| `FEAT-TV-SPORTS` | tvOS Native Sports Hub & Playback Driver | tvOS | Complete | `kyro/tvos` (`7c5925d6`) | Packaged in Build 84 Phase 2; unverified on physical hardware | Present on `kyro/tvos` & `kyro/tvos-phase3a`; missing from iOS branches |
| `FEAT-TV-FOCUS` | tvOS Siri Remote Focus Predictability & Treatment | tvOS | Complete | `kyro/tvos-phase3a` (`5bc4cd6e`) | Packaged in Build 84 Phase 3A; focus unit tests pass; unverified on physical TV | Isolated on `kyro/tvos-phase3a`; missing from `kyro/tvos` and iOS branches |
| `FEAT-EPG-SEARCH` | EPG Programme Search & Query Seam | iOS | Complete | `kyro/m1-rebrand` (`595a8397`, `fa961be2`) | Verified in Build 26–31 baselines | Merged into `kyro/m1-rebrand` baseline |
| `FEAT-PIP-69` | PiP Repair, Sports Polish & Pregame | iOS | Complete | `kyro/m1-rebrand` (`5a245367`) | **Accepted** (Physical iPhone, Tag `kyro-v1.0.0-build69-pip-verified`) | Integrated in `kyro/m1-rebrand` baseline |

---

## 2. Feature Detailed Profiles

### `FEAT-CAT-84`: Categories Navigation & Layouts
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/LiveTV/Guide/LiveTVCategoryBrowser.swift`
  - `iosApp/iosApp/LiveTV/LiveTVBrowseModel.swift`
  - `iosApp/iosApp/LiveTV/LiveTVViews.swift`
  - `iosApp/Tests/KyroBuild73CategoriesTests.swift`
- **Verification:** Physically verified and accepted on iPhone 16 Plus running Build 84. Tagged as `kyro-v1.0.0-build84-stable`.

### `FEAT-SET-86`: Settings Redesign & Diagnostics Move
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift`
  - `iosApp/iosApp/Screens/Settings/LiveTVDiagnosticsSettingsView.swift`
  - `iosApp/iosApp/Screens/Settings/PlaybackSettingsView.swift`
  - `iosApp/Tests/KyroSettingsIntegrationTests.swift`
- **Verification:** Unit and integration tests pass in suite. Physical device acceptance is unverified.

### `FEAT-BAK-88`: Settings Backup & Restore
- **Platform:** iOS (architecture extensible to tvOS)
- **Source Paths:**
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupLiveRegistry.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupModel.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift`
  - `iosApp/iosApp/Screens/Settings/SettingsBackupView.swift`
  - `iosApp/Tests/SettingsBackupCoreTests.swift`
  - `iosApp/Tests/SettingsBackupLiveRegistryTests.swift`
  - `iosApp/iosApp/Info.plist` (registered `com.cubbiestream.kyro.settings-backup` UTType)
- **Description:** Export and import of device preferences in JSON format (`.kyrosettings` extension). Includes validation, transactional restore with rollback on error, notification broadcasting (`kyroSettingsDidRestore`), and registry integration. Incorporates Build 88.1 and 88.2 file importer picker corrections (`[.json, .data, .item]`).
- **Verification:** Committed checkpoint commit `557ee779`. 14 unit test cases pass. Packaged into `Kyro-v1.0.0-Build88-Unsigned.ipa`. Physical device testing pending.

### `FEAT-PAIR-CORE`: Live TV Pairing Core
- **Platform:** Shared (iOS & tvOS)
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingCrypto.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingModels.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingProviderStore.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingSession.swift`
  - `iosApp/Tests/LiveTVPairingTests.swift`
- **Verification:** Covered by tests in `LiveTVPairingTests.swift`. Implementation is bit-for-bit identical across `kyro/ios-pairing-b86` and `kyro/tvos`.

### `FEAT-PAIR-IOS`: iPhone Companion Pairing Sender
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/iOS/KyroSendToAppleTVView.swift`
  - `iosApp/iosApp/Pairing/LiveTV/iOS/LiveTVPairingBrowser.swift`
  - `iosApp/iosApp/Pairing/LiveTV/iOS/LiveTVPairingClient.swift`
  - `iosApp/iosApp/Info.plist` (`_kyrolive._tcp` Bonjour registration)
- **Verification:** Packaged into `Kyro-v1.0.0-Build89-Pairing-Unsigned.ipa`. Physical device pair-testing with Apple TV pending.

### `FEAT-PAIR-TV`: tvOS Companion Pairing Receiver
- **Platform:** tvOS
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/TVLiveTVPairingReceiver.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVPairingView.swift`
  - `docs/livetv-phone-pairing.md`
- **Verification:** Built into tvOS Build 84 Phase 3 and Phase 3A. Physical device test pending.

### `FEAT-TV-FOCUS`: tvOS Siri Remote Focus & Grid Layout
- **Platform:** tvOS
- **Source Paths:**
  - `iosApp/iosApp/tvOS/Components/TVKyroFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVGuideFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVProviderFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVView.swift`
  - `iosApp/Tests/KyroTVFocusTests.swift`
- **Verification:** Unit tests pass (`KyroTVFocusTests.swift`). Built into `Kyro-tvOS-v1.0.0-Build84-Phase3A-Unsigned.ipa`. Physical device verification pending.
