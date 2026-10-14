# Tincan

Peer-to-peer chat with no accounts and no server. You are a
copy-pasteable address; traffic is end-to-end WireGuard, direct when NAT
traversal works and relayed through DERP when it doesn't.

- Text, emoji, images and video.
- First contact is a request you accept or refuse for good. Refusals are
  undoable, and pending requests collapse to one line so they can't be
  used to flood you.
- Profiles (nickname, status, description, picture) reach connected
  peers as you change them. Share yours as a `tincan:` blob, a QR
  code, or a `.vcf` contact.
- Regenerate your address to cut off everyone holding the old one.
- Back up and restore the account and the chat history for a new device.

This repo is the Flutter app; the transport lives in subdirectories:

- `lib/`, `linux/`, `android/`, … — the Flutter app (Linux first).
- `gobridge/` — Go bridge: `bridge/` is the chat layer over
  [tailcat](https://github.com/tailscale/tailcat) (framed CBOR messages
  + binary file chunks over one tunnel TCP stream, JSON event queue,
  request gating and the accepted/blocked roster); `cshared/` exports
  it as a C library for Dart FFI.
- `tailcat/` — checkout of the upstream transport library (`replace`d
  into gobridge). It is not vendored here; clone it beside the app:
  `git clone https://github.com/tailscale/tailcat`
- `brand/` — logos and the palette. `brand/generate-icons.sh`
  regenerates the app icons and in-app assets from `logo-color.svg`
  (needs rsvg-convert and ImageMagick).
- `design/` — the design canvas sources ("Warm den" direction),
  published at https://claude.ai/code/artifact/edd72066-526f-4152-8f08-507088cff9c4

The application id is `com.aukmind.tincan` on every platform.

Privacy policy: [PRIVACY.md](PRIVACY.md).

## Licence

BSD 3-Clause; see [LICENSE](LICENSE). Third-party notices, including
Tailscale's for the transport, are in [NOTICE](NOTICE).

## Brand

Teal `#137C7A` is the identity, orange `#F08B3E` the accent that has to
catch the eye (unread badges, the peer's ring in the logo), navy `#1E2433` the dark
surfaces. Connection-state colours are deliberately outside the brand:
green and amber mean something and must not read as chrome.

## Build & run (Linux)

```sh
gobridge/build.sh          # builds libtincan_bridge.so (needs Go + cgo)
flutter run -d linux       # or: flutter build linux
```

The Linux bundle picks up the `.so` automatically (CMake install step);
`TINCAN_BRIDGE=<path>` overrides the library location for dev runs.

To run two instances on one machine (two identities):

```sh
TINCAN_HOME=/tmp/tc-b TINCAN_NAME=bob ./build/linux/x64/release/bundle/tincan
```

## Build & run (Android)

```sh
gobridge/build-android.sh          # cross-compiles the bridge into android/app/src/main/jniLibs/ (needs the NDK)
flutter build apk --split-per-abi  # or: flutter run, with a device attached
```

One build covers Android 9 (minSdk 28) through current; the UI switches
to single-pane phone navigation below 700px.

Background receiving is a setting (the gear in the sidebar): **Never**,
or **for up to an hour after leaving the app** (15 minutes by default).
It runs a foreground service with a quiet ongoing notification, which is
the only way Android keeps a process alive, and does no work of its own
beyond holding the connection the transport already has. The service is
declared as `remoteMessaging`, Android's type for relaying messages
between devices; the hour cap bounds the battery cost.

The same settings page takes a relay of your own, by hostname or by
relay-map URL, instead of the default Tailscale-run relays. Changing it
restarts the transport and changes your address.

Live camera QR scanning works on Android/iOS; desktop reads a QR from
an image file instead (no camera plugin there).

### Release builds

Release signing reads `android/key.properties`, which is not in the
repo. Without it Gradle falls back to the debug key, which Play rejects:

```sh
keytool -genkey -v -keystore ~/tincan-upload.jks -keyalg RSA \
        -keysize 2048 -validity 10000 -alias upload
cat > android/key.properties <<EOF
storeFile=$HOME/tincan-upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
EOF
flutter build appbundle   # Play wants an .aab, not the split APKs
```

Keep that keystore backed up: with Play App Signing it is the upload
key, and losing it means asking Google to reset it.

Machine note: this box exports the deprecated `ANDROID_SDK_HOME`
pointing at the SDK, which the Android Gradle plugin rejects (it means
"preferences folder" to AGP). Until that export is removed from the
shell profile, build with:

```sh
env -u ANDROID_SDK_HOME ANDROID_USER_HOME=$HOME/.android-user flutter build apk --split-per-abi
```

## Tests

```sh
(cd gobridge && go test ./bridge/)   # incl. offline e2e over an in-process DERP
flutter test                         # state machine, profile blobs, QR roundtrip
dart run tool/e2e_smoke.dart         # full FFI stack over real DERP (needs network)
```

## State

Everything lives under the app support dir (or `$TINCAN_HOME`):
`state/identity.json` (transport key + pinned DERP region — delete for
a fresh identity, or use "Generate a new address" in the app),
`state/peers.json` (accepted/blocked roster), `state/profile.json` and
`state/avatar.img` (profile), `state/avatars/` (peers' pictures),
`state/chats.json` (message history), `media/` (received files).

## Notes

- Desktop "QR scanning" reads a QR from an image file (no Linux camera
  plugin exists); live camera scanning arrives with the mobile builds.
- "Save contact" writes a vCard (`.vcf`) with the address embedded,
  importable into Google Contacts, Samsung Contacts, iOS Contacts, etc.
