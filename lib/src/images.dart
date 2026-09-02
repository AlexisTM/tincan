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
  final decoded = img.decodeImage(File(source).readAsBytesSync());
  if (decoded == null) return 'That file doesn\'t look like an image.';
  File(target).writeAsBytesSync(img.encodeJpg(fitWithin(decoded, 192), quality: 85));
  return null;
}
