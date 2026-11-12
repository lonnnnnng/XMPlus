/// Pure playback decisions. Device commands and actual listening accounting live
/// in PlayerService and UsageLedger, not in this policy.
class PlaybackSettings {
  const PlaybackSettings._({
    required this.speed,
    required this.skipIntroSeconds,
    required this.skipOutroSeconds,
    required this.seekBackwardSeconds,
    required this.seekForwardSeconds,
    required this.autoNext,
    required this.loopMode,
    required this.listenAndDownload,
    required this.volume,
    required this.masterVolume,
    required this.masterMuted,
  });

  final double speed;
  final int skipIntroSeconds;
  final int skipOutroSeconds;
  final int seekBackwardSeconds;
  final int seekForwardSeconds;
  final bool autoNext;
  final String loopMode;
  final bool listenAndDownload;
  final double volume;
  final double masterVolume;
  final bool masterMuted;
  double get outputVolume => masterMuted ? 0 : volume * masterVolume / 100;

  factory PlaybackSettings.parse(Map values) => resolve(values);

  static PlaybackSettings resolve(Map global, [Map album = const {}]) {
    Object? value(String key, Object fallback) => album.containsKey(key)
        ? album[key]
        : global.containsKey(key)
        ? global[key]
        : fallback;

    double number(String key, double fallback, double min, double max) {
      final raw = value(key, fallback);
      if (raw is! num || !raw.isFinite || raw < min || raw > max) {
        throw FormatException('播放设置 $key 必须在 $min–$max 之间');
      }
      return raw.toDouble();
    }

    int seconds(String key, int fallback, int min, int max) {
      final raw = value(key, fallback);
      if (raw is! num ||
          !raw.isFinite ||
          raw < min ||
          raw > max ||
          raw != raw.truncateToDouble()) {
        throw FormatException('播放设置 $key 必须为 $min–$max 的整数');
      }
      return raw.toInt();
    }

    bool boolean(String key, bool fallback) {
      final raw = value(key, fallback);
      if (raw is! bool) throw FormatException('播放设置 $key 必须为开关值');
      return raw;
    }

    final loop = value('loopMode', 'off');
    if (loop != 'off' && loop != 'single') {
      throw const FormatException('循环方式必须为 off 或 single');
    }
    final masterVolume = global['masterVolume'] ?? 100;
    if (masterVolume is! num ||
        !masterVolume.isFinite ||
        masterVolume < 0 ||
        masterVolume > 100) {
      throw const FormatException('主音量必须在 0–100 之间');
    }
    final masterMuted = global['masterMuted'] ?? false;
    if (masterMuted is! bool) {
      throw const FormatException('主音量静音必须为开关值');
    }
    return PlaybackSettings._(
      speed: number('speed', 1, 0.5, 3),
      skipIntroSeconds: seconds('skipIntroSeconds', 0, 0, 3600),
      skipOutroSeconds: seconds('skipOutroSeconds', 0, 0, 3600),
      seekBackwardSeconds: seconds('seekBackwardSeconds', 15, 1, 300),
      seekForwardSeconds: seconds('seekForwardSeconds', 30, 1, 300),
      autoNext: boolean('autoNext', true),
      loopMode: loop as String,
      listenAndDownload: boolean('listenAndDownload', false),
      volume: number('volume', 100, 0, 100),
      masterVolume: masterVolume.toDouble(),
      masterMuted: masterMuted,
    );
  }

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'skipIntroSeconds': skipIntroSeconds,
    'skipOutroSeconds': skipOutroSeconds,
    'seekBackwardSeconds': seekBackwardSeconds,
    'seekForwardSeconds': seekForwardSeconds,
    'autoNext': autoNext,
    'loopMode': loopMode,
    'listenAndDownload': listenAndDownload,
    'volume': volume,
    'masterVolume': masterVolume,
    'masterMuted': masterMuted,
  };
}

enum SleepAction { pause, exit }

enum SleepMode { afterDuration, endOfTrack }

/// Persist this preset only; an armed deadline belongs to the current process.
class SleepRequest {
  SleepRequest({
    this.mode = SleepMode.afterDuration,
    this.action = SleepAction.pause,
    this.minutes = 30,
    this.waitForEnd = false,
  }) {
    if (minutes < 1 || minutes > 1440) {
      throw const FormatException('定时分钟数必须在 1–1440 之间');
    }
  }

  final SleepMode mode;
  final SleepAction action;
  final int minutes;
  final bool waitForEnd;

