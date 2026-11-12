import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';

import '../models/xmly_models.dart';
import 'album_cache.dart';
import 'close_sequence.dart';
import 'player_service.dart';
import 'windows_audio_service.dart';

/// A system-control view of PlayerService, never a second player or queue.
class SystemMediaService extends BaseAudioHandler {
  SystemMediaService._(this._player, this._albumCache, this._commandsAllowed);

  static Future<SystemMediaService> start({
    required PlayerService player,
    required AlbumCache albumCache,
    bool Function()? commandsAllowed,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw UnsupportedError('系统媒体控制仅支持 Android 和 Windows');
    }
    if (Platform.isWindows) WindowsAudioServicePlatform.registerWith();
    final handler = SystemMediaService._(player, albumCache, commandsAllowed);
    await AudioService.init<SystemMediaService>(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'teikengstudio.xmplus.playback',
        androidNotificationChannelName: '声音播放',
        androidNotificationIcon: 'drawable/ic_media_notification',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
    handler._playerEvents = player.changes.listen((_) => handler._sync());
    albumCache.addListener(handler._sync);
    handler._platformErrors = AudioService.asyncError.listen(
      handler._platformError,
    );
    handler._sync();
    return handler;
  }

  final PlayerService _player;
  final AlbumCache _albumCache;
  final bool Function()? _commandsAllowed;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<Future<void>> _pending = {};
  StreamSubscription<void>? _playerEvents;
  StreamSubscription<Object>? _platformErrors;
  late final _closeSteps = CloseSequence([
    () async {
      _closed = true;
      _albumCache.removeListener(_sync);
    },
    () async {
      await _playerEvents?.cancel();
    },
    () async {
      await _platformErrors?.cancel();
    },
    () async {
      await Future.wait(_pending.toList());
    },
    () async {
      mediaItem.add(null);
      playbackState.add(PlaybackState());
      _clock.stop();
    },
    () async {
      await Future.wait([
        playbackState.close(),
        mediaItem.close(),
        queue.close(),
        queueTitle.close(),
        androidPlaybackInfo.close(),
        ratingStyle.close(),
        customEvent.close(),
        customState.close(),
      ]);
    },
    () => AudioServicePlatform.instance.stopService(const StopServiceRequest()),
  ]);
  bool _closed = false, _dismissed = false, _everActive = false;
  Object? _metadataKey, _stateKey;
  String? _commandError, _nativeError;
  int _publishedAt = -1000;
  int _commandRecoveryRevision = 0;

  static Duration _seconds(double seconds) => Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );

  void _platformError(Object failure) {
    if (_closed) return;
    _nativeError = '系统媒体控制同步失败，请重新启动应用';
    _sync();
    _report(failure, StackTrace.current, _nativeError!);
  }

