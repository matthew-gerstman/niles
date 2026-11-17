# Niles — Notes for Review (App Store Connect)

Paste into **App Store Connect → App Review Information → Notes**. Replace every `<<...>>` placeholder before submitting. Drafted November 17, 2026 against App Review Guidelines as of October 16, 2026 (guideline citations per the pinned risk assessment).

---

Niles is a HomeKit companion app for people who want to inspect and change their Apple Home deliberately. It reads the homes configured on the device through Apple's HomeKit framework and lets the user review proposed changes — accessory settings, scenes, service groups, and automations — one at a time before anything is applied. Niles has no accounts, no sign-in, no analytics, and sends no data anywhere: everything it knows lives on the device, and its only network traffic is local-network traffic described below.

## The local server and how pairing works

Niles includes a small HTTP server that runs **only while the app is open in the foreground**. It lets automation tools on the same Wi-Fi network — an agent the user runs on their own hardware — read the current state of the user's home and submit suggested changes. The server is advertised over Bonjour as `_niles-mcp._tcp`. It listens on the local network only; it is not reachable from the internet, and the app itself makes no outbound requests to any server.

Before any agent can connect, two gates apply. First, iOS's standard Local Network permission prompt must be granted. Second, pairing requires a six-digit code shown in the app's pairing screen; the code is exchanged for a per-agent bearer token stored in the iOS Keychain. Each agent gets its own token, tokens are individually revocable in Settings, and revoking one cuts off that agent's access immediately. A paired agent can read home state and stage proposals; it **cannot** approve, execute, or modify anything directly.

## Proposal-only writes with human approval

Nothing in Niles changes the user's home without the user tapping Approve in the app. Incoming changes arrive as proposals, shown in the app's queue with exactly what will change. Each proposal expires after 24 hours. When the user approves, Niles applies the change and records read-back evidence (the value the accessory reports afterward) in the Activity timeline. Automations are always staged in a disabled state and require a second, separate approval to arm. Whole-home deletion is not supported.

## What to expect on a device with no HomeKit accessories

The review device does not need a HomeKit home or any accessories. Niles reads whatever homes exist on the device, and the app is fully usable with an empty home:

- On first launch, the app asks one question — whether to allow local serving — and saves the answer. Either answer (or skipping) leaves the app usable; serving can be toggled later in Settings.
- The main screen shows the home overview and staged-changes queue. With an empty home it shows the app's empty states rather than an error.
- The pairing screen is functional: it generates and displays a six-digit pairing code and shows paired agents and their status.

## How to reach each surface

- **Home overview and queue:** the app opens here. Sections for each room/accessory and the staged-changes queue appear in one scrollable list on phones.
- **Proposal detail:** tap any row in the queue to see the proposed change; tap the evidence area to see read-back results for executed proposals.
- **Activity:** on iPhone, scroll to the Activity section at the bottom of the main screen; on iPad or landscape the Activity pane sits beside Home.
- **Pairing screen and server settings:** open Settings from the toolbar, where the six-digit pairing code and paired agents are shown.

## Demo

A demo video recorded against a real home (read → stage → approve → execute with evidence) is available here:

**Demo video: `<<PASTE LINK — e.g. an App Store Connect-linked URL or a public unlisted link>>`**

The screenshots included with this submission were captured from the shipping build running on the iOS Simulator with the app's built-in sample data fixtures, clearly representing the app in use.

## Security summary

Pairing is gated by a six-digit code entered only in the app; the code never leaves the device. Every paired agent holds a unique bearer token stored in the iOS Keychain, used only for requests from the local network, and revocable in Settings at any time. Write operations are staged as proposals, require explicit in-app approval, expire after 24 hours, and execute forward-only with per-write read-back evidence recorded on-device. No home data ever leaves the device or the local network.

## Other review facts

- **Privacy:** the App Privacy section is answered "Data Not Collected." A `PrivacyInfo.xcprivacy` manifest is included. The app contains no analytics, tracking, or third-party data collection, and no chat or content-sharing features.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `NO`; the app uses only OS-provided encryption (Keychain and Apple networking APIs) and contains no third-party cryptography.
- **Sign-in:** the app has no accounts and no login; guideline 5.1.1(v) applies.
- **AI features:** none. Niles has no chat, no generative AI, and no content-sharing surfaces.
- **Support:** `<<SUPPORT URL — the hosted privacy/support page URL>>` (policy page reachable from this URL).
- **Contact:** Matthew Gerstman — mattgerstman@gmail.com.
