import 'package:flutter/material.dart';

import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/playback_policy.dart';
import 'playback_volume_control.dart';

/// Commit first: a failed disk write must not change the live playback policy.
Future<void> persistPlaybackSetting(
  AppRuntime runtime,
  String key,
  Object? value, {
  String? albumId,
}) async {
  await runtime.storage.transaction((state) {
    final settings = state['settings'] as Map;
    final global =
        settings.putIfAbsent('playback', () => <String, dynamic>{}) as Map;
    Map target = global;
    if (albumId != null) {
      final overrides = settings.putIfAbsent(
        'albumOverrides',
        () => <String, dynamic>{},
      ) as Map;
      target = overrides.putIfAbsent(albumId, () => <String, dynamic>{}) as Map;
    }
    if (value == null) {
      target.remove(key);
    } else {
      target[key] = value;
    }
    PlaybackSettings.resolve(global, albumId == null ? const {} : target);
    if (key == 'syncHistory' && value is! bool)
      throw const FormatException('同步设置无效');
  });
  await runtime.player.applySettings(updateSource: key == 'listenAndDownload');
  runtime.changed();
}

Future<void> showQuickPlaybackSettings(
  BuildContext context,
  AppRuntime runtime, {
  String? albumId,
  String? albumTitle,
}) async {
  var global = albumId == null;
  var saving = false;
  final fullSettings = await showLocalPanel<bool>(
    context: context,
    title: '播放选项',
    builder: (context) => StatefulBuilder(
      builder: (context, setPanelState) => Column(
        children: [
          if (albumId != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('此专辑')),
                  ButtonSegment(value: true, label: Text('全局')),
                ],
                selected: {global},
                onSelectionChanged: saving
                    ? null
                    : (values) => setPanelState(() => global = values.single),
              ),
            ),
          Expanded(
            child: PlaybackSettingsPage(
              key: ValueKey(global),
              runtime: runtime,
              albumId: global ? null : albumId,
              albumTitle: global ? null : albumTitle,
              embedded: true,
              quick: true,
              onSavingChanged: (value) {
                if (context.mounted) setPanelState(() => saving = value);
              },
              onOpenFullSettings: () => Navigator.pop(context, true),
            ),
          ),
        ],
      ),
    ),
  );
  if (fullSettings != true || !context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PlaybackSettingsPage(
        runtime: runtime,
        albumId: global ? null : albumId,
        albumTitle: global ? null : albumTitle,
      ),
    ),
  );
}

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({
    required this.runtime,
    this.albumId,
    this.albumTitle,
    this.embedded = false,
    this.quick = false,
    this.onSavingChanged,
    this.onOpenFullSettings,
    super.key,
  });
  final AppRuntime runtime;
  final String? albumId, albumTitle;
  final bool embedded;
  final bool quick;
  final ValueChanged<bool>? onSavingChanged;
  final VoidCallback? onOpenFullSettings;

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  bool _busy = false;
  String? _error;
  String? _historyResult;
  final Map<String, double> _drafts = {};

  Map get _settings => widget.runtime.storage.state['settings'] as Map;
  Map get _global => _settings['playback'] as Map? ?? const {};
  Map get _album =>
      (_settings['albumOverrides'] as Map?)?[widget.albumId] as Map? ??
      const {};
  String _source(String key) => widget.albumId == null
      ? '全局设置'
      : _album.containsKey(key)
      ? '专辑设置'
      : '继承全局';

  Future<void> _save(String key, Object? value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onSavingChanged?.call(true);
    try {
      await persistPlaybackSetting(
        widget.runtime,
        key,
        value,
        albumId: widget.albumId,
      );
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存或应用失败，请重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onSavingChanged?.call(false);
      }
    }
  }

  Widget _inherit(String key) =>
      widget.albumId != null && _album.containsKey(key)
      ? TextButton(
          key: ValueKey('inherit:$key'),
          onPressed: _busy ? null : () => _save(key, null),
          child: const Text('恢复继承全局'),
        )
      : const SizedBox.shrink();

  Widget _section(
    String title,
    List<Widget> children, {
    bool expandable = false,
  }) => widget.quick && expandable
      ? Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Card(
            margin: EdgeInsets.zero,
            child: ExpansionTile(title: Text(title), children: children),
          ),
        )
      : _sectionBody(title, children);

  Widget _sectionBody(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _slider(
    String key,
    String title,
    double value,
    double min,
    double max,
    int divisions,
    String Function(double) label,
  ) {
    final current = _drafts[key] ?? value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 16,
            runSpacing: 4,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(
                label(current),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_source(key), style: Theme.of(context).textTheme.bodySmall),
          Slider(
            key: ValueKey(key),
            value: current.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: label(current),
            semanticFormatterCallback: label,
            onChanged: _busy
                ? null
                : (value) => setState(() => _drafts[key] = value),
            onChangeEnd: _busy
                ? null
                : (value) async {
                    await _save(key, double.parse(value.toStringAsFixed(2)));
                    if (mounted) setState(() => _drafts.remove(key));
                  },
          ),
          if (key == 'speed')
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                  ChoiceChip(
                    label: Text('${speed}×'),
                    selected: current == speed,
                    onSelected: _busy ? null : (_) => _save(key, speed),
                  ),
              ],
            ),
          _inherit(key),
        ],
      ),
    );
  }

  Widget _number(String key, String title, int value, int min, int max) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${_source(key)} · $min–$max 秒',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: '$title减少 1 秒',
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: _busy || value <= min
                      ? null
                      : () => _save(key, value - 1),
                ),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('$key:$value:$_busy'),
                    initialValue: '$value',
                    enabled: !_busy,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: title,
                      suffixText: '秒',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    onFieldSubmitted: (text) {
                      final parsed = int.tryParse(text);
                      if (parsed == null || parsed < min || parsed > max) {
                        setState(() => _error = '$title请输入 $min–$max 秒');
                        return;
                      }
                      _save(key, parsed);
                    },
                  ),
                ),
                IconButton(
                  tooltip: '$title增加 1 秒',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _busy || value >= max
                      ? null
                      : () => _save(key, value + 1),
                ),
              ],
            ),
            _inherit(key),
          ],
        ),
      );

  Widget _toggle(String key, String title, bool value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile(
        key: ValueKey(key),
        title: Text(title),
        subtitle: Text(_source(key)),
        value: value,
        onChanged: _busy ? null : (value) => _save(key, value),
      ),
      Padding(padding: const EdgeInsets.only(left: 16), child: _inherit(key)),
    ],
  );

  Future<void> _sync(bool value) async {
    if (value) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('同步收听历史？'),
          content: const Text('开启后会读取并写入当前账号的喜马拉雅收听历史。本地文件播放也会同步实际进度。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开启同步'),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) return;
    }
    await _save('syncHistory', value);
  }

  Future<void> _retryHistory() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _historyResult = null;
    });
    try {
      await widget.runtime.player.retryHistory();
      if (mounted) setState(() => _historyResult = '历史同步完成');
    } catch (error) {
      if (mounted) {
        setState(() {
          final code = error is XmlyException ? error.code : null;
          if (code != 'history_unavailable' && code != 'history_interrupted') {
            _error = '历史同步失败，进度已保留';
          }
          _historyResult = switch (code) {
            'history_unconfirmed' => '部分进度未获确认，请稍后手动重试',
            'history_unavailable' => '请先登录并开启历史同步',
            'history_interrupted' => '账号或同步设置已变更，请重新操作',
            _ => null,
          };
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadOption(String key, bool value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.runtime.storage.transaction((state) {
        final download = (state['settings'] as Map).putIfAbsent(
          'download',
          () => <String, dynamic>{},
        ) as Map;
        download[key] = value;
      });
      widget.runtime.changed();
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        PlaybackSettings resolved;
        try {
          resolved = PlaybackSettings.resolve(
            _global,
            widget.albumId == null ? const {} : _album,
          );
        } on FormatException catch (error) {
          return Center(child: Text('播放设置无效：${error.message}'));
        }
        final download = _settings['download'] as Map? ?? const {};
        return SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                    child: Text(
                      widget.albumId == null
                          ? '对所有专辑生效；专辑可单独设置。'
                          : '${widget.albumTitle?.isNotEmpty == true ? widget.albumTitle : '当前专辑'} · 未单独设置的项目继承全局',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        key: const ValueKey('playbackError'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  _section('声音', [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: PlaybackVolumeControl(runtime: widget.runtime),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('主音量对所有专辑生效，与下面的专辑音量共同控制响度。'),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _slider(
                      'speed',
                      '播放倍速',
                      resolved.speed,
                      0.5,
                      3,
                      25,
                      (value) => '${value.toStringAsFixed(2)}×',
                    ),
                    const Divider(indent: 16, endIndent: 16),
                    _slider(
                      'volume',
                      widget.albumId == null ? '默认专辑音量' : '专辑音量',
                      resolved.volume,
                      0,
                      100,
                      100,
                      (value) => '${value.round()}%',
                    ),
                  ]),
                  _section('跳过与快进', [
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text('直接输入秒数后按完成保存，或使用加减按钮。'),
                    ),
                    _number(
                      'skipIntroSeconds',
                      '跳过片头',
                      resolved.skipIntroSeconds,
                      0,
                      3600,
                    ),
                    _number(
                      'skipOutroSeconds',
                      '跳过片尾',
                      resolved.skipOutroSeconds,
                      0,
                      3600,
                    ),
                    if (!widget.quick) ...[
                      _number(
                        'seekBackwardSeconds',
                        '后退间隔',
                        resolved.seekBackwardSeconds,
                        1,
                        300,
                      ),
                      _number(
                        'seekForwardSeconds',
                        '前进间隔',
                        resolved.seekForwardSeconds,
                        1,
                        300,
                      ),
                    ],
                  ], expandable: true),
                  _section('播放方式', [
                    _toggle('autoNext', '自动播放下一集', resolved.autoNext),
                    if (!widget.quick)
                      _toggle(
                        'listenAndDownload',
                        '默认边听边下',
                        resolved.listenAndDownload,
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<String>(
                            key: ValueKey('loopMode:${resolved.loopMode}'),
                            initialValue: resolved.loopMode,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: '循环方式',
                              helperText: _source('loopMode'),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'off',
                                child: Text('顺序播放'),
                              ),
                              DropdownMenuItem(
                                value: 'single',
                                child: Text('单集循环'),
                              ),
                            ],
                            onChanged: _busy
                                ? null
                                : (value) {
                                    if (value != null) _save('loopMode', value);
                                  },
                          ),
                          _inherit('loopMode'),
                        ],
                      ),
                    ),
                  ]),
                  if (widget.quick)
                    ListTile(
                      title: const Text('完整播放设置'),
                      subtitle: const Text('快进间隔、边听边下及其他偏好'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : widget.onOpenFullSettings,
                    )
                  else if (widget.albumId == null) ...[
                    _section('历史同步', [
                      SwitchListTile(
                        key: const ValueKey('syncHistory'),
                        title: const Text('同步云端收听历史'),
                        value: _global['syncHistory'] == true,
                        onChanged: _busy ? null : _sync,
                      ),
                      ListTile(
                        title: const Text('重试历史同步'),
                        subtitle: _historyResult == null
                            ? null
                            : Text(_historyResult!),
                        trailing: const Icon(Icons.sync),
                        onTap: _busy ? null : _retryHistory,
                      ),
                    ]),
                    _section('下载与定时', [
                      SwitchListTile(
                        title: const Text('暂停播放时也暂停当前下载'),
                        value: download['pauseDownloadWithPlayback'] == true,
                        onChanged: _busy
                            ? null
                            : (value) => _downloadOption(
                                'pauseDownloadWithPlayback',
                                value,
                              ),
                      ),
                      SwitchListTile(
                        title: const Text('定时结束后继续下载'),
                        value: download['continueDownloadAfterSleep'] == true,
                        onChanged: _busy
                            ? null
                            : (value) => _downloadOption(
                                'continueDownloadAfterSleep',
                                value,
                              ),
                      ),
                      ListTile(
                        title: const Text('定时关闭偏好'),
                        trailing: const Icon(Icons.timer_outlined),
                        onTap: _busy
                            ? null
                            : () => showSleepTimerDialog(
                                context,
                                widget.runtime,
                                startTimer: false,
                              ),
                      ),
                    ]),
                  ] else
                    ListTile(
                      title: const Text('全局播放设置'),
                      subtitle: const Text('历史同步、下载与定时偏好'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PlaybackSettingsPage(runtime: widget.runtime),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return widget.embedded
        ? PopScope(canPop: !_busy, child: content)
        : Scaffold(
            appBar: AppBar(title: const Text('播放设置')),
            body: content,
          );
  }
}

Future<void> showSleepTimerDialog(
  BuildContext context,
  AppRuntime runtime, {
  bool startTimer = true,
}) => showLocalPanel<void>(
  context: context,
  title: startTimer ? '定时关闭' : '定时关闭偏好',
  height: 600,
  builder: (_) => _SleepTimerPage(runtime: runtime, startTimer: startTimer),
);

class _SleepTimerPage extends StatefulWidget {
  const _SleepTimerPage({required this.runtime, required this.startTimer});
  final AppRuntime runtime;
  final bool startTimer;

  @override
  State<_SleepTimerPage> createState() => _SleepTimerPageState();
}

class _SleepTimerPageState extends State<_SleepTimerPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _minutes;
  late final int _storedMinutes;
  late SleepMode _mode;
  late SleepAction _action;
  late bool _wait;
  late bool _customMinutes;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final stored = (widget.runtime.storage.state['settings'] as Map)['sleep'];
    SleepRequest request;
    try {
      request = SleepRequest.fromJson(stored is Map ? stored : const {});
    } on FormatException {
      request = SleepRequest();
    }
    _storedMinutes = request.minutes;
    _minutes = TextEditingController(text: '${request.minutes}');
    _mode = request.mode;
    _action = request.action;
    _wait = request.waitForEnd;
    _customMinutes = ![15, 30, 45, 60].contains(request.minutes);
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final enteredMinutes = int.tryParse(_minutes.text);
      final request = SleepRequest(
        mode: _mode,
        action: _action,
        minutes:
            enteredMinutes != null &&
                enteredMinutes >= 1 &&
                enteredMinutes <= 1440
            ? enteredMinutes
            : _storedMinutes,
        waitForEnd: _wait,
      );
      await widget.runtime.storage.transaction(
        (state) => (state['settings'] as Map)['sleep'] = request.toJson(),
      );
      if (widget.startTimer) widget.runtime.player.setSleep(request);
      widget.runtime.changed();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '定时设置保存失败';
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _form,
            child: ListView(
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 320 ? 8 : 24,
              ),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                DropdownButtonFormField<SleepMode>(
                  initialValue: _mode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '结束时间'),
                  items: const [
                    DropdownMenuItem(
                      value: SleepMode.afterDuration,
                      child: Text('倒计时'),
                    ),
                    DropdownMenuItem(
                      value: SleepMode.endOfTrack,
                      child: Text('本集结束'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) setState(() => _mode = value);
                        },
                ),
                const SizedBox(height: 20),
                if (_mode == SleepMode.afterDuration) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final minutes in [15, 30, 45, 60])
                        ChoiceChip(
                          label: Text('$minutes 分钟'),
                          selected:
                              !_customMinutes && _minutes.text == '$minutes',
                          onSelected: _saving
                              ? null
                              : (_) => setState(() {
                                  _minutes.text = '$minutes';
                                  _customMinutes = false;
                                }),
                        ),
                      if (!_customMinutes)
                        ActionChip(
                          label: const Text('自定义'),
                          onPressed: _saving
                              ? null
                              : () => setState(() => _customMinutes = true),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_customMinutes)
                    TextFormField(
                      key: const ValueKey('sleepMinutes'),
                      controller: _minutes,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: '自定义分钟（1–1440）',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (text) {
                        final n = int.tryParse(text ?? '');
                        return n == null || n < 1 || n > 1440
                            ? '请输入 1–1440 分钟'
                            : null;
                      },
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('到时等待本集结束'),
                    value: _wait,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _wait = value == true),
                  ),
                  const SizedBox(height: 16),
                ],
                DropdownButtonFormField<SleepAction>(
                  initialValue: _action,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '结束动作'),
                  items: const [
                    DropdownMenuItem(
                      value: SleepAction.pause,
                      child: Text('暂停'),
                    ),
                    DropdownMenuItem(
                      value: SleepAction.exit,
                      child: Text('保存并退出应用'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) setState(() => _action = value);
                        },
                ),
                const SizedBox(height: 28),
                FilledButton(
                  key: const ValueKey('saveSleep'),
                  onPressed: _saving ? null : _save,
                  child: Text(
                    _saving
                        ? '正在保存…'
                        : widget.startTimer
                        ? '开始定时'
                        : '保存偏好',
                  ),
                ),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
