# Niles — Draft App Store Metadata

Ready to paste into App Store Connect. Placeholders are marked `<<...>>`. Drafted November 17, 2026.

## Name

Niles

## Subtitle (30 characters max)

Apple Home, on your approval

*(29 characters.)*

## Keywords (100 characters max, comma-separated, no spaces)

`homekit,home,assistant,agent,scenes,accessories,automations,smart,queue,approval,local,mcp`

*(Counts 92 characters. Do not include "Niles" — the app name is already indexed.)*

## Category

- **Primary:** Utilities
- **Secondary:** Lifestyle

## Description

Niles is the safe way to let tools and agents work with your Apple Home. It reads your homes, rooms, accessories, scenes, and automations through Apple's HomeKit framework, and every change a paired agent suggests lands in Niles as a proposal that you approve or deny yourself. Nothing ever changes in your home without your tap.

**How it works**

1. Run your automation agent on any device on your home Wi-Fi.
2. Pair it once with the six-digit code shown in Niles. Each agent gets its own access token, stored in your Keychain and revocable any time.
3. Your agent reads your home's current state and stages proposed changes.
4. You review each proposal in Niles — exactly what will change, on which accessory — and approve or deny it.
5. Approved changes execute and Niles records read-back evidence: the value your accessory reports afterward, in the Activity timeline.

**Built for deliberateness**

- Proposals expire after 24 hours, so stale suggestions never pile up.
- Automations are always staged disabled and require a separate approval to arm.
- Bulk changes are approved one card at a time, so you always know what you agreed to.
- Whole-home deletion is not supported — Niles cannot wipe your home even if an agent asks.

**Private by construction**

Niles has no accounts, no sign-in, and no analytics. It sends nothing to any server — its only network traffic is the local connection between Niles and the agents you paired, on your own Wi-Fi. Your home data, pairing tokens, proposals, and evidence all stay on your device.

Niles requires iOS 17. Local serving needs the Local Network permission, and your agent must be on the same Wi-Fi network.

## What's New (first release)

Initial release.

## App Privacy (Data Not Collected)

Answer **"No"** to: does the app collect data from this app? All data types remain unset — the app collects nothing off-device. Revisit only if that ever changes; per Apple's App Privacy documentation, on-device-only data with no off-device transmission is not "collected."

## Age Rating questionnaire

- Violence: None. Cartoons/Realistic: None.
- Sexual content: None.
- Profanity: None.
- Gambling: None.
- Alcohol/tobacco/drugs: None.
- Medical information: None.
- Unrestricted web access: **No** (no web browser in the app).
- **User-generated content:** No sharing, and no user-to-user interaction — proposed changes come from agents the user paired on their own network. Answer "No" to UGC sharing/exposure questions; guideline 1.2 moderation machinery is not applicable to a self-contained tool with no sharing surface.
- **Chat:** **No** — no chat features of any kind in the app.

## Support URL

`<<https://<final host>/niles/support — placeholder; the privacy policy page hosted by the project serves here, with the policy at /niles/privacy>>`

Per guideline 5.1.1(i), the privacy policy URL is required in App Store Connect even for a Data-Not-Collected app. Set both:
- **Privacy Policy URL:** `<<...>>/niles/privacy`
- **Support URL:** `<<...>>/niles/support`

## Copyright

© 2026 Matthew Gerstman

## Screenshots to upload

See the "Niles screenshot - ..." files in the project: 6.9-inch (iPhone 17 Pro Max, 1320×2868), 6.7-inch (iPhone 15 Pro Max, 1290×2796), and a compact 4.7-inch capture (iPhone SE, 750×1334) for the narrow-width check. Captured from the shipping build on the iOS Simulator using the app's built-in sample-data fixtures (launch flags `-UIHomeFixtures`, `-UIActivityFixtures`, `-UIServingConsent approved`, `-UISeedQueue`).
