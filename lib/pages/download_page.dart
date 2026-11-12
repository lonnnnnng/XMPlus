import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';

import '../common/widgets/adaptive_text.dart';
import '../services/app_runtime.dart';
import '../services/download_service.dart';
import '../models/xmly_models.dart';
import '../services/auto_download_service.dart';
import '../services/android_platform.dart';
import '../services/file_paths.dart';
import 'catalogue_page.dart';

Future<({String identity, bool polling})?> _chooseDownloadAccount(
  BuildContext context,
  AppRuntime runtime,
) async {
  final primary = runtime.accounts.primaryAccountId ?? 'anonymous';
  final accountIds = runtime.accounts.accountIds;
  var polling =
      ((runtime.storage.state['settings'] as Map)['download']
          as Map?)?['polling'] !=
      false;
  if (accountIds.isEmpty) return (identity: 'anonymous', polling: false);
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SimpleDialog(
        title: const Text('下载账号'),
        children: [
          SwitchListTile(
            title: const Text('轮询'),
            subtitle: const Text('请求失败时尝试下一个账号；扣时结果不明时停止'),
            value: polling,
            onChanged: (value) => setState(() => polling = value),
          ),
          for (final id in accountIds)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, id),
              child: Text(
                '账号 ${(runtime.storage.state['accounts'] as Map)[id]['uid']}'
                '${id == primary ? ' · 主账号' : ''}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'anonymous'),
            child: const Text('不登录（免费内容）'),
          ),
        ],
      ),
    ),
  );
  if (selected == null) return null;
  await runtime.storage.transaction((state) {
    final settings = state['settings'] as Map;
    final download =
        settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
    download['polling'] = polling;
  });
  return (identity: selected, polling: selected != 'anonymous' && polling);
}

Future<void> requestDownloads(
  BuildContext context,
  AppRuntime runtime,
  List<Track> tracks,
) async {
  final account = await _chooseDownloadAccount(context, runtime);
  if (account == null || !context.mounted) return;
  final batch = await runtime.prepareDownloads(
    tracks,
    accountIdentity: account.identity,
    polling: account.polling,
    previewBilling: false,
  );
  if (!context.mounted) return;
  if (batch.items.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('所选声音已在下载列表中')));
    return;
  }
  await runtime.downloads.enqueue(batch, confirmed: true);
}

Future<void> requestAlbumDownloads(
  BuildContext context,
  AppRuntime runtime,
  String albumId,
) async {
  final account = await _chooseDownloadAccount(context, runtime);
  if (account == null || !context.mounted) return;
  final batch = await runtime.prepareAlbumDownloads(
    albumId,
    accountIdentity: account.identity,
    polling: account.polling,
  );
  if (!context.mounted) return;
  await runtime.downloads.enqueue(batch, confirmed: true);
}

Future<bool> deleteDownloadedAudio(
  BuildContext context,
  AppRuntime runtime,
  DownloadTask task,
) async {
  final path = task.finalPath;
  if (path == null) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(
        '删除音频文件？',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SelectableText(path),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除文件'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await _deleteAudioGroup(runtime, [task]);
  return true;
}

String _audioPathKey(String path) => Platform.isWindows
    ? absoluteFilePath(path).toLowerCase()
    : absoluteFilePath(path);

Future<void> _deleteAudioGroup(
  AppRuntime runtime,
  List<DownloadTask> tasks, {
  void Function(int bytes)? onDeleted,
}) async {
  final path = tasks.first.finalPath!;
  final key = _audioPathKey(path);
  final ids = tasks.map((task) => task.id).toSet();
  void validate() {
    for (final expected in tasks) {
      final current = runtime.downloads.task(expected.id);
      if (current.state != DownloadState.completed ||
          current.finalPath != expected.finalPath ||
          current.accountIdentity != expected.accountIdentity ||
          current.track.id != expected.track.id) {
        throw const XmlyException('download_changed', '下载记录已变化，请重新选择后删除');
      }
    }
    if (runtime.downloads.tasks.any(
      (task) =>
          task.state == DownloadState.completed &&
          task.finalPath != null &&
          _audioPathKey(task.finalPath!) == key &&
          !ids.contains(task.id),
    )) {
      throw const XmlyException('shared_audio', '其他下载记录也引用此文件，请一并选择后删除');
    }
  }

  validate();
  for (final task in tasks) {
    await runtime.player.stopTaskReference(task.id);
  }
  validate();
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    for (final task in tasks) {
      await runtime.downloads.markAudioMissing(
        task.id,
        expectedPath: task.finalPath!,
      );
    }
    return;
  }
  if (type != FileSystemEntityType.file) {
    throw const XmlyException('audio_changed', '音频路径已不是普通文件，请检查下载目录');
  }
  final file = File(path);
  final bytes = await file.length();
  validate();
  await file.delete();
  onDeleted?.call(bytes);
  for (final task in tasks) {
    try {
      await runtime.downloads.markAudioDeleted(
        task.id,
        expectedPath: task.finalPath,
      );
    } catch (_) {
      throw const XmlyException(
        'audio_record_update_failed',
        '音频文件已删除，但记录更新未完成，请刷新后检查',
      );
    }
  }
}

