# nshare application extensions v3

The TLS identity handshake and NSH2/version-2 bounded envelope are retained for
v2 file interoperability. HELLO and READY optionally carry `extensions`, a list
of up to 16 unique names (each <=64 characters). Missing list means v2. The
connection's capabilities are the intersection. Authentication errors never
trigger a fallback. A requested unsupported feature fails before its payload.

Capabilities: `manifest-pages-v1`, `block-gzip-v1`, `clipboard-v1`, `pair-v1`.
New IDs: MANIFEST_BEGIN=30, MANIFEST_PAGE=31, MANIFEST_END=32,
COMPRESSED_DATA=33, CLIPBOARD=34, CLIPBOARD_ACK=35, PAIR=36, PAIR_ACK=37.
All new control frames retain the 256 KiB bound. Compressed data has an 8-byte
logical offset, 4-byte original length and a gzip block, bounded by 64 KiB + 12.
Ordinary DATA frames remain valid for blocks that do not shrink. Each gzip block
is independent. Inflate stops at 64 KiB; declared length must match decoded
length. Resume offsets, hashes and file sizes always refer to original bytes.
Receiver compression acceptance is off unless explicitly enabled.

Paged manifests begin with transfer ID, entry count, file count and total bytes.
Each PAGE contains consecutive entries. END repeats the manifest ID. ID is SHA-256
of UTF-8 `nshare-manifest-v3\n` followed by canonical entry JSON and newline for
each entry. The receiver validates totals, digest, paths and all collisions before
asking for offer approval. Maximum 1,000,000 entries and 512 MiB metadata on disk;
frames remain independently bounded. A peer cannot interleave file data with
manifest pages. Verified file and final acknowledgments retain v2 semantics.

CLIPBOARD carries one UTF-8 text offer (<=64 KiB), UUID/nonce and expiry. Receiver
must explicitly approve it; identity trust alone does not approve clipboard
replacement. ACK binds the offer ID. Content is excluded from ordinary logs.

PAIR carries a short-lived invitation token after mutual identity authentication.
The invitation is transferred through a trusted QR/display/copy channel and pins
the receiver's full fingerprint. Receiver still explicitly approves the sender's
full fingerprint. Tokens are consumed atomically, expire in at most ten minutes,
and are never identities or automatic transfer-approval credentials. PAIR_ACK
binds the token. A code used to find an endpoint is not an authentication secret;
camera-free flow uses the same full invitation or fingerprint verification.

QR payload: `nshare://pair?v=3&host=...&port=...&fp=...&token=...&expires=...`.
No private key or clipboard content is included. Invitation parsing rejects
unknown versions, duplicate fields, invalid pins, ports, expiry and oversized
inputs. No Internet rendezvous or relay exists.
