import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../services/app_runtime.dart';
import '../services/android_background_service.dart';

class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({required this.runtime, super.key});
  final AppRuntime runtime;
  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage>
    with WidgetsBindingObserver {
  String? _error;
  int _pendingSaves = 0;
  bool get _saving => _pendingSaves > 0;
  bool _disposing = false;
  Timer? _textSaveTimer;
  final Map<String, Object> _pendingText = {};
  ScaffoldMessengerState? _messenger;
  bool? _batteryExempt;
  bool _requestingBattery = false;
  bool _clearingUrlCache = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _readBatteryStatus();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_flushText());
    if (state == AppLifecycleState.resumed) _readBatteryStatus();
  }

  Future<void> _readBatteryStatus() async {
    try {
      final exempt = await AndroidBackgroundService.batteryOptimizationExempt();
      if (mounted) setState(() => _batteryExempt = exempt);
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取电池优化状态：$error');
    }
  }

  Future<void> _requestBatteryExemption() async {
    if (_requestingBattery) return;
    setState(() => _requestingBattery = true);
    try {
      await AndroidBackgroundService.requestBatteryOptimizationExemption();
      await _readBatteryStatus();
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开系统电池优化申请：$error');
    } finally {
      if (mounted) setState(() => _requestingBattery = false);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    unawaited(_flushText());
    if (Platform.isAndroid) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Map get _settings =>
      (widget.runtime.storage.state['settings'] as Map)['download'] as Map? ??
      const {};

  void _editText(String key, Object? value) {
    if (value == null) {
      _pendingText.remove(key);
    } else {
      _pendingText[key] = value;
    }
    _textSaveTimer?.cancel();
    if (_pendingText.isNotEmpty) {
      _textSaveTimer = Timer(
        const Duration(milliseconds: 400),
        () => unawaited(_flushText()),
      );
    }
  }

  Map<String, Object> _takeText() {
    _textSaveTimer?.cancel();
    final values = Map<String, Object>.from(_pendingText);
    _pendingText.clear();
    return values;
  }

  Future<void> _flushText() => _save(_takeText());

  Future<void> _set(String key, Object value) =>
      _save({..._takeText(), key: value});

  Future<void> _save(Map<String, Object> values) async {
    if (values.isEmpty) return;
    ++_pendingSaves;
    if (mounted && !_disposing) setState(() => _error = null);
    try {
      await widget.runtime.storage.transaction((state) {
        final settings = state['settings'] as Map;
        final download =
            settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
        download.addAll(values);
      });
      widget.runtime.changed();
    } catch (_) {
      if (mounted && !_disposing) {
        setState(() {
          _error = '设置保存失败，请重新修改后重试';
        });
      } else if (_messenger?.mounted == true) {
        _messenger!.showSnackBar(
          const SnackBar(content: Text('下载设置保存失败，请返回设置页重试')),
        );
      }
    } finally {
      --_pendingSaves;
      if (mounted && !_disposing) setState(() {});
    }
  }

  static String? _filenameError(String? text) {
    final value = text ?? '';
    if (value.contains('/') ||
        value.contains(r'\') ||
        value == '.' ||
        value == '..') {
      return '文件名不能包含目录路径，请使用“按专辑建立文件夹”';
    }
    final tokens = RegExp(r'\{([^{}]+)\}')
        .allMatches(value)
        .map((match) => match[1]!);
    if (value.trim().isEmpty ||
        tokens.any(
          (token) => !const {
            'index',
            'title',
            'trackId',
            'album',
            'albumId',
          }.contains(token),
        ) ||
        value.replaceAll(RegExp(r'\{[^{}]+\}'), '').contains(RegExp(r'[{}]'))) {
      return '文件名格式包含无效变量，尚未保存';
    }
    return null;
  }

  Future<void> _directory() async {
    try {
      final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择下载目录');
      if (directory != null && mounted) await _set('rootDirectory', directory);
    } catch (_) {
      if (mounted) setState(() => _error = '无法选择下载目录，请重试');
    }
  }

  Future<void> _clearUrlCache() async {
    if (_clearingUrlCache) return;
    setState(() {
      _clearingUrlCache = true;
      _error = null;
    });
    try {
      final runtime = widget.runtime;
      await Future.wait([
        runtime.anonymous.clearUrlCache(),
        for (final id in runtime.accounts.accountIds)
          runtime.accounts.clientFor(id).clearUrlCache(),
      ]);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已清除所有 URL 缓存')));
    } catch (error) {
      if (mounted) setState(() => _error = 'URL 缓存清除失败：$error');
    } finally {
      if (mounted) setState(() => _clearingUrlCache = false);
    }
  }

  Widget _number(
    String key,
    String title,
    int fallback,
    int minimum,
    int maximum,
  ) => TextFormField(
    key: ValueKey(key),
    initialValue: '${_settings[key] ?? fallback}',
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: title,
      helperText: '$minimum–$maximum',
      errorMaxLines: 3,
    ),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: (text) {
      final value = int.tryParse(text ?? '');
      return value == null || value < minimum || value > maximum
          ? '请输入 $minimum–$maximum 的整数，当前输入尚未保存'
          : null;
    },
    onChanged: (text) {
      final value = int.tryParse(text);
      _editText(
        key,
        value != null && value >= minimum && value <= maximum ? value : null,
      );
    },
    onTapOutside: (_) {
      unawaited(_flushText());
      FocusManager.instance.primaryFocus?.unfocus();
    },
    onFieldSubmitted: (text) {
      final value = int.tryParse(text);
      if (value != null && value >= minimum && value <= maximum)
        _set(key, value);
    },
  );

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
        ),
        children: [
          AdaptiveText('下载', style: Theme.of(context).textTheme.titleLarge),
          const Text('有效输入会自动保存。'),
          const SizedBox(height: 16),
          if (_saving) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const Text('下载目录'),
          const SizedBox(height: 8),
          SelectableText(
            _settings['rootDirectory'] as String? ?? '首次下载时使用系统下载目录',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _directory,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择目录'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('按专辑建立文件夹'),
            value: _settings['albumFolders'] as bool? ?? true,
            onChanged: (value) => _set('albumFolders', value),
          ),
          _number('parallelism', '同时下载数量', 3, 1, 6),
          const SizedBox(height: 16),
          _number('retryLimit', '限流重试上限', 3, 0, 1000),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('限流后至少等待 5 分钟；0 表示不自动重试。'),
          ),
          _number('minimumFreeMiB', '最低剩余空间（MiB）', 512, 512, 1048576),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _settings['quality'] as String? ?? 'auto',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '音质'),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('自动（优先最高音质）')),
              DropdownMenuItem(value: 'm4a_128', child: Text('M4A 128 kbps')),
              DropdownMenuItem(value: 'm4a_64', child: Text('M4A 64 kbps')),
              DropdownMenuItem(value: 'mp3_64', child: Text('MP3 64 kbps')),
              DropdownMenuItem(value: 'mp3_32', child: Text('MP3 32 kbps')),
              DropdownMenuItem(value: 'm4a_24', child: Text('M4A 24 kbps')),
            ],
            onChanged: (value) {
              if (value != null) _set('quality', value);
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('filenamePattern'),
            initialValue:
                _settings['filenamePattern'] as String? ??
                '{index} - {title} [{trackId}]',
            decoration: const InputDecoration(
              labelText: '文件名格式',
              helperText: '{index} {title} {trackId} {album} {albumId}',
              helperMaxLines: 2,
              errorMaxLines: 3,
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: _filenameError,
            onChanged: (value) => _editText(
              'filenamePattern',
              _filenameError(value) == null ? value : null,
            ),
            onTapOutside: (_) {
              unawaited(_flushText());
              FocusManager.instance.primaryFocus?.unfocus();
            },
            onFieldSubmitted: (value) {
              if (_filenameError(value) == null) {
                _set('filenamePattern', value);
              }
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _settings['conflict'] as String? ?? 'skip',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '同名文件'),
            items: const [
              DropdownMenuItem(value: 'skip', child: Text('校验后跳过')),
              DropdownMenuItem(value: 'overwrite', child: Text('新文件完成后替换')),
              DropdownMenuItem(value: 'number', child: Text('自动加编号')),
            ],
            onChanged: (value) {
              if (value != null) _set('conflict', value);
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('暂停播放时同步暂停下载'),
            value: _settings['pauseDownloadWithPlayback'] as bool? ?? false,
            onChanged: (value) => _set('pauseDownloadWithPlayback', value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('定时结束后继续下载'),
            value: _settings['continueDownloadAfterSleep'] as bool? ?? false,
            onChanged: (value) => _set('continueDownloadAfterSleep', value),
          ),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link_off),
            title: Text('播放地址缓存'),
            subtitle: Text('清除所有账号及匿名播放地址，下次使用时重新获取；不删除已下载音频。'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _clearingUrlCache ? null : _clearUrlCache,
              icon: const Icon(Icons.delete_outline),
              label: Text(_clearingUrlCache ? '正在清除…' : '清除所有 URL 缓存'),
            ),
          ),
          if (Platform.isAndroid) ...[
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('后台运行 / 电池优化'),
              subtitle: Text(
                _batteryExempt == null
                    ? '正在读取系统状态…'
                    : _batteryExempt!
                    ? '已忽略电池优化。下载仍受系统后台启动限制和 Android 15+ 下载服务时限约束。'
                    : '尚未忽略电池优化。下载时使用进度通知；系统仍可能限制后台运行。',
              ),
              isThreeLine: true,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _requestingBattery || _batteryExempt != false
                    ? null
                    : _requestBatteryExemption,
                icon: const Icon(Icons.open_in_new),
                label: Text(_batteryExempt == true ? '已获系统豁免' : '申请忽略电池优化'),
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: AndroidBackgroundService.error,
              builder: (context, message, _) => message == null
                  ? const SizedBox.shrink()
                  : Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
            ),
          ],
        ],
      ),
    ),
  );
}
