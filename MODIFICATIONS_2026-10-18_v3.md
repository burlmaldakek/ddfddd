# Erosion follow-up changes — 2026-10-18 v3

- Hide Dialer Themer's `Get Current Keys` menu action only when `airliftUIAccessRequired()` is true (iOS 27 DB5+ Airlift compatibility mode). Keep the action on other configurations.
- Restore the intended Containers order: category segmented picker first, then the `Find a container` header and Search/Results section.
- Show `No output yet.` in Custom Passcode and Cards Override log panels when no log lines exist.
- Explicitly give Custom Passcode log text a full-width leading-aligned frame so imported theme status lines align to the left like regular logs.

Validation: all 81 Swift source files passed `swiftc -frontend -parse`. Full Xcode build/device runtime testing was not performed.