  void _report(Object failure, StackTrace stack, String message) {
    if (!_closed) {
      customEvent.add({'type': 'systemMediaError', 'message': message});
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: failure,
        stack: stack,
        library: 'system_media_service',
        context: ErrorDescription(message),
      ),
    );
  }

  void _sync() {
    if (_closed) return;
    final track = _player.current;
    final hasSource = _player.sourceKind.isNotEmpty;
    if (hasSource || _player.loading) {
      _dismissed = false;
      _everActive = true;
    }
    if (_commandError != null &&
        !_player.loading &&
        hasSource &&
        _player.error == null &&
        _player.playbackRecoveryRevision != _commandRecoveryRevision) {
      _commandError = null;
    }
    final error = _nativeError ?? _commandError ?? _player.error;
    final active =
        track != null &&
        !_dismissed &&
        (hasSource || _player.loading || (_everActive && error != null));
    final seconds = active
        ? (_player.loading || _player.duration <= 0
              ? track.duration
              : _player.duration)
        : 0.0;
    final duration = seconds.isFinite && seconds > 0 ? _seconds(seconds) : null;
    final cached = active && track.albumId.isNotEmpty
        ? _albumCache[track.albumId]
        : null;
    final metadataKey = (active ? track : null, cached, duration);
    if (_metadataKey != metadataKey) {
      _metadataKey = metadataKey;
      if (!active) {
        mediaItem.add(null);
      } else {
        Track? observed;
        for (final candidate in cached?.tracks ?? const <Track>[]) {
          if (candidate.id == track.id) {
            observed = candidate;
            break;
          }
        }
        final title = track.title.isNotEmpty
            ? track.title
            : observed?.title ?? '';
        final artist = track.artist.isNotEmpty
            ? track.artist
            : observed?.artist.isNotEmpty == true
            ? observed!.artist
            : cached?.album.artist ?? '';
        final album = track.album.isNotEmpty
            ? track.album
            : observed?.album.isNotEmpty == true
            ? observed!.album
            : cached?.album.title ?? '';
        // AlbumCache has already validated this local image. Never fetch artwork
        // or private playback URLs here; null also clears the previous cover.
        mediaItem.add(
          MediaItem(
            id: track.id,
            title: title.isEmpty ? '声音 ${track.number}' : title,
            artist: artist,
            album: album,
            duration: duration,
            artUri: cached?.coverPath == null
                ? null
                : Uri.file(cached!.coverPath!),
          ),
        );
      }
    }

    final processing = !active
        ? AudioProcessingState.idle
        : error != null
        ? AudioProcessingState.error
        : _player.loading
        ? AudioProcessingState.loading
        : _player.buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready;
    final playing = active && error == null && _player.playing;
    final speed = _player.rate.isFinite && _player.rate > 0
        ? _player.rate
        : 1.0;
    final stateKey = (
      processing,
      playing,
      speed,
      error,
      active ? track.id : null,
      duration,
      _player.seekRevision,
    );
    final now = _clock.elapsedMilliseconds;
    if (_stateKey == stateKey && (!playing || now - _publishedAt < 1000))
      return;
    _stateKey = stateKey;
    _publishedAt = now;
    var position = active && _player.position.isFinite
        ? _player.position.clamp(0.0, double.infinity).toDouble()
        : 0.0;
    if (duration != null) position = position.clamp(0.0, seconds).toDouble();
    playbackState.add(
      PlaybackState(
        processingState: processing,
        playing: playing,
        updatePosition: _seconds(position),
        speed: speed,
        controls: active
            ? [
                MediaControl.skipToPrevious,
                playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
                MediaControl.rewind,
                MediaControl.fastForward,
                MediaControl.stop,
              ]
            : const [],
        androidCompactActionIndices: active ? const [0, 1, 2] : null,
        systemActions: active ? const {MediaAction.seek} : const {},
        errorCode: active && error != null ? 1 : null,
        errorMessage: active ? error : null,
      ),
    );
  }

  Future<void> _command(Future<void> Function() action) async {
    if (!(_commandsAllowed?.call() ?? true)) return;
    if (_closed) throw StateError('系统媒体控制已关闭');
    final finished = Completer<void>();
    _pending.add(finished.future);
    _commandError = null;
    try {
      await action();
    } catch (failure, stack) {
      if (!_closed) {
        _commandError = _player.error ?? '系统播放操作失败，请在应用内重试';
        _commandRecoveryRevision = _player.playbackRecoveryRevision;
        _report(failure, stack, _commandError!);
      }
      rethrow;
    } finally {
      _pending.remove(finished.future);
      finished.complete();
      _sync();
    }
  }

  @override
  Future<void> play() => _command(_player.resume);

  @override
  Future<void> pause() => _command(_player.pause);

  @override
  Future<void> stop() => _command(() async {
    await _player.quiesce();
    _dismissed = true;
    _everActive = false;
  });

  @override
  Future<void> skipToPrevious() => _command(_player.previous);

  @override
  Future<void> skipToNext() => _command(_player.next);

  @override
  Future<void> seek(Duration position) => _command(() async {
    final seconds = position.inMicroseconds / Duration.microsecondsPerSecond;
    if (!seconds.isFinite)
      throw ArgumentError.value(position, 'position', '播放位置无效');
    final duration = _player.duration;
    await _player.seek(
      seconds
          .clamp(
            0.0,
            duration.isFinite && duration > 0 ? duration : double.infinity,
          )
          .toDouble(),
    );
  });

  @override
  Future<void> fastForward() => _command(_player.seekForward);

  @override
  Future<void> rewind() => _command(_player.seekBackward);

  /// The runtime quiesces PlayerService before closing this projection.
  // Drain state streams before the native stop. If it fails, retry only that
  // stop; publishing to or closing the completed streams must not run again.
  Future<void> close() => _closeSteps.run();
}
