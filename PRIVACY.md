# Tincan privacy policy

Last updated: 2 September 2026

Tincan is built so this stays basically empty. This is a pure peer to
peer messaging. In an ideal scenario, with no relay. In complex network,
it will go through Tailscale public DERP servers (like tailcat) or use 
your own DERP server if speficied.

The data is encrypted end to end.

This policy describes what the app does. Where it says "we", that means
Aukmind, who publish Tincan.

## What we collect

Nothing.

We operate no server, no account and no analytics. This is why the chat
is only accessible if both parts are connected. We also have no advertising
no tracking and no crash reporting.

## What stays on your device

- **Your identity.** A key pair generated on the device the first time
  you open the app. It is your address. Nobody issues it and nobody can
  look it up; you share it, or you don't.
- **Your profile.** Nickname, status, description and picture, if you
  set them.
- **Your conversations.** Messages, and the photos and videos you send
  or receive.
- **Your contacts.** The peers you accepted or blocked.

All of it is encrypted on the device with a key held nowhere else. On
first launch you choose what unlocks that key: your device's biometrics
or screen lock, a password only you know, or no lock at all. A password
cannot be recovered — forgetting it means losing the messages, because
there is no server holding a copy. With no lock, the key is still kept
in your device's keystore rather than beside the files, so a copy of the
storage cannot be read, but anyone who can open the device can.

Filenames are the exception: the name of a file someone sends you stays
readable on disk even though its contents do not. Everything is removed
when you uninstall.

While the app is open, decrypted copies of pictures and videos you view
are written to a cache so they can be displayed. That cache is wiped
every time the app starts.

The backups you can export are plain files under your control. **The
account backup contains your private key**: anyone holding it can be
you. Keep it as carefully as a password.

## What leaves your device

**Messages and media** go to the peer you are talking to, encrypted end
to end with WireGuard. Tincan prefers a direct connection between the
two devices. When a network blocks that, the encrypted traffic is
relayed instead.

**Relays** carry ciphertext they cannot read. A relay does see the
things any network intermediary sees: your IP address, the size and
timing of traffic, and the fact that two addresses are talking. By
default Tincan uses relays operated by Tailscale under their own
terms. You can point the app at a relay you run yourself, in Settings.

**Relay discovery.** On first launch the app fetches the list of default
relays over HTTPS, which reveals your IP address to whoever serves that
list. Setting your own relay avoids this request entirely.

**Your profile** is sent to peers you are connected to, so they see the
name, status, description and picture you chose. Nothing else about you
is transmitted.

Tincan makes no other network requests. Fonts and images are bundled
in the app rather than fetched.

## Who you talk to

Anyone who has your address can send you a chat request. You accept or
refuse it, and a refusal is permanent until you undo it. Blocked peers
are dropped silently; to them your device looks offline.

If you want to be unreachable at an address you have shared, generate a
new one. The old address stops working immediately and for good.

## Permissions

- **Internet** — to reach your peers.
- **Camera** — only while you are scanning a peer's QR code. No image is
  stored or transmitted.
- **Notifications and background service** — only if you turn on
  background receiving, and only to keep the connection alive for the
  time you chose, at most an hour.

We do not have, and cannot obtain, a way to read your messages. There is
no key escrow and no recovery: that is a deliberate trade, and it is why
losing a password loses the data.

Photos and videos you send are chosen through your system's file picker,
so the app never gets access to your library.

## Children

Tincan is not directed at children under 13.

## Changes

If this policy changes, the updated version will be published with the
app and dated at the top.

## Contact

privacy@aukmind.com
