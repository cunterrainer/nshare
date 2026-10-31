## 3.0.0

- Add Flutter clients for Android, iOS, Windows, macOS and Linux with CLI parity.
- Add expiring QR/copy invitations, approved clipboard text and dual-stack discovery.
- Add disk-backed large-folder manifests, durable queue control and local service IPC.
- Add explicit opt-in compression and bounded transient-network retry backoff.
- Add native mobile folder adapters and platform receiver lifecycle controls.
- Add real CLI, Flutter-engine and desktop-window transfer validation.

Ordinary v2 file transfers remain compatible. New features require negotiated
extensions; compression and automatic clipboard replacement are not enabled by default.
Physical mobile runtime checks and production signing remain release gates.

## 2.0.0

- Rewrite the LAN transfer application as a UI-independent Dart core and CLI.
- Add standalone `--show-ip`, bounded discovery, device selection and trust tools.
- Replace v1 with TLS, verified certificate pairing and strict bounded v2 messages.
- Add SHA-256 verification, safe staged writes and receiver acknowledgments.
- Add verified resume, explicit conflict policies and idempotent completion retries.
- Add real socket/process tests and Linux/macOS/Windows CI.

Breaking: v1 peers and legacy CLI flags are unsupported. Use `send`, `receive`,
`devices`, and `trust`; no arguments now shows help. Requires Dart 3.8+.
