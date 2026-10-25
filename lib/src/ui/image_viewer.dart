import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../files.dart';
import 'toast.dart';

/// Full-screen, zoomable view of a decrypted image. Esc, the close
/// button or a vertical swipe at rest closes it.
Future<void> showImageViewer(BuildContext context, {required String path, required String name}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black87,
    barrierDismissible: true,
    barrierLabel: 'Close image',
    pageBuilder: (_, _, _) => ImageViewer(path: path, name: name),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
  ));
}

class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.path, required this.name});

  final String path;
  final String name;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final _zoom = TransformationController()..addListener(_zoomed);
  double _drag = 0;
  bool _atRest = true;

  // Swipe-to-close only at rest, so it never fights panning a zoomed image.
  void _zoomed() {
    final rest = _zoom.value.getMaxScaleOnAxis() <= 1.01;
    if (rest != _atRest) setState(() => _atRest = rest);
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _saveAs() async {
    final target = await chooseSaveTarget(widget.name, const [imageTypes]);
    if (target == null) return;
    final err = await target.write((dst) async {
      await File(widget.path).copy(dst);
      return null;
    });
    if (mounted) showToast(context, err == null ? 'Saved' : 'Couldn\'t save: $err');
  }

  Future<void> _openExternally() async {
    final err = await openExternal(widget.path);
    if (err != null && mounted) showToast(context, err);
  }

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFF4F5F7);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  onVerticalDragUpdate:
                      _atRest ? (d) => setState(() => _drag += d.delta.dy) : null,
                  onVerticalDragEnd: !_atRest ? null : (d) {
                    if (_drag.abs() > 120 || d.velocity.pixelsPerSecond.dy.abs() > 900) {
                      _close();
                    } else {
                      setState(() => _drag = 0);
                    }
                  },
                  child: Transform.translate(
                    offset: Offset(0, _drag),
                    child: InteractiveViewer(
                      transformationController: _zoom,
                      minScale: 1,
                      maxScale: 6,
                      child: Center(
                        child: Semantics(
                          image: true,
                          label: widget.name,
                          child: Image.file(File(widget.path),
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined,
                                  size: 48, color: ink)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(children: [
                    IconButton(
                      tooltip: 'Close',
                      onPressed: _close,
                      icon: const Icon(Icons.close, color: ink),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: ink, fontSize: 14)),
                    ),
                    IconButton(
                      tooltip: 'Open externally',
                      onPressed: _openExternally,
                      icon: const Icon(Icons.open_in_new, color: ink),
                    ),
                    IconButton(
                      tooltip: 'Save as…',
                      onPressed: _saveAs,
                      icon: const Icon(Icons.download_outlined, color: ink),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Opens a file with the platform's default handler; the error to
/// show, if it couldn't.
Future<String?> openExternal(String path) async {
  const failed = 'No app could open this file.';
  try {
    return (await OpenFilex.open(path)).type == ResultType.done ? null : failed;
  } catch (_) {
    return failed;
  }
}
