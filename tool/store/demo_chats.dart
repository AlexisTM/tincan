// Demo people, chats and photos for the store screens.
import 'dart:math';

import 'package:image/image.dart' as img;

/// A photo-like picture: a sky gradient, a sun and layered hills.
List<int> demoPhoto(int seed, List<int> sky, List<int> ground, {int w = 1200, int h = 900}) {
  final rnd = Random(seed);
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(
        x,
        y,
        (sky[0] + (255 - sky[0]) * t * .7).round(),
        (sky[1] + (230 - sky[1]) * t * .7).round(),
        (sky[2] + (200 - sky[2]) * t * .7).round(),
      );
    }
  }
  img.fillCircle(image,
      x: w * 2 ~/ 3, y: h * 2 ~/ 5, radius: h ~/ 7, color: img.ColorRgba8(255, 236, 190, 230), antialias: true);
  for (var layer = 0; layer < 4; layer++) {
    final base = h * (.55 + layer * .1);
    final amp = h * (.08 - layer * .012);
    final phase = rnd.nextDouble() * pi * 2;
    final k = .6 + layer * .25;
    final shade = 1 - layer * .22;
    final c = img.ColorRgb8(
      (ground[0] * shade).round(),
      (ground[1] * shade).round(),
      (ground[2] * shade).round(),
    );
    for (var x = 0; x < w; x++) {
      final top = (base + amp * sin(x / w * pi * 2 * k + phase)).round();
      img.drawLine(image, x1: x, y1: top, x2: x, y2: h - 1, color: c);
    }
  }
  return img.encodeJpg(image, quality: 88);
}

/// A round-friendly avatar: a soft two-tone gradient.
List<int> demoAvatar(List<int> a, List<int> b) {
  const s = 256;
  final image = img.Image(width: s, height: s);
  for (var y = 0; y < s; y++) {
    for (var x = 0; x < s; x++) {
      final t = (x + y) / (2 * s);
      image.setPixelRgb(
        x,
        y,
        (a[0] + (b[0] - a[0]) * t).round(),
        (a[1] + (b[1] - a[1]) * t).round(),
        (a[2] + (b[2] - a[2]) * t).round(),
      );
    }
  }
  img.fillCircle(image, x: s ~/ 2, y: s * 2 ~/ 5, radius: s ~/ 6, color: img.ColorRgba8(255, 255, 255, 210),
      antialias: true);
  img.fillCircle(image, x: s ~/ 2, y: s, radius: s * 2 ~/ 5, color: img.ColorRgba8(255, 255, 255, 210),
      antialias: true);
  return img.encodePng(image);
}

/// [minutesAgo] counts back from when the screens render.
typedef DemoLine = ({
  String id,
  bool out,
  int minutesAgo,
  String body,
  String? photo,
  String? reply,
  String? react,
});

DemoLine line(String id, bool out, int minutesAgo, String body,
        {String? photo, String? reply, String? react}) =>
    (id: id, out: out, minutesAgo: minutesAgo, body: body, photo: photo, reply: reply, react: react);

typedef DemoPeer = ({
  String id,
  String name,
  String status,
  String description,
  List<int>? avatar,
  bool direct,
  int latencyMs,
  bool online,
  bool verified,
  int unread,
  List<DemoLine> lines,
});

const selfName = 'Alex';
const selfStatus = 'Out hiking until Sunday';
const selfDescription = 'Coffee, trails and terrible puns.';

final demoPeers = <DemoPeer>[
  (
    id: 'nk:nia',
    name: 'Nia Okafor',
    status: 'Brewing something',
    description: 'Ceramics, film cameras, too many plants.',
    avatar: [240, 139, 62],
    direct: true,
    latencyMs: 14,
    online: true,
    verified: true,
    unread: 0,
    lines: [
      line('n1', false, 52, 'Are we still on for the lake this weekend? 🏞️'),
      line('n2', true, 50, 'Yes! Leaving Saturday at 8, I will bring the stove'),
      line('n3', false, 49, 'Perfect. I found the trail map', photo: 'trail'),
      line('n4', true, 31, 'That ridge looks unreal', reply: 'n3', react: '😍'),
      line('n5', false, 30, 'Bring layers, it gets cold up there'),
      line('n6', true, 12, 'Packed. See you at the bakery first ☕', react: '👍'),
      line('n7', false, 2, 'Deal. Last one there buys the croissants 🥐'),
    ],
  ),
  (
    id: 'nk:sam',
    name: 'Sam Kessler',
    status: 'On call',
    description: '',
    avatar: null,
    direct: false,
    latencyMs: 48,
    online: true,
    verified: false,
    unread: 2,
    lines: [
      line('s1', true, 190, 'Sent you the photos from Sunday'),
      line('s2', false, 22, 'These came out great', photo: 'sunset'),
      line('s3', false, 21, 'Printing this one for the hallway'),
    ],
  ),
  (
    id: 'nk:priya',
    name: 'Priya',
    status: '',
    description: '',
    avatar: [19, 124, 122],
    direct: true,
    latencyMs: 9,
    online: true,
    verified: true,
    unread: 0,
    lines: [
      line('p1', false, 300, 'Did the build pass on your machine?'),
      line('p2', true, 290, 'Green on mine, rebasing now'),
    ],
  ),
  (
    id: 'nk:tomas',
    name: 'Tomás',
    status: '',
    description: '',
    avatar: null,
    direct: false,
    latencyMs: 0,
    online: false,
    verified: false,
    unread: 0,
    lines: [
      line('t1', false, 60 * 26, 'Happy birthday!! 🎉'),
      line('t2', true, 60 * 25, 'Thank you! Dinner next week?'),
    ],
  ),
  (
    id: 'nk:mum',
    name: 'Mum',
    status: '',
    description: '',
    avatar: [130, 92, 160],
    direct: true,
    latencyMs: 22,
    online: false,
    verified: true,
    unread: 0,
    lines: [
      line('m1', false, 60 * 50, 'Call me when you land'),
      line('m2', true, 60 * 49, 'Landed, all good ❤️'),
    ],
  ),
];

const demoPhotos = {
  'trail': (seed: 4, sky: [120, 170, 214], ground: [62, 118, 92]),
  'sunset': (seed: 9, sky: [214, 112, 84], ground: [70, 52, 88]),
};
