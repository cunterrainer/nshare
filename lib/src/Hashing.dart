import "package:crypto/crypto.dart";

class DigestAccumulator implements Sink<Digest>
{
  final List<Digest> events = [];

  @override
  void add(Digest data)
  {
    events.add(data);
  }

  @override
  void close() {}
}
