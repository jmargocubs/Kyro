# Kyro Release & Artifact History

**Last Updated:** 2026-11-17  
**Tracking System Version:** 1.1.0

---

## 1. Release Verification Record Schema

Every packaged IPA artifact must be recorded with the following reproducible fields:

```yaml
release_record:
  artifact_name: string          # Exact filename of the .ipa
  platform: ios | tvos          # Target platform
  target: Silo | SiloTV         # Xcode target
  marketing_version: string     # E.g., "1.0.0"
  build_number: integer         # CURRENT_PROJECT_VERSION
  source_branch: string         # Branch name at build time
  source_commit: string         # 40-character Git SHA (or 8-char abbreviated)
  dirty_tree: boolean           # True if uncommitted changes were compiled
  dirty_description: string     # Summary of uncommitted modifications, if dirty_tree is true
  signing_state: unsigned | signed
  sha256: string                # SHA-256 checksum of the .ipa file
  file_size_bytes: integer      # Exact byte size
  included_feature_ids: list    # List of stable feature IDs (from FEATURES.md)
  device_test_status: pending | accepted | rejected
  tested_device: string         # Model and identifier of physical device used for test
  stable_checkpoint: boolean    # True only if backed by an immutable tag and physical acceptance
  stable_tag: string            # Tag name (e.g. kyro-ios-v1.0.0-build<N>-stable), if applicable
```

> [!IMPORTANT]
> **Independent Platform Versioning:** iOS and tvOS build sequences and stable tags are tracked independently (`kyro-ios-v1.0.0-build<N>-stable` vs `kyro-tvos-v1.0.0-build<N>-stable`). Legacy tags (`kyro-v1.0.0-build84-stable`, etc.) are preserved verbatim.
> **Reproducibility Rule:** Stable releases MUST NOT be built from a dirty working tree. Any build built from a dirty tree is classified as a nonreproducible checkpoint unless its full source patch is preserved.
> **Device Acceptance Rule:** No build may be marked `stable_checkpoint: true` without confirmed physical-device testing.

---

## 2. Verified IPA Artifact Catalog

The following table records every known active build artifact with verified SHA-256 checksums and source provenance:

