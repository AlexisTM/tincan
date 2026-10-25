import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import 'images.dart';

/// Reads a QR code out of an image, or null if there isn't one.
///
/// The decoder is fussy about scale: full-resolution photos often fail
/// where a downscaled copy reads fine, so try a few sizes.
Future<String?> decodeQrFromImageFile(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    return await Isolate.run(() => _decodeBytes(bytes));
  } catch (_) {
    return null;
  }
}

String? _decodeBytes(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Garbage can sniff as TGA and claim absurd dimensions, truncated
    // files throw RangeError.
    return null;
  }
  return decoded == null ? null : decodeQrFromImage(decoded);
}

/// As [decodeQrFromImageFile], for an already-decoded image.
String? decodeQrFromImage(img.Image decoded) {
  // zxing ignores alpha, so transparent pixels would read as black.
  decoded = flattenOnWhite(decoded);
  // Full size last: it's the slowest pass and the likeliest to fail.
  for (final maxSide in const [1200, 800, 1600, 0]) {
    final candidate = maxSide == 0
        ? decoded
        : fitWithin(decoded, maxSide, interpolation: img.Interpolation.average);
    if (maxSide != 0 && identical(candidate, decoded)) continue; // too small to resize
    final text = _tryDecode(candidate);
    if (text != null) return text;
  }
  return null;
}

String? _tryDecode(img.Image image) {
  try {
    // Little-endian BGRA bytes read as ints are the ARGB zxing wants.
    final bytes = image
        .convert(format: img.Format.uint8, numChannels: 4)
        .getBytes(order: img.ChannelOrder.bgra);
    final pixels = Int32List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4);
    final source = RGBLuminanceSource(image.width, image.height, pixels);
    final result = QRCodeReader().decode(
      BinaryBitmap(HybridBinarizer(source)),
      hints: DecodeHints()..put(DecodeHintType.tryHarder),
    );
    return result.text;
  } catch (_) {
    // ReaderException when there's no code, ArgumentError and friends
    // when the detector locks onto something that isn't one.
    return null;
  }
}
