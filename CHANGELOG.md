## 2.0.0

- Rewrite the LAN transfer application as a UI-independent Dart core and CLI.
- Add standalone `--show-ip`, bounded discovery, device selection and trust tools.
- Replace v1 with TLS, verified certificate pairing and strict bounded v2 messages.
- Add SHA-256 verification, safe staged writes and receiver acknowledgments.
- Add verified resume, explicit conflict policies and idempotent completion retries.
- Add real socket/process tests and Linux/macOS/Windows CI.

Breaking: v1 peers and legacy CLI flags are unsupported. Use `send`, `receive`,
`devices`, and `trust`; no arguments now shows help. Requires Dart 3.8+.
