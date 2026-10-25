import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:tincan/src/profile.dart';
import 'package:tincan/src/qr_util.dart';

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

void main() {
  test('a rendered profile QR decodes back to the same blob', () async {
    const blob = 'tincan:eyJ2IjoxLCJuYW1lIjoibmlhIiwiYWRkciI6InRjWFlaIn0';

    // Rendered the way qr_flutter does, via the same `qr` package.
    final code = QrCode.fromData(data: blob, errorCorrectLevel: QrErrorCorrectLevel.M);
    final matrix = QrImage(code);
    const scale = 6, quiet = 4 * scale;
    final side = matrix.moduleCount * scale + 2 * quiet;
    final image = img.Image(width: side, height: side);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var r = 0; r < matrix.moduleCount; r++) {
      for (var c = 0; c < matrix.moduleCount; c++) {
        if (matrix.isDark(r, c)) {
          img.fillRect(image,
              x1: quiet + c * scale,
              y1: quiet + r * scale,
              x2: quiet + (c + 1) * scale - 1,
              y2: quiet + (r + 1) * scale - 1,
              color: img.ColorRgb8(0, 0, 0));
        }
      }
    }
    final path = '${_tempDir('tcqr').path}/qr.png';
    File(path).writeAsBytesSync(img.encodePng(image));

    final decoded = await decodeQrFromImageFile(path);
    expect(decoded, blob);
    expect(parseConnectInput(decoded!)!.token, 'tcXYZ');
  });

  test('a photo-like image without a QR returns null instead of throwing', () async {
    // Noise makes zxing latch onto false finder patterns and throw from
    // deep inside, which escaped as an unhandled exception on device.
    final rnd = Random(7);
    final noisy = img.Image(width: 900, height: 1600);
    for (var y = 0; y < noisy.height; y++) {
      for (var x = 0; x < noisy.width; x++) {
        final v = rnd.nextInt(256);
        noisy.setPixelRgb(x, y, v, v, v);
      }
    }
    // Blocky patches, closer to a real photo than pure noise.
    for (var i = 0; i < 60; i++) {
      img.fillRect(noisy,
          x1: rnd.nextInt(800), y1: rnd.nextInt(1500),
          x2: rnd.nextInt(900), y2: rnd.nextInt(1600),
          color: img.ColorRgb8(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)));
    }
    final path = '${_tempDir('tcnoqr').path}/noise.png';
    File(path).writeAsBytesSync(img.encodePng(noisy));

    expect(await decodeQrFromImageFile(path), isNull);
  });

  test('a non-image file returns null', () async {
    final path = '${_tempDir('tcnotimg').path}/x.png';
    File(path).writeAsStringSync('definitely not a png');
    expect(await decodeQrFromImageFile(path), isNull);
  });
}
