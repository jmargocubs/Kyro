# Kyro Development & Platform Status

**Last Updated:** 2026-11-17  
**Repository:** `<repo>`  
**Tracking System Version:** 1.2.0

---

## 1. Executive Summary

Kyro iOS and tvOS development branches have completed their planned integrations and stand ready for independent candidate packaging:

- **iOS Mainline (`kyro/m1-rebrand`):** HEAD at [`6eb3befc`](<repo>). Fully integrates **Settings Redesign** (Build 86.1, `94d9ad78`), **Backup & Restore with Build 88.2 importer fix** (`557ee779`), and **iPhone Live TV Pairing Sender** (cherry-picked commits `45f2e160`, `bdb4fc7a`, `7e72762e`, `e4750bd7`). Configured for **iPhone Build 90**.
- **tvOS Canonical Branch (`kyro/tvos`):** HEAD at [`5bc4cd6e`](<worktrees>/kyro-tvos). Verified and **fast-forwarded** to include **Phase 3A Siri Remote focus visibility & grid navigation**. Configured for **Apple TV Build 85**.
- **Integration State:** All intended features are integrated without duplication or conflicts. Source code is verified and prepared for candidate compilation.

---

## 2. Worktree & Branch Inventory

| Worktree Path | Active Branch | HEAD Commit | Commit Subject | Tree Status | Status / Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `<repo>` | `kyro/m1-rebrand` | `6eb3befc` | `chore(ios): set CURRENT_PROJECT_VERSION to 90 for iPhone release candidate` | Clean of code | Canonical iOS branch ready for Build 90 packaging |
| `<worktrees>/kyro-tvos` | `kyro/tvos` | `5bc4cd6e` | `fix(tvos): make Siri Remote focus predictable and visible` | Clean | Canonical tvOS branch fast-forwarded to Phase 3A; ready for Build 85 packaging |
| `<worktrees>/kyro-tvos-3a` | `kyro/tvos-phase3a` | `5bc4cd6e` | `fix(tvos): make Siri Remote focus predictable and visible` | Clean | Reference branch (now aligned with `kyro/tvos`) |
| `<worktrees>/kyro-ios-b86` | `kyro/ios-pairing-b86` | `4bf10084` | `fix(ios): open the Apple TV pairing screen from any state` | Clean | Historical source branch for pairing commits; fully integrated into `kyro/m1-rebrand` |
| `<worktrees>/kyro-ios-integration` | `kyro/ios-pairing-integration` | `87685dc8` | `fix(ios): make phone pairing survive first run and report failures` | Clean | Historical integration attempt |
| `<worktrees>/kyro-ios-pairing` | `kyro/ios-tv-pairing` | `5dbee415` | `feat(ios): send a Live TV provider to Apple TV` | Clean | Historical sender branch |
| `<worktrees>/t3-0357580d` | `t3/epg-program-search-index` | `31e1ed26` | `chore(kyro): make unified navigation default and stabilize test configuration` | Clean | Historical search index branch |

---

## 3. Platform Status & Release Candidates

### iOS Platform Status (Build 90 Candidate)
- **Candidate HEAD:** [`6eb3befc`](<repo>)
- **Included Features:**
  - `FEAT-CAT-84`: Verified Categories navigation, layouts, grouping, search, pinning, and scroll restoration.
  - `FEAT-SET-86`: Settings overview redesign and Live TV diagnostics repositioning.
  - `FEAT-BAK-88`: Settings Backup & Restore with Build 88.2 file importer picker type resolution corrections (`[.json, .data, .item]`).
  - `FEAT-PAIR-CORE`: Cryptographic Live TV pairing protocol core.
  - `FEAT-PAIR-IOS`: iPhone companion pairing sender UI (`KyroSendToAppleTVView`), Bonjour browser, and deep link routing.
- **Physical Device Gate:** Pending physical installation and verification on iPhone 16 Plus.

### tvOS Platform Status (Build 85 Candidate)
- **Candidate HEAD:** [`5bc4cd6e`](<worktrees>/kyro-tvos)
- **Included Features:**
  - `FEAT-TV-NATIVE`: Native tvOS foundation and Top Shelf bundle ID alignment.
  - `FEAT-TV-LIVETV`: Native full-screen Live TV experience.
  - `FEAT-TV-SPORTS`: Native Sports Hub and playback driver.
  - `FEAT-PAIR-CORE`: Cryptographic Live TV pairing protocol core (identical to iOS).
  - `FEAT-PAIR-TV`: Apple TV phone pairing receiver and approval flow.
  - `FEAT-TV-FOCUS`: Phase 3A Siri Remote focus visibility, cyan ring, layout-placed grid cells, and provider back navigation.
- **Physical Device Gate:** Pending physical installation and verification on Apple TV 4K.

---

## 4. Next Actions

1. Acquire host-wide build lock via `kyro-build-lock.sh`.
2. Compile and package **iPhone Build 90** (`Kyro-v1.0.0-Build90-Unsigned.ipa`).
3. Compile and package **Apple TV Build 85** (`Kyro-tvOS-v1.0.0-Build85-Unsigned.ipa`).
4. Execute physical device verification on `iPhone 16 Plus` and `Living Room Apple TV 4K`.
5. Mint independent platform tags: `kyro-ios-v1.0.0-build90-stable` and `kyro-tvos-v1.0.0-build85-stable`.