Future<void> setAlbumAutoDownload(
  BuildContext context,
  AutoDownloadService service,
  String identity,
  String albumId,
  String title,
) async {
  if (service.enabled(identity, albumId)) {
    await service.setEnabled(identity, albumId, confirmed: false);
    return;
  }
  final account = (service.storage.state['accounts'] as Map)[identity];
  final label = account is Map && account['uid'] is String
      ? account['uid'] as String
      : identity;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(
        '自动下载新声音',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Text(
          '${title.isEmpty ? "此专辑" : title}\n账号 $label\n\n'
          '开启后，启动应用或打开专辑时检查更新，只下载开启后新增的声音，不补下已有集数。\n\n'
          '始终使用此账号及正常下载规则。奖励内容会逐集预扣整首听时，未来新增声音不再逐次询问；'
          '失败或取消不自动退回。余额不足、登录失效或扣时结果未知时停止，不切换账号或重试扣时。\n\n'
          '可随时关闭；已加入的任务和扣时记录保留。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('同意并开启'),
        ),
      ],
    ),
  );
  if (accepted == true && context.mounted)
    await service.setEnabled(identity, albumId, confirmed: true);
}

Future<bool> confirmDownloadBatch(
  BuildContext context,
  DownloadBatch batch,
) async {
  if (batch.items.isEmpty && batch.albumId == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('所选声音已在下载列表中')));
    return false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(
            batch.albumId == null ? '下载 ${batch.items.length} 集' : '下载整个专辑',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (batch.albumId != null) ...[
                  Text(
                    '共 ${batch.albumTotalCount ?? "未知"} 集，首批 ${batch.items.length} 集。'
                    '当前页处理结束后再请求下一页，单集失败不影响其余声音。',
                  ),
                  const SizedBox(height: 8),
                  const Text('后续每页继续按正常规则逐集扣时；已下载声音自动跳过，可随时暂停。'),
                  const SizedBox(height: 8),
                ],
                Text(
                  batch.totalSeconds == 0
                      ? '本批预览无需扣除奖励听时'
                      : '本批预计扣除 ${batch.totalSeconds} 秒（按实际使用的账号逐集扣除）',
                ),
                if (batch.totalSeconds > 0) ...[
                  const SizedBox(height: 8),
                  const Text('逐集扣除整首时长，下载失败或取消不自动退回。原任务重试不会重复扣时。'),
                ],
                if (batch.items.isNotEmpty) const SizedBox(height: 12),
                if (batch.items.isNotEmpty)
                  SizedBox(
                    height: (batch.items.length * 72.0).clamp(72.0, 260.0),
                    child: Scrollbar(
                      child: ListView.builder(
                        itemCount: batch.items.length,
                        itemBuilder: (_, index) {
                          final item = batch.items[index];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              item.track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.error ??
                                  '${item.accountIdentity != batch.accountIdentity ? "已切换账号 · " : ""}${item.seconds} 秒',
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(batch.totalSeconds > 0 ? '确认扣时并下载' : '下载'),
            ),
          ],
        ),
      ) ==
      true;
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({required this.runtime, super.key});
  final AppRuntime runtime;
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadService get _service => widget.runtime.downloads;
  AutoDownloadService get _autoDownloads => widget.runtime.autoDownloads;
  String? _error;
  String? _availabilityKey;
  int _availabilityEpoch = 0;
  bool _refreshingAvailability = false;
  Map<String, bool> _available = const {};
  final _expandedAlbums = <String>{};
  final _selectedDownloads = <String>{};
  bool _selectingDownloads = false, _deletingAudio = false;
  int _deletionDone = 0, _deletionTotal = 0;
  final _downloadQuery = TextEditingController();
  Timer? _searchDebounce;
  String _downloadFilter = '';
  StreamSubscription<void>? _taskChanges;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _taskChanges = _service.changes.listen((_) => _tasksChanged());
    widget.runtime.albumCache.addListener(_cacheChanged);
    unawaited(_refreshAvailability(_service.tasks));
  }

  void _tasksChanged() {
    if (!mounted) return;
    final tasks = _service.tasks;
    setState(() {
      if (_selectedDownloads.isNotEmpty) {
        _selectedDownloads.retainAll(
          tasks.where(_canSelectAudio).map((task) => task.id),
        );
      }
    });
    if (!_deletingAudio) unawaited(_refreshAvailability(tasks));
  }

  void _cacheChanged() {
    _availabilityKey = null;
    _tasksChanged();
  }

  @override
  void didUpdateWidget(covariant DownloadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime == widget.runtime) return;
    unawaited(_taskChanges?.cancel());
    oldWidget.runtime.albumCache.removeListener(_cacheChanged);
    _availabilityKey = null;
    _available = const {};
    _selectedDownloads.clear();
    _selectingDownloads = false;
    _listen();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _downloadQuery.dispose();
    unawaited(_taskChanges?.cancel());
    widget.runtime.albumCache.removeListener(_cacheChanged);
    super.dispose();
  }

  Future<void> _refreshAvailability(List<DownloadTask> tasks) async {
    final key = tasks
        .map((task) => '${task.id}:${task.finalPath}:${task.state.name}')
        .join('|');
    if (key == _availabilityKey) return;
    _availabilityKey = key;
    final epoch = ++_availabilityEpoch;
    final paths = {
      for (final task in tasks)
        if (task.finalPath != null) task.id: task.finalPath!,
    };
    final result = <String, bool>{};
    for (final entry in paths.entries) {
      try {
        result[entry.key] = await File(entry.value).exists();
      } on FileSystemException {
        result[entry.key] = false;
      }
    }
    if (mounted && epoch == _availabilityEpoch && key == _availabilityKey) {
      setState(() => _available = result);
    }
  }

  Future<void> _recheckAvailability() async {
    if (_refreshingAvailability || _deletingAudio) return;
    setState(() => _refreshingAvailability = true);
    try {
      _availabilityKey = null;
      await _refreshAvailability(_service.tasks);
    } finally {
      if (mounted) setState(() => _refreshingAvailability = false);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) setState(() => _error = null);
    } on XmlyException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，任务和文件已保留');
    }
  }

  Future<void> _retry(DownloadTask task) async {
    task = _service.task(task.id);
    if (task.state == DownloadState.awaitingDebit && task.needsConfirmation) {
      // Drain the worker that reported the changed fee before preparing again.
      await widget.runtime.pauseDownload(task.id);
      task = _service.task(task.id);
    }
    if (task.state != DownloadState.failed &&
        task.state != DownloadState.paused &&
        task.state != DownloadState.cancelled)
      return;
    if (task.processingFailed) {
      await _service.retry(task.id);
      return;
    }
    if (task.needsConfirmation || !task.userConfirmed) {
      final batch = await _service.prepareRetry(task.id);
      if (!mounted) return;
      await _service.enqueue(batch, confirmed: true);
    } else {
      await _service.retry(task.id);
    }
  }

  Future<void> _adjustProcessing(DownloadTask task) async {
    var format =
        (task.settings['media'] as Map?)?['format'] as String? ?? 'original';
    var bitrate =
        (task.settings['media'] as Map?)?['bitrateKbps'] as int? ?? 64;
    var conflict =
        (task.settings['download'] as Map?)?['conflict'] as String? ?? 'skip';
    var currentTools = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text(
            '调整处理',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('仅重跑处理，不重新取流或扣时。'),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: format,
                    items: const [
                      DropdownMenuItem(value: 'original', child: Text('原格式')),
                      DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                      DropdownMenuItem(value: 'm4a', child: Text('M4A')),
                      DropdownMenuItem(value: 'm4b', child: Text('M4B')),
                      DropdownMenuItem(value: 'flac', child: Text('FLAC')),
                    ],
                    onChanged: (value) => update(() {
                      format = value!;
                    }),
                  ),
                  if (format != 'original' && format != 'flac')
                    DropdownButton<int>(
                      isExpanded: true,
                      value: bitrate,
                      items: [
                        for (final value in [32, 64, 96, 128, 192])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value kbps'),
                          ),
                      ],
                      onChanged: (value) => update(() {
                        bitrate = value!;
                      }),
                    ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: conflict,
                    items: const [
                      DropdownMenuItem(
                        value: 'skip',
                        child: Text(
                          '同名：校验后跳过',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'overwrite',
                        child: Text(
                          '同名：新文件完成后替换',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'number',
                        child: Text(
                          '同名：自动加编号',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) => update(() {
                      conflict = value!;
                    }),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: currentTools,
                    title: const Text('使用当前工具路径'),
                    onChanged: (value) => update(() {
                      currentTools = value!;
                    }),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并重试'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true)
      await _service.reprocess(
        task.id,
        format: format,
        bitrateKbps: bitrate,
        conflict: conflict,
        useCurrentTools: currentTools,
      );
  }

  Future<void> _reacquire(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text(
          '重新获取音频？',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text('${task.track.title}\n清除本任务缓存并重新核验权限，成品和扣时记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新获取'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await widget.runtime.reacquireDownload(task.id);
  }

  Future<void> _relocate(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('更换目录', maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SelectableText(
          '${task.track.title}\n${task.rootDirectory}\n旧缓存不自动移动，原扣时记录保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择目录'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择本任务的下载目录',
    );
    if (directory == null) return;
    await widget.runtime.relocateDownload(task.id, directory);
  }

  Future<void> _cancel(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text(
          '取消此任务？',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: const Text('缓存和已扣听时记录会保留，不自动退款。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.runtime.cancelDownload(task.id);
  }

  Future<void> _open(DownloadTask task) async {
    final path = task.finalPath == null
        ? task.rootDirectory
        : p.dirname(task.finalPath!);
    if (!await Directory(path).exists())
      throw const FileSystemException('Directory missing');
    if (Platform.isAndroid) {
      if (task.finalPath case final file?) {
        await AndroidPlatform.openAudioFile(file);
      } else if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text(
              '下载目录',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            content: SelectableText(path),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final executable = Platform.isWindows
        ? 'explorer.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    await Process.start(executable, [path], runInShell: false);
  }

  Future<void> _delete(DownloadTask task) async {
    if (_deletingAudio) return;
    setState(() => _deletingAudio = true);
    try {
      if (await deleteDownloadedAudio(context, widget.runtime, task)) {
        _availabilityKey = null;
        await _refreshAvailability(_service.tasks);
      }
    } finally {
      if (mounted) setState(() => _deletingAudio = false);
    }
  }

  bool _canSelectAudio(DownloadTask task) =>
      task.state == DownloadState.completed && task.finalPath != null;

  void _selectAudio(Iterable<DownloadTask> tasks) {
    if (_deletingAudio) return;
    final ids = tasks.where(_canSelectAudio).map((task) => task.id).toSet();
    if (ids.isEmpty) return;
    setState(() {
      _selectingDownloads = true;
      if (ids.every(_selectedDownloads.contains)) {
        _selectedDownloads.removeAll(ids);
      } else {
        _selectedDownloads.addAll(ids);
      }
    });
  }

  Future<void> _deleteSelectedAudio() async {
    if (_deletingAudio || _selectedDownloads.isEmpty) return;
    final runtime = widget.runtime;
    final groups = <String, List<DownloadTask>>{};
    for (final task in _service.tasks.where(_canSelectAudio)) {
      if (_selectedDownloads.contains(task.id)) {
        groups.putIfAbsent(_audioPathKey(task.finalPath!), () => []).add(task);
      }
    }
    if (groups.isEmpty) return;
    setState(() {
      _deletingAudio = true;
      _deletionDone = 0;
      _deletionTotal = 0;
    });
    try {
      var estimatedBytes = 0, unknownSizes = 0;
      for (final tasks in groups.values) {
        try {
          final stat = await File(tasks.first.finalPath!).stat();
          if (stat.type == FileSystemEntityType.file) {
            estimatedBytes += stat.size;
          } else {
            unknownSizes++;
          }
        } on FileSystemException {
          unknownSizes++;
        }
      }
      if (!mounted || widget.runtime != runtime) return;
      final count = groups.values.fold<int>(
        0,
        (sum, tasks) => sum + tasks.length,
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text('删除 $count 条声音的音频？'),
          content: Text(
            '共 ${groups.length} 个路径，预计释放 ${_bytes(estimatedBytes)}'
            '${unknownSizes > 0 ? "（另有 $unknownSizes 个路径大小未知或文件已缺失）" : ""}。\n\n'
            '正在使用这些文件的播放会停止。任务和扣时记录保留；缺失文件不会记为主动删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除所选音频'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || widget.runtime != runtime) return;
      setState(() => _deletionTotal = groups.length);
      var freedBytes = 0, deletedFiles = 0;
      final failures = <String>[];
      final cleared = <String>{};
      for (final tasks in groups.values) {
        try {
          await _deleteAudioGroup(
            runtime,
            tasks,
            onDeleted: (bytes) {
              freedBytes += bytes;
              deletedFiles++;
            },
          );
          cleared.addAll(tasks.map((task) => task.id));
        } catch (error) {
          failures.add(
            '${tasks.first.track.title}：${error is XmlyException ? error.message : "删除或记录更新未完成，请刷新后重试"}',
          );
        }
        if (mounted && widget.runtime == runtime)
          setState(() => _deletionDone++);
      }
      if (!mounted || widget.runtime != runtime) return;
      setState(() {
        _selectedDownloads.removeAll(cleared);
        if (_selectedDownloads.isEmpty) _selectingDownloads = false;
        _error = failures.isEmpty
            ? null
            : '${failures.length} 个路径未完全处理；已删除文件不会恢复。\n${failures.take(3).join("\n")}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已删除 $deletedFiles 个文件，释放 ${_bytes(freedBytes)}；${failures.length} 项未完成',
          ),
        ),
      );
      _availabilityKey = null;
      await _refreshAvailability(_service.tasks);
    } finally {
      if (mounted) setState(() => _deletingAudio = false);
    }
  }

  Future<void> _openAlbum(String albumId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AlbumPageView(
          runtime: widget.runtime,
          albumId: albumId,
          onDownload: (tracks) =>
              requestDownloads(context, widget.runtime, tracks),
          onPlayAlbum: widget.runtime.player.playAlbum,
        ),
      ),
    );
    if (!mounted) return;
    _availabilityKey = null;
    await _refreshAvailability(_service.tasks);
  }

  Widget _albumCard(
    String albumId,
    List<DownloadTask> tasks,
    bool compact, {
    required bool downloaded,
  }) {
    final cached = albumId.isEmpty ? null : widget.runtime.albumCache[albumId];
    final album = cached?.album;
    final total = album?.total ?? 0;
    late final completed = {
      for (final task in tasks)
        if (_available[task.id] == true) task.track.id,
    }.length;
    final missing = downloaded
        ? tasks
              .where(
                (task) =>
                    task.finalPath == null || _available[task.id] == false,
              )
              .length
        : 0;
    final states = <DownloadState, int>{};
    for (final task in tasks) {
      states.update(task.state, (count) => count + 1, ifAbsent: () => 1);
    }
    final summary = [
      for (final entry in states.entries) '${_state(entry.key)} ${entry.value}',
      if (missing > 0) '文件缺失 $missing',
    ].join(' · ');
    final title = albumId.isEmpty
        ? '未归属专辑的声音'
        : album != null && album.title.isNotEmpty
        ? album.title
        : tasks.first.track.album.isNotEmpty
        ? tasks.first.track.album
        : '专辑 $albumId';
    final expansionKey = '${downloaded ? 'downloaded' : 'tasks'}:$albumId';
    final expanded = _expandedAlbums.contains(expansionKey);
    late final selectable = tasks.where(_canSelectAudio).toList();
    late final selected = selectable
        .where((task) => _selectedDownloads.contains(task.id))
        .length;
    final selecting = downloaded && _selectingDownloads;
    void toggle() => setState(() {
      if (expanded) {
        _expandedAlbums.remove(expansionKey);
      } else {
        _expandedAlbums.add(expansionKey);
      }
    });
    return Card(
      margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: 6),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 16,
              vertical: 6,
            ),
            leading: selecting
                ? Checkbox(
                    tristate: true,
                    value: selected == 0
                        ? false
                        : selected == selectable.length
                        ? true
                        : null,
                    onChanged: _deletingAudio || selectable.isEmpty
                        ? null
                        : (_) => _selectAudio(selectable),
                  )
                : compact
                ? null
                : CoverImage(
                    uri: album?.coverUrl ?? tasks.first.track.coverUrl,
                    localPath: cached?.coverPath,
                    size: 52,
                    downloaded: downloaded && completed > 0,
                  ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (downloaded)
                  Text(
                    '$completed / ${total > 0 ? total : "总集数未知"} 集已下载',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                if (downloaded && total > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: LinearProgressIndicator(
                      value: (completed / total).clamp(0.0, 1.0),
                    ),
                  ),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            onTap: selecting
                ? (_deletingAudio ? null : () => _selectAudio(selectable))
                : albumId.isEmpty
                ? toggle
                : () => _run(() => _openAlbum(albumId)),
            onLongPress: downloaded && !_deletingAudio
                ? () => _selectAudio(selectable)
                : null,
            trailing: IconButton(
              tooltip: expanded ? '收起声音与操作' : '展开声音与操作',
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: toggle,
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            SizedBox(
              height: (tasks.length * (downloaded ? 80.0 : 260.0))
                  .clamp(80.0, 400.0)
                  .toDouble(),
              child: ListView.builder(
                primary: false,
                itemCount: tasks.length,
                itemBuilder: (_, index) => downloaded
                    ? _downloadedTrack(tasks[index], compact)
                    : _taskCard(tasks[index], compact),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _downloadedTrack(
    DownloadTask task,
    bool compact, {
    bool searchResult = false,
  }) {
    final available = _available[task.id] == true;
    return ListTile(
      selected: _selectingDownloads && _selectedDownloads.contains(task.id),
      leading: _selectingDownloads
          ? Checkbox(
              value: _selectedDownloads.contains(task.id),
              onChanged: _deletingAudio || !_canSelectAudio(task)
                  ? null
                  : (_) => _selectAudio([task]),
            )
          : compact
          ? null
          : CoverImage(
              uri: searchResult ? null : task.track.coverUrl,
              localPath: task.track.albumId.isEmpty
                  ? null
                  : widget.runtime.albumCache[task.track.albumId]?.coverPath,
              downloaded: available,
              size: 44,
            ),
      title: AdaptiveText(task.track.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (searchResult)
            Text(
              _downloadAlbumTitle(task),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            _available.containsKey(task.id)
                ? (available ? '已下载' : '音频文件已不存在')
                : '正在检查本地文件',
          ),
        ],
      ),
      onLongPress: _deletingAudio ? null : () => _selectAudio([task]),
      onTap: _deletingAudio
          ? null
          : _selectingDownloads
          ? () => _selectAudio([task])
          : available
          ? () => _run(() => widget.runtime.player.playLocal(task.id))
          : null,
      trailing: PopupMenuButton<String>(
        enabled: !_deletingAudio && !_selectingDownloads,
        tooltip: '已下载声音操作',
        onSelected: (action) => _run(() async {
          switch (action) {
            case 'play':
              await widget.runtime.player.playLocal(task.id);
            case 'next':
              await widget.runtime.player.playNext(task.track);
            case 'open':
              await _open(task);
            case 'delete':
              await _delete(task);
          }
        }),
        itemBuilder: (_) => [
          if (available) const PopupMenuItem(value: 'play', child: Text('播放')),
          if (available)
            const PopupMenuItem(value: 'next', child: Text('下一集播放')),
          const PopupMenuItem(value: 'open', child: Text('打开目录')),
          if (available)
            const PopupMenuItem(value: 'delete', child: Text('删除音频')),
        ],
      ),
    );
  }

  Future<void> _cancelAlbum(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消整专辑下载？'),
        content: const Text('停止后续分页；已创建的任务、缓存和扣时记录保留，不自动退款。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消专辑任务'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.cancelAlbum(id);
  }

  String _downloadAlbumTitle(DownloadTask task) {
    final id = task.track.albumId;
    final cached = id.isEmpty
        ? null
        : widget.runtime.albumCache[id]?.album.title;
    if (cached != null && cached.isNotEmpty) return cached;
    if (task.track.album.isNotEmpty) return task.track.album;
    return id.isEmpty ? '未归属专辑的声音' : '专辑 $id';
  }

  void _searchDownloads(String text, {bool immediately = false}) {
    _searchDebounce?.cancel();
    void apply() {
      if (mounted) setState(() => _downloadFilter = text.trim().toLowerCase());
    }

    if (immediately) {
      apply();
    } else {
      _searchDebounce = Timer(const Duration(milliseconds: 180), apply);
    }
  }

  Widget _downloadedLibrary(List<DownloadTask> completed) {
    final compact = MediaQuery.sizeOf(context).width < 320;
    final query = _downloadFilter;
    final tokens = query
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty);
    final matches = query.isEmpty
        ? const <DownloadTask>[]
        : completed.where((task) {
            final track = task.track;
            final text = [
              _downloadAlbumTitle(task),
              track.album,
              track.title,
              for (final ordinal in {
                track.officialPosition,
                track.orderNo,
                track.episode,
              }.whereType<int>())
                '$ordinal 第${ordinal}集',
            ].join(' ').toLowerCase();
            return tokens.every(text.contains);
          }).toList();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 16,
            12,
            compact ? 8 : 16,
            8,
          ),
          child: TextField(
            key: const ValueKey('downloadLibrarySearch'),
            controller: _downloadQuery,
            decoration: InputDecoration(
              labelText: '搜索已下载',
              hintText: '专辑、单集标题或集号',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _downloadQuery,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: '清除本地搜索',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _downloadQuery.clear();
                          _searchDownloads('', immediately: true);
                        },
                      ),
              ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: _searchDownloads,
            onSubmitted: (text) => _searchDownloads(text, immediately: true),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed:
                  _refreshingAvailability || _deletingAudio || completed.isEmpty
                  ? null
                  : () => _run(_recheckAvailability),
              icon: _refreshingAvailability
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_refreshingAvailability ? '正在检查' : '刷新本地文件'),
            ),
            if (!_selectingDownloads)
              OutlinedButton.icon(
                onPressed: _deletingAudio || completed.isEmpty
                    ? null
                    : () => setState(() => _selectingDownloads = true),
                icon: const Icon(Icons.checklist),
                label: const Text('多选音频'),
              )
            else ...[
              Text('已选 ${_selectedDownloads.length} 条'),
              TextButton(
                onPressed: _deletingAudio
                    ? null
                    : () => _selectAudio(completed),
                child: const Text('全选／取消全选'),
              ),
              FilledButton.icon(
                onPressed: _deletingAudio || _selectedDownloads.isEmpty
                    ? null
                    : () => _run(_deleteSelectedAudio),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除所选音频'),
              ),
              TextButton(
                onPressed: _deletingAudio
                    ? null
                    : () => setState(() {
                        _selectingDownloads = false;
                        _selectedDownloads.clear();
                      }),
                child: const Text('取消多选'),
              ),
            ],
          ],
        ),
        if (_deletingAudio) ...[
          LinearProgressIndicator(
            value: _deletionTotal == 0 ? null : _deletionDone / _deletionTotal,
          ),
          Text(
            _deletionTotal == 0
                ? '正在准备删除'
                : '正在处理 $_deletionDone / $_deletionTotal 个路径',
          ),
        ],
        if (query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '本地下载记录：匹配 ${matches.length} / 共 ${completed.length} 条',
            ),
          ),
        if (query.isNotEmpty && _error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: query.isEmpty
              ? _albumList(completed, downloaded: true)
              : matches.isEmpty
              ? const Center(child: Text('未找到匹配的本地下载记录'))
              : Scrollbar(
                  child: ListView.builder(
                    key: ValueKey('downloadSearch:$query'),
                    itemCount: matches.length,
                    itemBuilder: (context, index) => _downloadedTrack(
                      matches[index],
                      compact,
                      searchResult: true,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _albumList(Iterable<DownloadTask> tasks, {required bool downloaded}) {
    final compact = MediaQuery.sizeOf(context).width < 320;
    final groups = <String, List<DownloadTask>>{};
    for (final task in tasks) {
      groups.putIfAbsent(task.track.albumId, () => []).add(task);
    }
    if (downloaded) {
      for (final group in groups.entries) {
        if (group.key.isEmpty) continue;
        final originalOrder = {
          for (var index = 0; index < group.value.length; index++)
            group.value[index].id: index,
        };
        int? position(DownloadTask task) =>
            task.track.officialPosition ??
            xmlyPositive(task.track.orderNo) ??
            xmlyPositive(task.track.episode);
        group.value.sort((a, b) {
          final left = position(a), right = position(b);
          if (left != null && right != null && left != right) {
            return left.compareTo(right);
          }
          if ((left == null) != (right == null)) return left == null ? 1 : -1;
          return originalOrder[a.id]!.compareTo(originalOrder[b.id]!);
        });
      }
    }
    final albums = groups.entries.toList();
    final jobs = downloaded
        ? const <DownloadAlbumJob>[]
        : _service.albumJobs
              .where(
                (job) => job.state != 'completed' && job.state != 'cancelled',
              )
              .toList();
    return Scrollbar(
      child: ListView.builder(
        key: PageStorageKey(
          downloaded ? 'downloaded-albums' : 'download-tasks',
        ),
        itemCount: albums.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) {
            final group = albums[index - 1];
            return _albumCard(
              group.key,
              group.value,
              compact,
              downloaded: downloaded,
            );
          }
          return Padding(
            padding: EdgeInsets.all(compact ? 8 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!downloaded) ...[
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _run(widget.runtime.pauseAllDownloads),
                        icon: const Icon(Icons.pause),
                        label: const Text('全部暂停'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _run(_service.resumeAll),
                        icon: const Icon(Icons.download),
                        label: const Text('全部继续'),
                      ),
                    ],
                  ),
                  for (final job in jobs)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AdaptiveText('${job.title} · 整专辑下载'),
                            Text('第 ${job.page} 页 · ${job.total} 集'),
                            if (job.error != null) Text(job.error!),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (job.state == 'queued' ||
                                    job.state == 'running')
                                  TextButton(
                                    onPressed: () =>
                                        _run(() => _service.pauseAlbum(job.id)),
                                    child: const Text('暂停专辑'),
                                  )
                                else
                                  TextButton(
                                    onPressed: () => _run(
                                      () => _service.resumeAlbum(job.id),
                                    ),
                                    child: Text(
                                      job.state == 'failed' ? '重试专辑' : '继续专辑',
                                    ),
                                  ),
                                if (job.state == 'failed' ||
                                    job.state == 'paused')
                                  TextButton(
                                    onPressed: () => _run(
                                      () => _service.refreshAlbum(job.id),
                                    ),
                                    child: const Text('刷新目录并继续'),
                                  ),
                                TextButton(
                                  onPressed: () =>
                                      _run(() => _cancelAlbum(job.id)),
                                  child: const Text('取消专辑任务'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                for (final error in [
                  if (_error != null) _error!,
                  if (!downloaded) ..._autoDownloads.errors,
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (albums.isEmpty && (downloaded || jobs.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(downloaded ? '暂无已下载内容' : '暂无下载任务'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: _autoDownloads.changes,
    builder: (context, _) {
      final tasks = _service.tasks;
      final completed = tasks
          .where((task) => task.state == DownloadState.completed)
          .toList();
      return DefaultTabController(
        length: 2,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: '下载任务'),
                    Tab(text: '已下载'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _albumList(
                        tasks.where(
                          (task) => task.state != DownloadState.completed,
                        ),
                        downloaded: false,
                      ),
                      _downloadedLibrary(completed),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _taskCard(DownloadTask task, bool compact) {
    final total = task.totalBytes;
    final progress = total == null || total <= 0
        ? null
        : (task.receivedBytes / total).clamp(0.0, 1.0);
    final remaining = total == null || task.bytesPerSecond <= 0
        ? null
        : ((total - task.receivedBytes).clamp(0, total) / task.bytesPerSecond)
              .ceil();
    return Card(
      margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: 6),
      child: Padding(
        padding: EdgeInsets.all(compact ? 8 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              task.track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${task.track.album} · ${_state(task.state)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            if (task.error != null)
              Text(
                task.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (task.state == DownloadState.downloading ||
                task.state == DownloadState.processing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: task.state == DownloadState.processing ? null : progress,
              ),
            ],
            const SizedBox(height: 8),
            AdaptiveText(
              '${_bytes(task.receivedBytes)} / ${total == null ? "未知" : _bytes(total)} · ${_bytes(task.bytesPerSecond.round())}/s${remaining == null ? "" : " · 剩余 ${remaining}s"}',
            ),
            if (task.retryAt != null)
              AdaptiveText(
                '下次重试 ${task.retryAt!.toLocal().toString().split(".").first}',
              ),
            if (task.actualQuality != null)
              AdaptiveText('实际音质：${task.actualQuality}'),
            if (task.warning != null)
              Text(
                task.warning!,
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (task.state == DownloadState.awaitingDebit &&
                    task.needsConfirmation)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: const Text('重新获取'),
                  ),
                if (task.active &&
                    !(task.state == DownloadState.awaitingDebit &&
                        task.needsConfirmation))
                  TextButton(
                    onPressed: () =>
                        _run(() => widget.runtime.pauseDownload(task.id)),
                    child: const Text('暂停'),
                  ),
                if (task.state == DownloadState.paused)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: Text(
                      task.needsConfirmation && !task.processingFailed
                          ? '重新获取'
                          : '继续',
                    ),
                  ),
                if (task.state == DownloadState.failed)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: Text(
                      task.needsConfirmation
                          ? '重新获取'
                          : task.processingFailed
                          ? '重试处理'
                          : '重试',
                    ),
                  ),
                if (task.state == DownloadState.cancelled)
                  TextButton(
                    onPressed: () => _run(() => _retry(task)),
                    child: Text(task.processingFailed ? '恢复并重试处理' : '恢复任务'),
                  ),
                if (task.processingFailed &&
                    (task.state == DownloadState.failed ||
                        task.state == DownloadState.paused ||
                        task.state == DownloadState.cancelled))
                  TextButton(
                    onPressed: () => _run(() => _reacquire(task)),
                    child: const Text('重新获取音频'),
                  ),
                if (task.processingFailed &&
                    (task.state == DownloadState.failed ||
                        task.state == DownloadState.paused ||
                        task.state == DownloadState.cancelled))
                  TextButton(
                    onPressed: () => _run(() => _adjustProcessing(task)),
                    child: const Text('调整处理'),
                  ),
                if (task.state != DownloadState.completed &&
                    task.state != DownloadState.cancelled)
                  TextButton(
                    onPressed: () => _run(() => _cancel(task)),
                    child: const Text('取消'),
                  ),
                if (!task.active && task.state != DownloadState.completed)
                  TextButton(
                    onPressed: () => _run(() => _relocate(task)),
                    child: const Text('更换目录'),
                  ),
                TextButton(
                  onPressed: () => _run(() => _open(task)),
                  child: const Text('打开目录'),
                ),
                if (task.finalPath != null)
                  TextButton(
                    onPressed: () => _run(() => _delete(task)),
                    child: const Text('删除音频'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _bytes(int value) => value < 1024
    ? '${value}B'
    : value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)}KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)}MiB';
String _state(DownloadState state) => switch (state) {
  DownloadState.queued => '等待中',
  DownloadState.awaitingDebit => '等待扣时确认',
  DownloadState.downloading => '下载中',
  DownloadState.paused => '已暂停',
  DownloadState.processing => '处理中',
  DownloadState.completed => '已完成',
  DownloadState.failed => '失败',
  DownloadState.cancelled => '已取消',
};
