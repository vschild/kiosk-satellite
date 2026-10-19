/// Opening a video the way a broken hardware decoder will accept.
///
/// Flutter renders a texture into an `ImageReader` on API 29 and up, and
/// that reader holds up to 7 images, so the native window asks the decoder
/// for 8 buffers beyond its own. Some MediaTek AVC decoders cap their
/// output port well below the sum and refuse every count ACodec tries
/// (issue #374, reproduced on an Echo Show 8):
///
///     [OUTPUT] ... nBufferCountActual(6)
///     [OMX.MTK.VIDEO.DECODER.AVC] setting nBufferCountActual to 14 failed: -22
///     ... 13, 12, 11 ...
///     Failed to allocate buffers after transitioning to IDLE state
///     Decoder init failed: OMX.MTK.VIDEO.DECODER.AVC
///
/// A SurfaceView keeps only two or three buffers back, so the same file and
/// the same decoder start fine through a platform view. The texture stays
/// the default everywhere - it composites inside Flutter and costs less -
/// and only a device that fails this way pays for the second attempt.
///
/// Samsung Exynos devices start on the platform view instead (issue #894).
/// Their decoders hand out SBWC compressed frames, and importing those
/// into Flutter's GPU context leaks the decompressed copies: a Galaxy Tab
/// S9 FE grew by gigabytes of EGL memory and never gave it back. A
/// SurfaceView passes the frames to SurfaceFlinger, which reads SBWC as is.
///
/// Google Pixels start there too (issue #1024). Flutter's texture draws the
/// decoder's whole buffer and skips its crop, so a 1080p video decoded into
/// 1088 rows showed a green line along the bottom.
library;

import 'package:video_player/video_player.dart';

import '../managers/device/device_details.dart';

/// Options for a muted video that plays alongside other sound, like a
/// screensaver slide (issue #924). The plugin's default asks Android for
/// audio focus even at volume 0, and the music playing on the device
/// goes quiet for as long as the video runs.
///
/// The plugin keeps this flag process-wide and only changes it when a
/// controller passes options, so every controller in the app passes one
/// of these two explicitly. Otherwise a DLNA video would inherit the
/// screensaver's choice, or the other way round.
final mutedVideoOptions = VideoPlayerOptions(mixWithOthers: true);

/// Options for a video whose sound is the point, like a DLNA cast. It
/// takes audio focus and other players pause or duck as usual.
final audibleVideoOptions = VideoPlayerOptions(mixWithOthers: false);

/// Asked once per process: the answer is a property of the device. The
/// answer is kept, not the Future: a Future delivers to the zone it was
/// made in, so one made in a widget test never answers the tests after it.
bool? _platformVideoFirst;

/// Whether a player error is the video decoder refusing to start, rather
/// than a URL, a network or a container the device cannot read.
///
/// ExoPlayer's message reaches Dart as the plugin's
/// "Video player had error `<exception>`" string, so the match is on wording,
/// not a type. All three spellings below have been seen in the field.
bool isVideoDecoderFailure(Object error) {
  final text = error.toString();
  return text.contains('MediaCodecVideoRenderer error') ||
      text.contains('Decoder init failed') ||
      text.contains('DecoderInitializationException');
}

/// Builds a controller with [build] and initializes it, retrying once on a
/// decoder failure with [VideoViewType.platformView].
///
/// [build] must return a fresh controller for the view type it is handed;
/// the failed one is disposed before the retry. [onFallback] reports the
/// first error when the retry happens, for the log. The returned controller
/// is initialized and owned by the caller. [platformViewFirst] skips the
/// texture altogether; left null, the device decides.
Future<VideoPlayerController> openVideo(
  VideoPlayerController Function(VideoViewType viewType) build, {
  void Function(Object error)? onFallback,
  bool? platformViewFirst,
}) async {
  if (platformViewFirst ??
      (_platformVideoFirst ??= await DeviceDetails.platformVideoFirst())) {
    final only = build(VideoViewType.platformView);
    try {
      await only.initialize();
      return only;
    } catch (_) {
      await only.dispose();
      rethrow;
    }
  }
  final first = build(VideoViewType.textureView);
  try {
    await first.initialize();
    return first;
  } catch (e) {
    await first.dispose();
    if (!isVideoDecoderFailure(e)) rethrow;
    onFallback?.call(e);
    final second = build(VideoViewType.platformView);
    try {
      await second.initialize();
      return second;
    } catch (_) {
      await second.dispose();
      rethrow;
    }
  }
}
