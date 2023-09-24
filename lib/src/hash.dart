// ignore_for_file: type=lint
library Hash;
import "dart:core";
import "dart:typed_data";

class _Util
{
  static int RightRotate32(int n, int c) => (n >> c) | (n << 32 - c);
  static bool IsLittleEndian() => Endian.host == Endian.little;

  static int SwapEndian(int value)
  {
    // Extract individual bytes from the 32-bit integer
    final int byte1 = (value >> 24) & 0xFF;
    final int byte2 = (value >> 16) & 0xFF;
    final int byte3 = (value >> 8) & 0xFF;
    final int byte4 = value & 0xFF;

    return (byte4 << 24) | (byte3 << 16) | (byte2 << 8) | byte1;
  }

  static int SwapEndian64(int value)
  {
    // Extract individual bytes from the 64-bit integer
    final int byte1 = (value >> 56) & 0xFF;
    final int byte2 = (value >> 48) & 0xFF;
    final int byte3 = (value >> 40) & 0xFF;
    final int byte4 = (value >> 32) & 0xFF;
    final int byte5 = (value >> 24) & 0xFF;
    final int byte6 = (value >> 16) & 0xFF;
    final int byte7 = (value >> 8) & 0xFF;
    final int byte8 = value & 0xFF;

    return (byte8 << 56) | (byte7 << 48) | (byte6 << 40) | (byte5 << 32) | (byte4 << 24) | (byte3 << 16) | (byte2 << 8) | byte1;
  }
}

class Sha256
{
  int _Bitlen = 0;
  int _BufferSize = 0;
  Uint8List _Buffer = Uint8List(64);

  Uint32List _a = Uint32List(1);
  Uint32List _b = Uint32List(1);
  Uint32List _c = Uint32List(1);
  Uint32List _d = Uint32List(1);
  Uint32List _e = Uint32List(1);
  Uint32List _f = Uint32List(1);
  Uint32List _g = Uint32List(1);
  Uint32List _h = Uint32List(1);

  Uint32List w = Uint32List(64);

  // FracPartsSquareRoots
  final Uint32List _H = Uint32List.fromList([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19]);

