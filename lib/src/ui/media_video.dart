import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'image_viewer.dart' show openExternal;
import 'toast.dart';

/// Bigger videos wait for a tap: each thumbnail costs a plaintext copy
/// and a decoder.
const _autoDecryptBytes = 32 << 20;

/// A received or sent video: first frame and duration, played inline.
class VideoBubble extends StatefulWidget {
  const VideoBubble({super.key, required this.state, required this.msg, required this.width});

  final AppState state;
  final ChatMessage msg;
  final double width;

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  bool _opening = false;
  bool _playWhenReady = false;
  bool _failed = false;
  VideoPlayerController? _video;
  ValueListenable<String?>? _plain;

  bool get _small => (widget.msg.size ?? 0) <= _autoDecryptBytes;

  @override
  void initState() {
    super.initState();
    if (_small) _load(play: false);
  }

  @override
  void dispose() {
    _plain?.removeListener(_cacheChanged);
    _drop();
    super.dispose();
  }

  // Disposed after the frame, so nothing still painting it sees it go.
  void _drop() {
    final video = _video;
    _video = null;
    if (video == null) return;
    video.removeListener(_checkError);
    WidgetsBinding.instance.addPostFrameCallback((_) => video.dispose());
  }

  Future<void> _load({required bool play}) async {
    final sealed = widget.msg.path;
    if (sealed == null) return;
    if (_opening) {
      _playWhenReady |= play;
      return;
    }
    _playWhenReady = play;
    setState(() {
      _opening = true;
      _failed = false;
    });
    final path = await widget.state.decryptForOpen(sealed);
    if (!mounted) return;
    if (path == null) return _fail();
    final video = VideoPlayerController.file(File(path));
    try {
      await video.initialize();
      // Paints the first frame as the thumbnail.
      await video.seekTo(Duration.zero);
    } catch (_) {
      await video.dispose();
      if (mounted) _fail();
      return;
    }
    if (!mounted) {
      await video.dispose();
      return;
    }
    video.addListener(_checkError);
    setState(() {
      _video = video;
      _opening = false;
    });
    // Tells this bubble when the cache wipe deletes the copy it plays.
    _plain ??= widget.state.plaintext(sealed)..addListener(_cacheChanged);
    if (_playWhenReady) await video.play();
  }

  void _fail() => setState(() {
        _opening = false;
        _failed = true;
      });

  void _cacheChanged() {
    if (!mounted) return;
    if (_plain?.value == null) {
      if (_video != null) setState(_drop);
    } else if (_video == null && !_opening && !_failed && _small) {
      _load(play: false);
    }
  }

  void _checkError() {
    if (!(_video?.value.hasError ?? false) || !mounted) return;
    setState(() {
      _drop();
      _failed = true;
    });
  }

  Future<void> _toggle() async {
    final video = _video;
    if (video == null) return _load(play: true);
    final v = video.value;
    if (v.isPlaying) return video.pause();
    if (v.isCompleted) await video.seekTo(Duration.zero);
    await video.play();
  }

  Future<void> _external() async {
    final sealed = widget.msg.path;
    if (sealed == null) return;
    final path = await widget.state.decryptForOpen(sealed);
    if (!mounted) return;
    await showError(context, path == null ? 'Couldn\'t decrypt this file.' : openExternal(path));
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    if (video == null) return _bubble(context, null);
    return ListenableBuilder(listenable: video, builder: (context, _) => _bubble(context, video));
  }

  Widget _bubble(BuildContext context, VideoPlayerController? video) {
    final tc = TincanColors.of(context);
    const ink = Color(0xFFF4FBFA);
    final width = widget.width;
    var height = width * 0.565;
    if (video != null && video.value.aspectRatio > 0) {
      height = (width / video.value.aspectRatio).clamp(width * 0.4, width * 1.4);
    }
    final playing = video?.value.isPlaying ?? false;
    final duration = video?.value.duration;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: width,
        height: height,
        color: tc.videoBg,
        child: Stack(alignment: Alignment.center, children: [
          if (video != null)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: video.value.size.width,
                  height: video.value.size.height,
                  child: VideoPlayer(video),
                ),
              ),
            ),
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: Semantics(
                button: true,
                label: _failed ? 'Retry video' : playing ? 'Pause video' : 'Play video',
                child: InkWell(onTap: _toggle),
              ),
            ),
          ),
          if (_opening)
            const SizedBox(
                width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: ink))
          else if (_failed)
            Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.videocam_off_outlined, size: 26, color: ink),
              TextButton(
                onPressed: _external,
                child: const Text('Open externally', style: TextStyle(color: ink)),
              ),
            ])
          else if (!playing)
            IgnorePointer(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0x8C0F0C09),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xD9FFF7EE), width: 1.5),
                ),
                child: const Icon(Icons.play_arrow_rounded, size: 30, color: ink),
              ),
            ),
          if (duration != null && duration > Duration.zero)
            Positioned(
              right: 8,
              bottom: playing ? 14 : 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0x99000000), borderRadius: BorderRadius.circular(6)),
                  child: Text(
                      playing ? '${formatDuration(video!.value.position)} / ${formatDuration(duration)}' : formatDuration(duration),
                      style: Tc.mono(11, ink)),
                ),
              ),
            ),
          if (video != null && playing)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(video,
                  allowScrubbing: true,
                  padding: const EdgeInsets.only(top: 6),
                  colors: VideoProgressColors(playedColor: tc.accent)),
            ),
          if (!_failed)
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: 'Open externally',
                onPressed: _external,
                icon: const Icon(Icons.open_in_new, size: 16, color: ink),
              ),
            ),
        ]),
      ),
    );
  }
}

/// 0:42, 12:05, 1:02:09.
String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
