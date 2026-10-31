/// UI-independent API for nshare v2. No Flutter or terminal dependencies.
library;

export 'src/core/models.dart';
export 'src/discovery/discovery.dart';
export 'src/discovery/interfaces.dart';
export 'src/identity/identity.dart' show DeviceIdentity, TrustStore;
export 'src/transfer/transfer.dart';
export 'src/core/task.dart';

export 'src/application/state.dart';
export 'src/storage/paged_manifest.dart'
    show PagedManifest, collectTransferManifest;
export 'src/application/pairing.dart';
export 'src/application/sharing.dart';
export 'src/application/queue.dart';
export 'src/discovery/mdns.dart' show discoverNearby, watchNearby;
export 'src/application/service.dart';
export 'src/application/paths.dart';