| Build & Artifact | Platform | Target | Source Branch & Commit | Tree State | SHA-256 Checksum | Size (Bytes) | Included Features | Device Acceptance | Stable Tag |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Build 84 Stable (iOS)**<br>`Kyro-v1.0.0-Build84-Unsigned.ipa` | iOS | Silo | `kyro/m1-rebrand`<br>`7f9224e5` | Clean | `e19ccd166517efe34261d0a7e8201975ba7fa34b011dde3a4cfea977219d3c31` | 29,129,391 | `FEAT-CAT-84`<br>`FEAT-PIP-69`<br>`FEAT-SPORTS-70` | **Accepted** (iPhone 16 Plus) | `kyro-v1.0.0-build84-stable` (Legacy) |
| **Build 85 (iOS)**<br>`Kyro-v1.0.0-Build85-Unsigned.ipa` | iOS | Silo | `kyro/m1-rebrand`<br>WIP | Dirty | `3bc99810fcbb630e0307121f34bb7dfd955fa6fddef3ec763087438055213f0e` | 29,100,752 | `FEAT-CAT-84`<br>WIP Settings | Superseded by Build 86 | None |
| **Build 86 (iOS)**<br>`Kyro-v1.0.0-Build86-Unsigned.ipa` | iOS | Silo | `kyro/m1-rebrand`<br>`94d9ad78` | Clean | `547d5f6392ed4584cb1874793250ecc19d24cc5261cd25cb39328649c5fd24cb` | 29,067,752 | `FEAT-CAT-84`<br>`FEAT-SET-86` | Unverified on device | None |
| **Build 88 (iOS)**<br>`Kyro-v1.0.0-Build88-Unsigned.ipa` | iOS | Silo | `kyro/m1-rebrand`<br>`557ee779` | Checkpoint (Committed) | `00ddd8899b9cdcd91ae66dba87a3c434bd088c26227a1fa6eba4517a7ce5ca57` | 29,180,459 | `FEAT-CAT-84`<br>`FEAT-SET-86`<br>`FEAT-BAK-88` | Unverified on device (Import-picker pending test) | None (Candidate) |
| **Build 89 Pairing (iOS)**<br>`Kyro-v1.0.0-Build89-Pairing-Unsigned.ipa` | iOS | Silo | `kyro/ios-pairing-b86`<br>`4bf10084` | Clean | `507013c5695043aabcb98cdd4c0c706664d7c4f2fdf609317f49cb8e354a790d` | 29,155,964 | `FEAT-CAT-84`<br>`FEAT-SET-86`<br>`FEAT-PAIR-CORE`<br>`FEAT-PAIR-IOS` | Unverified on device | None |
| **tvOS Build 84 Baseline**<br>`Kyro-tvOS-v1.0.0-Build84-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos`<br>`7f9224e5` | Clean | `1ee67b35656c508c50a8181c6ed132226125f7ac111b2dcc3fc201c6baea94b3` | 18,126,391 | `FEAT-TV-NATIVE` baseline | Superseded | None |
| **tvOS Build 84 TopShelfFix**<br>`Kyro-tvOS-v1.0.0-Build84-TopShelfFix-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos`<br>`8118b2f1` | Clean | `a47f6d9ac33cefcc2fbb65de426115c17697f9a5c8c237d084972e56221db253` | 18,125,844 | `FEAT-TV-NATIVE`<br>(Bundle ID aligned) | Superseded | None |
| **tvOS Build 84 Phase 1**<br>`Kyro-tvOS-v1.0.0-Build84-Phase1-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos`<br>`bd323e54` | Clean | `cf52eaf08ba64ba6813e7aad2b23cbbfab52410b648715f5d5c68fb43557d19e` | 30,048,037 | `FEAT-TV-NATIVE`<br>`FEAT-TV-LIVETV` | Superseded | None |
| **tvOS Build 84 Phase 2**<br>`Kyro-tvOS-v1.0.0-Build84-Phase2-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos`<br>`7c5925d6` | Clean | `650d96c6f405267af4c70f60ad79b9d2266c5c396a49b036e2781615fa834f15` | 30,285,665 | `FEAT-TV-LIVETV`<br>`FEAT-TV-SPORTS`<br>`FEAT-PAIR-CORE` | Superseded | None |
| **tvOS Build 84 Phase 3**<br>`Kyro-tvOS-v1.0.0-Build84-Phase3-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos`<br>`ab861de2` | Clean | `53c9d3fef45cea0965ff29dac82dd7546c7bbf6c3395ca1e28c1354f5ddaa798` | 31,002,301 | `FEAT-TV-SPORTS`<br>`FEAT-PAIR-CORE`<br>`FEAT-PAIR-TV` | Superseded | None |
| **tvOS Build 84 Phase 3A**<br>`Kyro-tvOS-v1.0.0-Build84-Phase3A-Unsigned.ipa` | tvOS | SiloTV | `kyro/tvos-phase3a`<br>`5bc4cd6e` | Clean | `6aac935fbec4543cd51a11c0da58f21f792a80498d93cb30631e0754a4296532` | 31,035,884 | `FEAT-TV-SPORTS`<br>`FEAT-PAIR-TV`<br>`FEAT-TV-FOCUS` | Pending Apple TV test | None (Candidate) |

---

## 3. Historical Milestones & Legacy Tags

| Build Number | Tag Name | Target SHA | Key Milestone | Verification State |
| :--- | :--- | :--- | :--- | :--- |
| **Build 84** | `kyro-v1.0.0-build84-stable` | `7f9224e5` | Stable Categories navigation, layouts, search & pinning | **Physically Verified & Accepted** |
| **Build 77** | `kyro-v1.0.0-build77-stable` | `6da08228` | Rollback & stabilization checkpoint | **Physically Verified & Accepted** |
| **Build 70** | `kyro-v1.0.0-build70-stable` | `c96935b5` | Sports Hub UX polish | **Physically Verified & Accepted** |
| **Build 69** | `kyro-v1.0.0-build69-pip-verified` | `5a245367` | Sports polish, pregame and PiP hotfix | **Physically Verified & Accepted** |
| **Build 65** | `kyro-v1.0.0-build65-checkpoint` | `7e0c5f89` | Tennis data, soccer supplement, PiP repair | Checkpoint |
| **Build 62** | `kyro-v1.0.0-build62-stable` | `1f3f7008` | Sports Hub, guide and playback stabilization | **Physically Verified & Accepted** |
| **Build 26** | `kyro-build-26` | `5eb46705` | Verified Build 26 baseline | **Physically Verified & Accepted** |