  factory SleepRequest.fromJson(Map values) {
    final minutes = values.containsKey('minutes') ? values['minutes'] : 30;
    final wait = values.containsKey('waitForEnd')
        ? values['waitForEnd']
        : false;
    final mode = values.containsKey('mode') ? values['mode'] : 'afterDuration';
    final action = values.containsKey('action') ? values['action'] : 'pause';
    if (minutes is! int ||
        wait is! bool ||
        !SleepMode.values.any((value) => value.name == mode) ||
        !SleepAction.values.any((value) => value.name == action)) {
      throw const FormatException('定时设置格式不正确');
    }
    return SleepRequest(
      mode: SleepMode.values.firstWhere((value) => value.name == mode),
      action: SleepAction.values.firstWhere((value) => value.name == action),
      minutes: minutes,
      waitForEnd: wait,
    );
  }

  Map<String, dynamic> toJson() => {
    'minutes': minutes,
    'action': action.name,
    'mode': mode.name,
    'waitForEnd': waitForEnd,
  };
}

class PlaybackPolicy {
  PlaybackPolicy({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  PlaybackSettings _settings = PlaybackSettings.resolve(const {});
  double _duration = 0;
  bool _started = false;
  bool _manual = false;
  bool _finished = false;
  SleepRequest? _sleepRequest;
  DateTime? _deadline;
  bool _sleepWaitingForEnd = false;

  String? get warning =>
      _duration > 0 &&
          _settings.skipIntroSeconds + _settings.skipOutroSeconds >= _duration
      ? '片头和片尾合计不小于本集时长，已关闭本集自动跳过'
      : null;

  bool get _canSkip => !_manual && _duration > 0 && warning == null;

  double start({
    required double duration,
    double resumePosition = 0,
    required PlaybackSettings settings,
    bool manualReplay = false,
  }) {
    _settings = settings;
    _duration = _knownDuration(duration);
    _started = true;
    _manual = manualReplay;
    _finished = false;
    final resume = _clamp(resumePosition);
    return _canSkip && resume < settings.skipIntroSeconds
        ? settings.skipIntroSeconds.toDouble()
        : resume;
  }

  void updateSettings(PlaybackSettings settings) => _settings = settings;

  /// A single chapter epoch emits at most one completion, regardless of whether
  /// an outro threshold or the device's physical end event arrives first.
  bool observe(
    double actualPosition, {
    double? duration,
    bool completed = false,
    bool allowCompletion = true,
  }) {
    if (!_started) return false;
    if (duration != null) _duration = _knownDuration(duration);
    if (_finished || !allowCompletion) return false;
    final atEnd =
        actualPosition.isFinite && _duration > 0 && actualPosition >= _duration;
    final atOutro =
        _canSkip &&
        _settings.skipOutroSeconds > 0 &&
        actualPosition.isFinite &&
        actualPosition >= _duration - _settings.skipOutroSeconds;
    if (!completed && !atEnd && !atOutro) return false;
    _finished = true;
    return true;
  }

  double manualSeek(double position) {
    _manual = true;
    return _clamp(position);
  }

  static double _knownDuration(double duration) =>
      duration.isFinite && duration > 0 ? duration : 0;

  double _clamp(double position) {
    if (!position.isFinite || position < 0) return 0;
    return _duration > 0 && position > _duration ? _duration : position;
  }

  SleepRequest? get sleepRequest => _sleepRequest;
  DateTime? get deadline => _deadline;
  bool get sleepWaitingForEnd => _sleepWaitingForEnd;

  Duration? get remainingDuration {
    final end = _deadline;
    if (end == null) return null;
    final remaining = end.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void armSleep(SleepRequest request) {
    _sleepRequest = request;
    _sleepWaitingForEnd = false;
    _deadline = request.mode == SleepMode.afterDuration
        ? _clock().add(Duration(minutes: request.minutes))
        : null;
  }

  void cancelSleep() {
    _sleepRequest = null;
    _deadline = null;
    _sleepWaitingForEnd = false;
  }

  SleepAction _consumeSleep() {
    final action = _sleepRequest!.action;
    cancelSleep();
    return action;
  }

  SleepAction? pollSleep() {
    final request = _sleepRequest;
    if (request == null ||
        request.mode == SleepMode.endOfTrack ||
        _clock().isBefore(_deadline!))
      return null;
    if (request.waitForEnd) {
      _sleepWaitingForEnd = true;
      return null;
    }
    return _consumeSleep();
  }

  /// Call before deciding loop/next/tail actions, including when a timer tick
  /// and a chapter event arrive together. Consuming clears the pending request.
  SleepAction? onChapterEnd() {
    final request = _sleepRequest;
    if (request == null) return null;
    if (request.mode == SleepMode.endOfTrack) return _consumeSleep();
    if (_sleepWaitingForEnd || !_clock().isBefore(_deadline!)) {
      return _consumeSleep();
    }
    return null;
  }
}
