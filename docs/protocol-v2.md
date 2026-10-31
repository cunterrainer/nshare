# nshare LAN protocol v2

All connections use TLS. No upgrade from plaintext or automatic v1 fallback.
Frame header: ASCII `NSH2` (4 bytes), version `2` (u8), message ID (u8),
payload length (u32 big endian). Control payloads are UTF-8 JSON objects limited
to 256 KiB. DATA is at most 64 KiB plus its u64 big-endian file offset.
Message IDs are explicit; unknown IDs, oversized lengths, malformed metadata,
truncation and invalid ordering terminate the session.

IDs: HELLO=1 CHALLENGE=2 PROOF=3 READY=4 OFFER=10 ACCEPT=11 FILE_START=12
FILE_ACCEPT=13 DATA=14 FILE_END=15 FILE_ACK=16 COMPLETE=17 COMPLETE_ACK=18
CANCEL=20 ERROR=21. ERROR contains bounded code/message. EOF is never completion.

Authentication: receiver presents its self-signed TLS certificate. Sender pins
an out-of-band-verified SHA-256 DER certificate fingerprint. Inside that TLS
connection the sender sends its certificate and a random nonce (HELLO). Receiver
sends a fresh nonce (CHALLENGE); sender signs a domain-separated transcript
including both fingerprints and both nonces using RSA/SHA-256 (PROOF). Receiver
verifies proof and pins the sender after out-of-band approval, then sends READY.
No transfer metadata is sent before both peers approve. Deadlines: connection
10 seconds; transfer inactivity 60 seconds; human approval 5 minutes.

OFFER: deterministic manifest ID, entries (numeric ID, relative slash path,
kind=file|directory, size, SHA-256 for files). Receiver validates the complete
bounded manifest and requests user acceptance before ACCEPT. Maximum 1024 entries
and 256 KiB encoded control payload; larger offers fail with an explicit limit.
Manifest IDs bind the protocol version and ordered canonical entry metadata.

For each entry: FILE_START identifies transfer and entry. FILE_ACCEPT provides
resume offset and SHA-256 of retained prefix, or skip=true for the chosen conflict
policy. DATA offsets must be contiguous and remain within declared size.
FILE_END includes entry identity and full digest. Receiver checks count/digest,
closes and verifies staging, then finalizes and sends FILE_ACK. Sender checks each
ack. Finally COMPLETE / COMPLETE_ACK confirm the manifest ID and counts.
A failed transfer may have finalized earlier files; a transfer is not an atomic
folder transaction. Disconnect after finalization but before acknowledgment is
an uncertain result until reconnect resolves it.

Resume uses peer/manifest/destination-bound staging. Receiver rehashes retained
bytes and advertises only complete verified-size chunks. Sender rehashes its
prefix before continuing; stale/corrupt state is rejected and can be discarded.
Every completed file is rehashed before finalization. Completion receipts permit
idempotent retries after lost acknowledgments; receipts must be checked against
the current destination files before reuse.
