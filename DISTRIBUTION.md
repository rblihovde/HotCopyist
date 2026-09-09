# Distributing HotCopyist

This document covers what it takes to ship HotCopyist to other Macs, and an
honest assessment of the Mac App Store.

## TL;DR

**HotCopyist cannot ship on the Mac App Store as currently designed.** The Mac
App Store requires the **App Sandbox**, and HotCopyist's core Finale feature
works by reading and rewriting Finale's private clipboard file at
`~/Library/Caches/com.makemusic.Finale27/…` — a path *outside* the sandbox
container that a sandboxed app is not permitted to touch. See "Mac App Store"
below for the full analysis.

**The right path for a utility like this is Developer ID + notarization**
(direct download, e.g. a DMG). This is how comparable clipboard/automation
tools ship. It supports everything HotCopyist does today and the Dorico feature
planned next.

---

## Prerequisites (both paths)

- An **Apple Developer Program** membership ($99/year). Required to get the
  signing certificates and to notarize.
- Xcode command line tools (`xcode-select --install`) for `codesign`,
  `notarytool`, and `stapler`.
- An **app icon** (`AppIcon.icns`). Not strictly required for notarization,
  but expected by users and *required* by the App Store. The Makefile already
  copies `Resources/AppIcon.icns` into the bundle if present, and Info.plist
  points `CFBundleIconFile` at `AppIcon`. (Ask and I'll generate a starter
  icon set.)

---

## Recommended: Developer ID + notarization (direct download)

Non-sandboxed, notarized, hardened-runtime app that users download and drag to
/Applications.

### 1. Get a Developer ID Application certificate

In Xcode → Settings → Accounts → Manage Certificates → "+" → **Developer ID
Application**, or from the Apple Developer website. Confirm it's installed:

```sh
security find-identity -v -p codesigning
# look for "Developer ID Application: Ryan Blihovde (TEAMID)"
```

### 2. Build and sign with hardened runtime

HotCopyist needs no special entitlements under Developer ID: it is not sandboxed,
so it has normal file access (Finale clip file), and auto-paste + global
hotkeys rely on the user-granted **Accessibility** permission (a TCC prompt),
not an entitlement. Outbound localhost (the coming Dorico feature) also needs
no entitlement when unsandboxed.

```sh
make app     # builds dist/HotCopyist.app (currently ad-hoc signed)

# Re-sign with your Developer ID and hardened runtime:
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Ryan Blihovde (TEAMID)" \
  dist/HotCopyist.app

codesign --verify --strict --verbose=2 dist/HotCopyist.app
```

If you later add capabilities that need them, create
`Resources/HotCopyist.entitlements` and pass `--entitlements` to codesign. None
are needed today.

### 3. Notarize

Store credentials once (use an app-specific password from appleid.apple.com,
or an App Store Connect API key):

```sh
# (profile name predates the HotCopy → HotCopyist rename; keep it)
xcrun notarytool store-credentials "HotCopy-notary" \
  --apple-id "rblihovde@gmail.com" --team-id "TEAMID"

# Zip the app for submission, submit, wait, then staple the ticket:
ditto -c -k --keepParent dist/HotCopyist.app dist/HotCopyist.zip
xcrun notarytool submit dist/HotCopyist.zip --keychain-profile "HotCopy-notary" --wait
xcrun stapler staple dist/HotCopyist.app
```

### 4. Package for download

A DMG is the usual delivery:

```sh
make dmg     # produces dist/HotCopyist-1.0.0.dmg from the (signed) app bundle
```

Notarize+staple the app *before* building the DMG so the ticket travels with
it. Gatekeeper on any Mac will then open it without warnings.

---

## Mac App Store: why it's blocked

The Mac App Store requires the **App Sandbox** entitlement
(`com.apple.security.app-sandbox`). Under the sandbox, an app can reach only:

- its own container,
- files the user explicitly picks (via an open panel → security-scoped
  bookmark),
- a handful of "temporary exception" entitlements.

HotCopyist's Finale integration reads and **rewrites** Finale's clipboard file at
`~/Library/Caches/com.makemusic.Finale27/Finale Temp Files …/EnigmaTemp…`.
That's inside *another app's* container in `~/Library/Caches`, which the
sandbox forbids. The available escapes don't hold up:

- **User-selected folder + bookmark**: the path lives under `~/Library/Caches`,
  which the open panel hides, and the folder name contains a per-session id
  that changes each launch — so the user couldn't reliably grant it, and
  Apple frowns on reaching into another app's container regardless.
- **`com.apple.security.temporary-exception.files.absolute-path.read-write`**:
  App Review routinely **rejects** absolute-path exceptions, especially ones
  pointing into another application's data.

On top of that, HotCopyist continuously reads the general pasteboard and
synthesizes ⌘V into other apps (auto-paste) — patterns that are normal for a
Developer-ID utility but out of step with App Store sandboxing expectations.

**Conclusion:** submitting to the App Store would require removing or crippling
the Finale feature that is the whole point of the app. If App Store presence is
a hard requirement, the realistic option is a *separate, reduced* build (e.g.
system-pasteboard clipboard manager only, no Finale/Dorico) — a different
product from this one. That build now exists: **HotCopy**, the sandboxed Mac
App Store edition (see the HotCopy2 project).

---

## Version bookkeeping

Bump these in `Resources/Info.plist` for each release:

- `CFBundleShortVersionString` — marketing version (e.g. `1.0.1`).
- `CFBundleVersion` — build number, must increase every upload.
