# tvOS text entry for Live TV provider fields

Investigated 2026-11-17 against the tvOS 27.0 SDK (Xcode 27.1).

## Question

Can an app make the system keyboard offer Siri's "Hold to spell" instead of
"Hold to dictate" for the provider URL, username and password fields?

## Finding

No supported API controls it. The setting is chosen by tvOS.

- `UITextInputTraits` (`keyboardType`, `textContentType`, `autocorrectionType`,
  `spellCheckingType`, `isSecureTextEntry`) has no dictation or spelling mode.
  `spellCheckingType` only turns spell-check underlines on or off.
- The dictation symbols in `UITextInput.h` (`insertDictationResult:`,
  `dictationRecordingDidEnd`) are callbacks for apps that implement their own
  text-input view. They receive dictation; they do not pick the mode.
- Searching UIKit, SwiftUI, TVUIKit and TVServices headers finds no "spell",
  "hold to dictate" or voice-input-mode symbol.
- The content-type hints (`.URL`, `.username`, `.password`) are advisory.
  tvOS may change how it offers voice input for them between releases, but an
  app cannot request a mode.

The only ways to force spelling would be a custom keyboard or private API.
Both are ruled out for Kyro.

## Decision

The fields stay on the native `TextField` and `SecureField`. That keeps secure
password handling and Apple's nearby-iPhone keyboard entry. No change was made.

## Recommended ways to enter provider details

1. Set up with a phone (QR pairing), which avoids typing on the TV.
2. The nearby iPhone keyboard prompt that tvOS shows for any focused text field.
