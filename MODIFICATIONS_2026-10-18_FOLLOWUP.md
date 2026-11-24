# Erosion follow-up patch — 2026-10-18

This follow-up is based on `Erosion_Full_Source_Modified.zip` from the previous turn.

- Restored the `Run Exploit` button inside Airlift's existing `Actions` section. It calls the existing `AirliftBridge.runExploit()` implementation and is disabled while the exploit is running, when LocalDevVPN is down, or when pairing is unavailable.
- Restored a separate selector section in Containers so the segmented selector is visually distinct from the Search / Results card. Its vertical row insets are increased minimally (4 pt to 5 pt above and below).
- Removed automatic Dialer Themer key loading from view appearance. Current `TelephonyUI-10` retrieval runs from the explicit `Get Current Keys` action only. Reset Keys no longer triggers a hidden reread. Non-Airlift container discovery and access preparation are now performed when the user taps `Get Current Keys`.

Validation: `swiftc -parse` succeeded for all Swift files under `Erosion/`. This is a syntax check, not an Xcode build or on-device test.
