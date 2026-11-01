import 'dart:convert';
import '../core/models.dart';
import '../identity/identity.dart';
import '../protocol/protocol.dart';
import 'pairing.dart';

const maxClipboardBytes = 64 * 1024;

class ClipboardOffer {
  const ClipboardOffer(this.peer, this.text, this.id);
  final PeerIdentity peer;
  final String text, id;
}

typedef ClipboardApproval = Future<bool> Function(ClipboardOffer offer);
void validateClipboardText(String text) {
  if (utf8.encode(text).length > maxClipboardBytes) {
    throw const NshareException('limit', 'Clipboard text exceeds 64 KiB');
  }
}

Future<void> shareText(
  String text,
  String host,
  int port,
  DeviceIdentity identity,
  TrustStore trust, {
  String? expectedFingerprint,
  PairingApproval? approvePeer,
  CancellationToken? cancellation,
}) async {
  validateClipboardText(text);
  final wire = await connectAuthenticated(
    host,
    port,
    identity,
    trust,
    expectedFingerprint: expectedFingerprint,
    approve: approvePeer,
    cancellation: cancellation,
  );
  try {
    wire.require('clipboard-v1');
    final id = randomNonce();
    await wire.send(WireType.clipboard, {
      'id': id,
      'text': text,
      'expires': DateTime.now()
          .add(const Duration(minutes: 2))
          .millisecondsSinceEpoch,
    });
    final ack = await wire.expect(
      WireType.clipboardAck,
      wait: const Duration(minutes: 5),
    );
    if (ack['id'] != id) {
      throw const NshareException(
        'protocol',
        'Invalid clipboard acknowledgment',
      );
    }
  } finally {
    await wire.close();
  }
}

Future<void> joinInvitation(
  PairingInvitation invite,
  DeviceIdentity identity,
  TrustStore trust, {
  CancellationToken? cancellation,
}) async {
  // An invitation must have come from a trusted display/copy channel.
  PairingInvitation.parse(invite.uri.toString());
  final wire = await connectAuthenticated(
    invite.host,
    invite.port,
    identity,
    trust,
    expectedFingerprint: invite.fingerprint,
    cancellation: cancellation,
  );
  try {
    wire.require('pair-v1');
    await wire.send(WireType.pair, {'token': invite.token});
    final ack = await wire.expect(
      WireType.pairAck,
      wait: const Duration(minutes: 5),
    );
    if (ack['token'] != invite.token) {
      throw const NshareException('protocol', 'Invalid pairing acknowledgment');
    }
  } finally {
    await wire.close();
  }
}

/// Pair without a camera or pre-shared fingerprint. Both screens must approve
/// the same session code; this is not a password and must never be auto-accepted.
Future<PeerIdentity> pairByCode(
  String host,
  int port,
  DeviceIdentity identity,
  TrustStore trust, {
  required PairingApproval approvePeer,
  CancellationToken? cancellation,
}) async {
  final wire = await connectAuthenticated(
    host,
    port,
    identity,
    trust,
    approve: approvePeer,
    cancellation: cancellation,
    requireConfirmationCode: true,
  );
  try {
    await wire.send(WireType.pair, {'confirmationCode': true});
    final ack = await wire.expect(WireType.pairAck);
    if (ack['confirmationCode'] != true) {
      throw const NshareException(
        'protocol',
        'Missing code pairing acknowledgment',
      );
    }
    return wire.remotePeer!;
  } finally {
    await wire.close();
  }
}
