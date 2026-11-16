# Oh My OpenClaw

A native iOS chat client for your own OpenClaw Gateway, inspired by the calm, conversation-first interaction of Muse.
This is an independent client, without a hosted AI service or an embedded administration console.

The first version includes streaming replies with real tool activity, a main conversation and independent side chats, automatic titles supplied by the Gateway, Markdown and code copying, images and file attachments, on-device dictation, and per-conversation model and thinking choices.
Drafts and uncertain submissions stay on the device; credentials and the device identity use the iOS Keychain.
The built-in demo uses synthetic conversations and never contacts a Gateway or AI provider.

## Build and run

Requirements: Xcode 16 or newer with Swift 6, iOS 18 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open OhMyOpenClaw.xcodeproj
```

Select the `OhMyOpenClaw` scheme and an iPhone simulator, then run.
For a physical device, select your own development team in Signing & Capabilities.
The project specification is `project.yml`; the generated project is intentionally ignored.

Unsigned simulator build:

```sh
xcodebuild -project OhMyOpenClaw.xcodeproj -scheme OhMyOpenClaw \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Connect your Gateway

Use a `wss://` Gateway URL with a normally trusted TLS certificate, for example a Tailscale Serve endpoint.
Enter the Gateway's shared token or password, or scan/paste its setup code.
The first connection requests an operator device pairing; approve the exact request on the Gateway host, then choose **承認後に再接続**:

```sh
openclaw devices list
openclaw devices approve <requestId>
```

After approval, the app saves its own device token for reconnects.
It requests read, write, approvals, and questions scopes; no admin or device-management scope is requested.
QR bootstrap is used as operator authentication and may still need explicit approval; this app does not use the official node-first automatic mobile handoff.
Setup codes containing a TLS certificate fingerprint are rejected until certificate pinning is implemented. Use a system-trusted certificate instead of bypassing TLS validation.

The client targets protocol v4 and the contracts at OpenClaw source snapshot [`a8a7ce9`](https://github.com/openclaw/openclaw/tree/a8a7ce94eb544f3c39cf25f674471c3f1e3fe4ab), whose package version is `2026.11.4`.
That snapshot is a main-branch build, not a claim that every release with that version has the same methods or optional fields.
Older Gateway compatibility and a real self-hosted Gateway connection require validation before distributing a beta.

File ingestion is separate from model understanding: a Gateway can accept a PDF or archive while its selected model still needs tools to read it.
Attachment limits come from the connection policy and the total encoded request size; the app does not promise a fixed upload limit for every Gateway.

## Tests

```sh
swift test
```

The core suite covers device proof construction, safe endpoints and setup codes, conversation state, and a real loopback WebSocket exchange with the synthetic Python fixture.
That fixture proves client transport and framing behavior; it is not an OpenClaw instance or evidence of production connectivity.
The fixture binds only to `127.0.0.1`, needs Python 3's standard library, and uses synthetic credentials.

```sh
python3 scripts/gateway-fixture.py --port 9876
```

Use `ws://127.0.0.1:9876` only for local simulator development.
Remote unencrypted WebSocket endpoints, URL-embedded credentials, and credential query parameters are rejected.

## Beta distribution

TestFlight upload is a separate release step: configure an Apple Developer team, a unique App Store Connect app for the bundle ID, signing, a privacy policy, and beta review information.
No signing keys or App Store Connect credentials belong in this repository.
The demo gives reviewers a way to inspect the interface without access to a personal Gateway.

Before inviting testers, verify pairing and device-token reconnect against the intended Gateway build, real microphone recognition, camera QR scanning, and file/photo selection on a physical iPhone.
Simulator/demo checks do not establish those acceptance results.

Push notifications, node capabilities, feed/ideas/goals/library tabs, slash-command completion, and certificate pinning are outside this version.
When the app returns to the foreground it reconnects and reloads the selected conversation.

## Architecture

`Sources/OhMyOpenClawCore` owns the small actor-based WebSocket transport, device proofs, wire values, and durable conversation reducer.
`App` owns the SwiftUI interface, lifecycle, protected local storage, Keychain integration, and native input services.
The transport is app-owned because the official Swift package is nested in the OpenClaw monorepo and depends on its Node-based protocol generation; it cannot be added as a standalone URL dependency unchanged.

Adapted OpenClaw authentication code retains its upstream MIT notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
The app icon is original geometric artwork, reproducible with `swift scripts/generate-icon.swift`.
