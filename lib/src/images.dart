import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

/// Scales image down so neither side exceeds maxSide; smaller ones pass
/// through untouched.
img.Image fitWithin(img.Image image, int maxSide,
    {img.Interpolation interpolation = img.Interpolation.nearest}) {
  if (image.width <= maxSide && image.height <= maxSide) return image;
  return img.copyResize(image,
      width: image.width >= image.height ? maxSide : null,
      height: image.height > image.width ? maxSide : null,
      interpolation: interpolation);
}

/// Downscales any image file into a profile picture at target, off the
/// UI isolate. Returns an error message, or null.
Future<String?> downscaleAvatar(String source, String target) =>
    Isolate.run(() => _downscaleAvatar(source, target));

String? _downscaleAvatar(String source, String target) {
  const notImage = 'That file doesn\'t look like an image.';
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(File(source).readAsBytesSync());
  } catch (_) {
    return notImage;
  }
  if (decoded == null) return notImage;
  final small = flattenOnWhite(fitWithin(decoded, 192));
  File(target).writeAsBytesSync(img.encodeJpg(small, quality: 85));
  return null;
}

/// Composites image onto white, so transparency doesn't turn black.
img.Image flattenOnWhite(img.Image image) {
  if (!image.hasAlpha) return image;
  final out = img.Image(width: image.width, height: image.height);
  img.fill(out, color: img.ColorRgb8(255, 255, 255));
  return img.compositeImage(out, image);
}
