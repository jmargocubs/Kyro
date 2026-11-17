# Live TV provider setup from a phone

Apple TV is a poor place to type a long IPTV URL, username and password. Kyro on
Apple TV can instead receive a saved provider from the Kyro iPhone app over the
local network.

Code: `iosApp/iosApp/Pairing/LiveTV/` (shared core, Apple TV receiver, iPhone
sender), `tvOS/LiveTV/TVLiveTVPairingView.swift`, `Tests/LiveTVPairingTests.swift`.

## Flow

1. On Apple TV: Live TV → Providers → **Set up with phone**. The TV opens a
   five-minute session, shows a QR and a code such as `ABCDE-FGHJK`, and listens
   on a random local port. It advertises `_kyrolive._tcp` over Bonjour.
2. On iPhone: scan the QR with the Camera app (opens `kyro://livetv-pair?...`),
   or open Live TV settings → **Send provider to Apple TV**, pick the TV and
   type the code.
3. The phone authenticates the TV, then shows the code, the provider list and
   **Send**. Nothing leaves the phone before that tap.
4. The TV shows the provider name, type and host, and the sender. The TV user
   presses **Allow** or **Decline**. Only Allow saves it.
5. The TV saves through the existing keychain-backed Live TV store and loads
   channels and the guide.

## Protocol

Length-prefixed JSON frames over TCP (4-byte big-endian length, 16 KiB cap):
`hello` → `helloAck` → `deliver` → `result`.

- **Pairing code**: 10 random Crockford base32 characters (50 bits), shown on the
  TV and carried in the QR. It is never sent over the network.
- **Public session id**: 16 random bytes, in the Bonjour record and the QR.
- **Mutual proof**: the phone sends `HMAC(code, sid ‖ phoneKey)`; the TV answers
  with `HMAC(code, sid ‖ phoneKey ‖ tvKey)`. The phone sends nothing until the
  TV's proof verifies.
- **Key**: ephemeral X25519 on both sides; HKDF-SHA256 over the shared secret,
  salted with the session id and the code.
- **Payload**: provider JSON sealed with ChaChaPoly; session id and both public
  keys are the associated data, so a frame cannot be replayed into another
  session.

## Security properties

| Property | How |
|---|---|
| No credentials in QR, URL, Bonjour or logs | QR holds only host, port, session id and code. `LiveTVPairingPayload`, frames and errors print fixed text; `dump` shows no fields. |
| Cryptographically secure tokens | `SecRandomCopyBytes`; code characters use `& 31` (unbiased). |
| Expiry | 300 seconds, checked on every input and by a one-second countdown. |
| Single use | One phone, one delivery, one approval. Every terminal state refuses all input. |
| Wrong codes | Three failed proofs or decryptions end the session. A second connection cannot burn attempts or take over. |
| Explicit approval | Phone: tap Send. TV: press Allow. |
| Local network only | The phone refuses QR hosts outside RFC 1918, link-local, loopback, ULA or `.local`. |
| Cancel | Cancel and New Code on the TV; Cancel on the phone. |
| Storage | `LiveTVService.saveConfiguration` / `saveXtreamConfiguration`, which write the secret to the keychain store and nothing sensitive to UserDefaults. |

Known limits: the code protects against LAN observers, not against someone who
can see the TV screen during the five minutes. The TV and phone must be on the
same network segment.

## Browser fallback (no Kyro on the phone)

**Not implemented. No safe version exists within the constraints.**

A page served by the Apple TV would let any phone browser enter a provider, but
the requirements rule out every workable transport:

- **Plain HTTP on the LAN** sends credentials in the clear and lets anyone on
  the network alter the page. Browsers also withhold `crypto.subtle` on insecure
  origins, so the page cannot encrypt in the browser, and JavaScript served over
  HTTP can be rewritten in transit.
- **HTTPS served by the TV** needs a certificate. No public CA issues one for a
  private IP or `.local` name, so the TV would use a self-signed certificate and
  every browser would show a security warning. Teaching users to click through
  that warning on a credentials form is the wrong habit. A fingerprint shown on
  the TV could be compared by hand, but few people will do it.
- **A static HTTPS page on free hosting that posts to the TV** is blocked as
  mixed content (HTTPS page to an HTTP LAN address), and Chrome and Safari
  restrict requests from public pages to private addresses.
- **A cloud relay** works technically but is a recurring cost and a third party
  holding credentials, both ruled out.

tvOS itself allows a foreground `NWListener` with TLS; the blocker is browser
trust, not the platform.

### Safe alternatives that need no Kyro on the phone

1. **Nearby iPhone keyboard.** When an iPhone signed in to the same Apple ID is
   near, tvOS offers to type into any focused native text field from the phone,
   and the phone can paste a long URL. Kyro's provider fields are native
   `TextField` and `SecureField`, so this works with no code. See
   `tvos-keyboard-entry.md`.
2. **Kyro on the phone** (implemented above).

## Test checklist (physical devices)

1. Open Set up with phone on the TV; confirm the QR, code and countdown appear.
2. Scan the QR with the iPhone Camera; confirm Kyro opens the send screen.
3. Confirm the phone shows the same code as the TV before Send.
4. Send an M3U and an Xtream provider; confirm the TV asks Allow/Decline and the
   channel list loads after Allow.
5. Decline; confirm nothing is saved.
6. Let the code expire; confirm both devices report it and a new code works.
7. Enter a wrong code three times; confirm the session ends.
8. Cancel from the TV mid-pairing and from the phone mid-pairing.
9. Deny Local Network access on the phone; confirm the message points to Settings.
10. Confirm no URL, username or password appears in the QR or in Console logs.
