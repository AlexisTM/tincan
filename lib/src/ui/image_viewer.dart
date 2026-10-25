import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../files.dart';
import 'toast.dart';

/// Full-screen, zoomable view of a decrypted image. Esc, the close
/// button, a tap beside the image or a vertical swipe at rest closes it.
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
  final _scaffold = GlobalKey();
  double _drag = 0;
  bool _atRest = true;
  bool _swiping = false;
  int _pointers = 0;
  // A second finger at any point makes the touch a pinch until all lift.
  bool _multi = false;

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

  void _toast(String message) {
    final ctx = _scaffold.currentContext;
    if (ctx != null) showToast(ctx, message);
  }

  void _pointerDown(PointerDownEvent _) {
    if (++_pointers > 1) {
      _multi = true;
      _stopSwipe();
    }
  }

  void _pointerUp(PointerEvent _) {
    if (--_pointers <= 0) {
      _pointers = 0;
      _multi = false;
    }
  }

  void _stopSwipe() {
    _swiping = false;
    if (_drag != 0) setState(() => _drag = 0);
  }

  void _swipeStart(ScaleStartDetails d) => _swiping = _atRest && !_multi && d.pointerCount == 1;

  void _swipeUpdate(ScaleUpdateDetails d) {
    if (!_swiping) return;
    if (d.pointerCount > 1 || !_atRest) return _stopSwipe();
    setState(() => _drag += d.focalPointDelta.dy);
  }

  void _swipeEnd(ScaleEndDetails d) {
    if (!_swiping) return;
    // Still touching: another finger came down, not a release.
    if (d.pointerCount > 0) return _stopSwipe();
    _swiping = false;
    if (_drag.abs() > 120 || d.velocity.pixelsPerSecond.dy.abs() > 900) {
      _close();
    } else {
      setState(() => _drag = 0);
    }
  }

  /// The cache wipe may have deleted the copy while the viewer stayed open.
  Future<bool> _stillThere() async {
    if (await File(widget.path).exists()) return true;
    _toast('This image was cleared from the cache. Close and reopen it.');
    return false;
  }

  Future<void> _saveAs() async {
    if (!await _stillThere()) return;
    final target = await chooseSaveTarget(widget.name, const [imageTypes]);
    if (target == null) return;
    final err = await target.write((dst) async {
      await File(widget.path).copy(dst);
      return null;
    });
    if (mounted) _toast(err == null ? 'Saved' : 'Couldn\'t save: $err');
  }

  Future<void> _openExternally() async {
    if (!await _stillThere()) return;
    final err = await openExternal(widget.path);
    if (err != null && mounted) _toast(err);
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
            key: _scaffold,
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              Positioned.fill(
                child: Listener(
                  onPointerDown: _pointerDown,
                  onPointerUp: _pointerUp,
                  onPointerCancel: _pointerUp,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: Transform.translate(
                      offset: Offset(0, _drag),
                      child: InteractiveViewer(
                        transformationController: _zoom,
                        minScale: 1,
                        maxScale: 6,
                        onInteractionStart: _swipeStart,
                        onInteractionUpdate: _swipeUpdate,
                        onInteractionEnd: _swipeEnd,
                        child: Center(
                          // Takes taps on the image itself, so only the letterbox closes.
                          child: GestureDetector(
                            onTap: () {},
                            excludeFromSemantics: true,
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