  // FracPartsCubeRoots
  static final Uint32List _sK = Uint32List.fromList([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);


  void _Compress()
  {
    _a[0] = _H[0];
    _b[0] = _H[1];
    _c[0] = _H[2];
    _d[0] = _H[3];
    _e[0] = _H[4];
    _f[0] = _H[5];
    _g[0] = _H[6];
    _h[0] = _H[7];

    for (int i = 0; i < 64; ++i)
    {
      final int s1 = _Util.RightRotate32(_e[0], 6) ^ _Util.RightRotate32(_e[0], 11) ^ _Util.RightRotate32(_e[0], 25);
      final int ch = (_e[0] & _f[0]) ^ (~_e[0] & _g[0]);
      final int temp1 = _h[0] + s1 + ch + _sK[i] + w[i];
      final int s0 = _Util.RightRotate32(_a[0], 2) ^ _Util.RightRotate32(_a[0], 13) ^ _Util.RightRotate32(_a[0], 22);
      final int maj = (_a[0] & _b[0]) ^ (_a[0] & _c[0]) ^ (_b[0] & _c[0]);
      final int temp2 = s0 + maj;
      _h[0] = _g[0];
      _g[0] = _f[0];
      _f[0] = _e[0];
      _e[0] = _d[0] + temp1;
      _d[0] = _c[0];
      _c[0] = _b[0];
      _b[0] = _a[0];
      _a[0] = temp1 + temp2;
    }

    _H[0] += _a[0];
    _H[1] += _b[0];
    _H[2] += _c[0];
    _H[3] += _d[0];
    _H[4] += _e[0];
    _H[5] += _f[0];
    _H[6] += _g[0];
    _H[7] += _h[0];
  }

  void _Transform()
  {
    for (int i = 0; i < 16; i += 4)
    {
      Uint8List c = Uint8List.view(w.buffer, i * 4, 16);
      c[0] = _Buffer[4 * i];
      c[1] = _Buffer[4 * i + 1];
      c[2] = _Buffer[4 * i + 2];
      c[3] = _Buffer[4 * i + 3];
      w[i] = _Util.IsLittleEndian() ? _Util.SwapEndian(w[i]) : w[i];

      c[4] = _Buffer[4 * (i+1)];
      c[5] = _Buffer[4 * (i+1) + 1];
      c[6] = _Buffer[4 * (i+1) + 2];
      c[7] = _Buffer[4 * (i+1) + 3];
      w[i+1] = _Util.IsLittleEndian() ? _Util.SwapEndian(w[i+1]) : w[i+1];

      c[8] = _Buffer[4 * (i+2)];
      c[9] = _Buffer[4 * (i+2) + 1];
      c[10] = _Buffer[4 * (i+2) + 2];
      c[11] = _Buffer[4 * (i+2) + 3];
      w[i+2] = _Util.IsLittleEndian() ? _Util.SwapEndian(w[i+2]) : w[i+2];

      c[12] = _Buffer[4 * (i+3)];
      c[13] = _Buffer[4 * (i+3) + 1];
      c[14] = _Buffer[4 * (i+3) + 2];
      c[15] = _Buffer[4 * (i+3) + 3];
      w[i+3] = _Util.IsLittleEndian() ? _Util.SwapEndian(w[i+3]) : w[i+3];
    }


    for (int i = 16; i < 64; i += 4)
    {
      int s0 = _Util.RightRotate32(w[i - 15], 7) ^ _Util.RightRotate32(w[i - 15], 18) ^ (w[i - 15] >> 3);
      int s1 = _Util.RightRotate32(w[i - 2], 17) ^ _Util.RightRotate32(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;

      s0 = _Util.RightRotate32(w[i+1 - 15], 7) ^ _Util.RightRotate32(w[i+1 - 15], 18) ^ (w[i+1 - 15] >> 3);
      s1 = _Util.RightRotate32(w[i+1 - 2], 17) ^ _Util.RightRotate32(w[i+1 - 2], 19) ^ (w[i+1 - 2] >> 10);
      w[i+1] = w[i+1 - 16] + s0 + w[i+1 - 7] + s1;

      s0 = _Util.RightRotate32(w[i+2 - 15], 7) ^ _Util.RightRotate32(w[i+2 - 15], 18) ^ (w[i+2 - 15] >> 3);
      s1 = _Util.RightRotate32(w[i+2 - 2], 17) ^ _Util.RightRotate32(w[i+2 - 2], 19) ^ (w[i+2 - 2] >> 10);
      w[i+2] = w[i+2 - 16] + s0 + w[i+2 - 7] + s1;

      s0 = _Util.RightRotate32(w[i+3 - 15], 7) ^ _Util.RightRotate32(w[i+3 - 15], 18) ^ (w[i+3 - 15] >> 3);
      s1 = _Util.RightRotate32(w[i+3 - 2], 17) ^ _Util.RightRotate32(w[i+3 - 2], 19) ^ (w[i+3 - 2] >> 10);
      w[i+3] = w[i+3 - 16] + s0 + w[i+3 - 7] + s1;
    }

    _Compress();
  }

  void UpdateBinary(Uint8List data, int size)
  {
    for (int i = 0; i < size; ++i)
    {
      _Buffer[_BufferSize++] = data[i];
      if (_BufferSize == 64)
      {
        _Transform();
        _BufferSize = 0;
        _Bitlen += 512;
      }
    }
  }

  void Update(Uint8List data) => UpdateBinary(data, data.length);
  void UpdateString(String str) => Update(Uint8List.fromList(str.codeUnits));

  void Finalize()
  {
    int start = _BufferSize;
    int end = _BufferSize < 56 ? 56 : 64;

    _Buffer[start++] = 0x80;
    _Buffer.fillRange(start, end, 0);

    if (_BufferSize >= 56)
    {
      _Transform();
      _Buffer.fillRange(0, 56, 0);
    }

    _Bitlen += _BufferSize * 8;
    Uint64List size = Uint64List.view(_Buffer.buffer, 64-8, 1);
    size[0] = _Util.IsLittleEndian() ? _Util.SwapEndian64(Uint64List.fromList([_Bitlen])[0]) : Uint64List.fromList([_Bitlen])[0];
    _Transform();
  }

  String Hexdigest()
  {
    StringBuffer buffer = StringBuffer();
    for (int h in _H)
    {
      String hexString = h.toRadixString(16).padLeft(8, '0');
      buffer.write(hexString);
    }
    return buffer.toString();
  }

  void Reset()
  {
    _Bitlen = 0;
    _BufferSize = 0;
    _H[0] = 0x6a09e667;
    _H[1] = 0xbb67ae85;
    _H[2] = 0x3c6ef372;
    _H[3] = 0xa54ff53a;
    _H[4] = 0x510e527f;
    _H[5] = 0x9b05688c;
    _H[6] = 0x1f83d9ab;
    _H[7] = 0x5be0cd19;
  }
}

String sha256(String str)
{
  Sha256 s = Sha256();
  s.UpdateString(str);
  s.Finalize();
  return s.Hexdigest();
}