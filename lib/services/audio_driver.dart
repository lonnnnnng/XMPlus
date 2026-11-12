import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

import 'close_sequence.dart';

/// Device observations, not requested commands. Epoch rejects old-source events.
class AudioSnapshot {
  const AudioSnapshot({
    required this.epoch,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = 0,
    this.duration = 0,
    this.error,
  });
  final int epoch;
  final bool playing, buffering, completed;
  final double position, duration;
  final String? error;
}

/// The only sound-device boundary. Tests implement this with recorded commands.
abstract class AudioDriver {
  Stream<AudioSnapshot> get snapshots;
  Future<void> open(Uri localUri, {required int epoch});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(double seconds);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> close();
}

void requireLocalAudio(Uri uri) {
  if (uri.scheme == 'file' &&
      (uri.host.isEmpty || Platform.isWindows) &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      uri.hasAbsolutePath &&
      !uri.hasQuery &&
      !uri.hasFragment) {
    try {
      // Windows file hosts are UNC shares already supported by downloads.
      uri.toFilePath(windows: Platform.isWindows);
      return;
    } on UnsupportedError {
      // Malformed file URIs must not become a different native media resource.
    }
  }
  if (uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.hasPort &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment)
    return;
  throw ArgumentError('播放器仅接受本机缓存或已下载文件');
}

/// Constructing this adapter never initializes media_kit or a sound device.
class MediaKitAudioDriver implements AudioDriver {
  Player? _player;
  final _events = StreamController<AudioSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _epoch = 0;
  bool _opening = false;
  bool _closed = false;
  AudioSession? _session;
  Future<void> _commands = Future<void>.value();
  late final _closeSteps = CloseSequence([
    () async {
      _closed = true;
      _cancelResume();
      await _commands;
    },
    () async {
      while (_subscriptions.isNotEmpty) {
        await _subscriptions.last.cancel();
        _subscriptions.removeLast();
      }
    },
    _releaseFocus,
    () async {
      await _player?.dispose();
      _player = null;
    },
    () async {
      await _events.close();
    },
  ]);
  int _intent = 0;
  int? _resumeIntent;
  @override
  Stream<AudioSnapshot> get snapshots => _events.stream;

  void _emit({String? error}) {
    final player = _player;
    if (player == null || _opening || _closed) return;
    final state = player.state;
    _events.add(
      AudioSnapshot(
        epoch: _epoch,
        playing: state.playing,
        buffering: state.buffering,
        completed: state.completed,
        position: state.position.inMicroseconds / 1000000,
        duration: state.duration.inMicroseconds / 1000000,
        error: error,
      ),
    );
  }

  Player _create() {
    if (_closed) throw StateError('播放器已关闭');
    MediaKit.ensureInitialized();
    // Independent pitch remains 1.0 while scaletempo changes playback rate.
    final player = Player(
      configuration: const PlayerConfiguration(pitch: true, title: 'XMPlus'),
    );
    _player = player;
    _subscriptions.addAll([
      player.stream.playing.listen((_) => _emit()),
      player.stream.buffering.listen((_) => _emit()),
      player.stream.position.listen((_) => _emit()),
      player.stream.duration.listen((_) => _emit()),
      player.stream.completed.listen((_) => _emit()),
      player.stream.error.listen((_) => _emit(error: '音频播放失败，请重试')),
    ]);
    return player;
  }

  // Serialize Android device/session operations, including disposal. The returned
  // future still reports command failures; only the queue tail handles its copy.
  Future<void> _run(Future<void> Function() action) {
    if (!Platform.isAndroid) return action();
    final result = _commands.then((_) async {
      if (!_closed) await action();
    });
    _commands = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  int _cancelResume() {
    _resumeIntent = null;
    return ++_intent;
  }

  void _event(Future<void> Function() action) {
    if (_closed) return;
    unawaited(
      _run(action).catchError((Object _) {
        _emit(error: '音频播放失败，请重试');
      }),
    );
  }

  Future<AudioSession> _audioSession() async {
    if (_session case final session?) return session;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    if (_closed) return session;
    _session = session;
    _subscriptions.addAll([
      session.interruptionEventStream.listen(
        _interrupt,
        onError: (Object _) => _emit(error: '音频播放失败，请重试'),
      ),
      session.becomingNoisyEventStream.listen((_) {
        final intent = _cancelResume();
        _event(() async {
          if (intent == _intent) await _pause();
        });
      }, onError: (Object _) => _emit(error: '音频播放失败，请重试')),
    ]);
    return session;
  }

  void _interrupt(AudioInterruptionEvent event) {
    if (_closed) return;
    if (event.begin) {
      final resume =
          event.type != AudioInterruptionType.unknown &&
          (_player?.state.playing == true || _resumeIntent != null);
      final intent = ++_intent;
      _resumeIntent = resume ? intent : null;
      _event(() async {
        if (intent != _intent) return;
        await _player?.pause();
        _emit();
        // Keep transient focus requests registered so Android can send gain.
        if (event.type == AudioInterruptionType.unknown) await _releaseFocus();
      });
    } else {
      final intent = _resumeIntent;
      _resumeIntent = null;
      if (event.type != AudioInterruptionType.unknown && intent != null) {
        _event(() => _play(intent));
      }
    }
  }

  Future<void> _releaseFocus() async {
    await _session?.setActive(false);
  }

  Future<void> _play(int intent) async {
    final player = _player;
    if (player == null || _closed || intent != _intent) return;
    if (Platform.isAndroid) {
      final session = await _audioSession();
      if (_closed || intent != _intent) return;
      final granted = await session.setActive(true);
      if (!granted) {
        await player.pause();
        throw StateError('无法获取音频焦点，请稍后重试');
      }
      if (_closed || intent != _intent) return;
    }
    await player.play();
    if (Platform.isAndroid && (_closed || intent != _intent)) {
      await player.pause();
    }
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
      _emit();
    } finally {
      await _releaseFocus();
    }
  }

  @override
  Future<void> open(Uri localUri, {required int epoch}) async {
    requireLocalAudio(localUri);
    // media_kit's file URI sanitizer can turn a named UNC host into a local
    // directory. Give it the native file path to preserve the share and escapes.
    final resource = localUri.scheme == 'file'
        ? localUri.toFilePath(windows: Platform.isWindows)
        : localUri.toString();
    _cancelResume();
    await _run(() async {
      _opening = true;
      try {
        final player = _player ?? _create();
        await player.stop();
        await _releaseFocus();
        _epoch = epoch;
        await player.open(Media(resource), play: false);
        await player.setPitch(1.0);
      } finally {
        _opening = false;
      }
      _emit();
    });
  }

  @override
  Future<void> play() {
    final intent = _cancelResume();
    return _run(() => _play(intent));
  }

  @override
  Future<void> pause() {
    _cancelResume();
    return _run(_pause);
  }

  @override
  Future<void> stop() {
    _cancelResume();
    return _run(() async {
      try {
        await _player?.stop();
        _emit();
      } finally {
        await _releaseFocus();
      }
    });
  }

  @override
  Future<void> seek(double seconds) => _run(() async {
    await _player?.seek(Duration(microseconds: (seconds * 1000000).round()));
  });
  @override
  Future<void> setRate(double rate) => _run(() async {
    await _player?.setRate(rate);
  });
  @override
  Future<void> setVolume(double volume) => _run(() async {
    await _player?.setVolume(volume);
  });
  @override
  Future<void> close() => _closeSteps.run();
}
