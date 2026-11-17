# Kyro Development & Platform Status

**Last Updated:** 2026-11-17  
**Repository:** `/Users/paolazanetti/.t3/scratch/kyro-silo`  
**Tracking System Version:** 1.1.0

---

## 1. Executive Summary

Kyro iOS and tvOS development operate across parallel branches:

- **iOS Mainline (`kyro/m1-rebrand`):** Anchored on committed Build 86.1 (`94d9ad78`), advanced by **committed Checkpoint Build 88/88.2 (`557ee779`)** covering Settings Backup & Restore and file importer picker corrections.
- **iOS Pairing Companion Branch (`kyro/ios-pairing-b86`):** Anchored on Build 86 (`94d9ad78`), advanced by commit `4bf10084` (`KyroSendToAppleTVView`, Bonjour browser, routing), packaged as Build 89.
- **tvOS Lineage (`kyro/tvos` & `kyro/tvos-phase3a`):** Diverged from **Build 84 Stable (`7f9224e5`)**. Developed native tvOS foundation, Top Shelf integration, native Live TV, Sports Hub, phone pairing receiver (`c9371b79`), and Phase 3A Siri Remote focus visibility (`5bc4cd6e`).
- **Integration State:** No code has been integrated between iOS and tvOS yet. Integration plan is prepared and ready for execution.

---

## 2. Worktree & Branch Inventory

| Worktree Path | Active Branch | HEAD Commit | Commit Subject | Tree Status |
| :--- | :--- | :--- | :--- | :--- |
| `/Users/paolazanetti/.t3/scratch/kyro-silo` | `kyro/m1-rebrand` | `557ee779` | `feat(kyro): checkpoint Builds 88-88.2 Settings Backup & Restore` | Clean of code (Tracking docs & untracked scripts only) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/kyro-ios-b86` | `kyro/ios-pairing-b86` | `4bf10084` | `fix(ios): open the Apple TV pairing screen from any state` | Clean (untracked `artifacts/`) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/kyro-ios-integration` | `kyro/ios-pairing-integration` | `87685dc8` | `fix(ios): make phone pairing survive first run and report failures` | Clean (untracked `artifacts/`) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/kyro-ios-pairing` | `kyro/ios-tv-pairing` | `5dbee415` | `feat(ios): send a Live TV provider to Apple TV` | Clean (untracked `artifacts/`) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/kyro-tvos` | `kyro/tvos` | `ab861de2` | `docs(pairing): document Live TV phone pairing and the browser fallback` | Clean (untracked `artifacts/`) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/kyro-tvos-3a` | `kyro/tvos-phase3a` | `5bc4cd6e` | `fix(tvos): make Siri Remote focus predictable and visible` | Clean (untracked `artifacts/`) |
| `/Users/paolazanetti/.t3/worktrees/kyro-silo/t3-0357580d` | `t3/epg-program-search-index` | `31e1ed26` | `chore(kyro): make unified navigation default and stabilize test configuration` | Historical worktree (ancestor of `kyro/m1-rebrand`) |

---

## 3. Platform Status & Checkpoints

### iOS Platform Status
- **Latest Formally Accepted Stable Checkpoint:** `kyro-v1.0.0-build84-stable` (`7f9224e5`) — verified Categories navigation, layout, grouping, search, pinning, and scroll restoration.
- **Committed Redesign Checkpoint:** Build 86.1 (`94d9ad78`) — Settings overview redesign, Live TV diagnostics repositioning, Downloads hydrator and row wrapping fixes.
- **Committed Feature Checkpoint:** Build 88/88.2 (`557ee779`) — Settings Backup & Restore (`.kyrosettings` UTType, JSON codec, live registry, rollback on error, Build 88.1/88.2 file importer picker corrections). 14 unit test cases pass. Unsigned IPA packaged (`Kyro-v1.0.0-Build88-Unsigned.ipa`).
- **Companion Pairing Branch:** `kyro/ios-pairing-b86` (`4bf10084`) — adds Bonjour browsing for `_kyrolive._tcp`, pairing client crypto, and `KyroSendToAppleTVView`. Packaged as `Kyro-v1.0.0-Build89-Pairing-Unsigned.ipa`.

### tvOS Platform Status
- **Base Anchor:** `kyro-v1.0.0-build84-stable` (`7f9224e5`).
- **Phase 1 Checkpoint:** Native app compilation restored (`903ac760`), Top Shelf bundle ID aligned (`8118b2f1`), Kyro native foundation established (`4482a88a`).
- **Phase 2 Checkpoint:** Native Live TV experience added (`bd323e54`), shared pairing core added (`72c6a81a`), native Sports Hub added (`7c5925d6`).
- **Phase 3 Checkpoint:** Phone pairing setup receiver implemented (`c9371b79`), architecture and security documented (`ab861de2`).
- **Phase 3A Focus Polish Checkpoint:** `kyro/tvos-phase3a` (`5bc4cd6e`) — Siri Remote focus visibility (cyan ring, dark keyline, lift/shadow), predictable grid navigation, program cell placement by layout, and provider back navigation. Packaged as `Kyro-tvOS-v1.0.0-Build84-Phase3A-Unsigned.ipa`.

---

## 4. Current Blockers & Risks

1. **Shared File Drifting:**  
   `LiveTVViews.swift`, `LiveTVService.swift`, `Info.plist`, and `project.yml` have diverged between iOS and tvOS worktrees. Handled via integration plan.
2. **Device Verification Pending:**  
   Build 88 Backup & Restore file-picker resolution and tvOS Phase 3A focus improvements require physical device testing before promotion to `-stable` tags.
3. **Build Serialization:**  
   Addressed by `docs/kyro-development/scripts/kyro-build-lock.sh`.
