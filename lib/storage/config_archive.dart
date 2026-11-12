// ZIP layout adapted from PiliPlus lib/utils/config_archive.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import '../models/download_task.dart';
import '../services/account_service.dart';
import '../services/playback_policy.dart';
import '../services/download_service.dart' show DownloadAlbumJob;
import '../services/usage_ledger.dart';
import 'app_storage.dart';
import 'credential_store.dart';

class ConfigArchiveException implements Exception {
  const ConfigArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A fully parsed and candidate-validated preview. Secrets are never exposed in
/// the summary; the private payload cannot be modified between preview/restore.
class ArchiveImport {
  ArchiveImport._(
    this._payload,
    this._owner,
    this.sameOrigin,
    List<String> summary,
    Iterable<String> missingDirectories,
  ) : summary = List.unmodifiable(summary),
      missingDirectories = List.unmodifiable(missingDirectories);
  final String _payload;
  final ConfigArchive _owner;
  final bool sameOrigin;
  final List<String> summary;
  final List<String> missingDirectories;
}

class ConfigArchive {
  ConfigArchive({
    required this.storage,
    required this.accounts,
    required this.secrets,
  });
  final AppStorage storage;
  final AccountService accounts;
  final CredentialStore secrets;
  static const maxBytes = 64 * 1024 * 1024;
  static const _members = {
    'meta.json',
    'setting.json',
    'library.json',
    'account.json',
  };
  static const _rootKeys = {
    'root',
    'rootDirectory',
    'downloadRoot',
    'downloadDirectory',
  };
  static const _secretKeys = {
    'token',
    'device_id',
    'deviceId',
    'cookie',
    'cookie2',
    'headers',
    'x-tk',
    'password',
    'verificationCode',
    'credentialRef',
    'credentialCleanup',
    'cacheIdentity',
    'challenge',
    'captcha',
    'smsCode',
  };
  static const _transientKeys = {
    'url',
    'uri',
    'audioUrl',
    'playUrl',
    'signedUrl',
    'resolvedAudio',
    'outputPath',
    'filePath',
    'cachePath',
    'cacheDirectory',
    'temporaryPath',
    'partialPath',
    'finalPath',
    'destination',
    'localPath',
  };
  String get _origin =>
      sha256.convert(utf8.encode(storage.directory)).toString();

  Future<List<int>> export({bool includeAccount = false}) async {
    final state = storage.state;
    final tasks = {
      'downloads': _clean(state['downloads']),
      'downloadAlbums': _clean(state['downloadAlbums'] ?? const []),
      'queue': _clean(state['queue']),
    };
    final files = <String, Object?>{
      'setting.json': _clean(state['settings']),
      'library.json': {
        'library': _clean(state['library']),
        if (!includeAccount) ...tasks,
      },
    };
    if (includeAccount) {
      final records = <Map<String, dynamic>>[];
      for (final entry in (state['accounts'] as Map).entries) {
        final record = entry.value as Map;
        Map<String, dynamic>? pair;
        final ref = record['credentialRef'];
        if (ref is String) {
          final encoded = await secrets.read(ref);
          if (encoded == null)
            throw const ConfigArchiveException('安全凭据缺失，未导出备份');
          final credentials = Credentials.parse(encoded);
          if (credentials.identity != entry.key) {
            throw const ConfigArchiveException('账号资料不一致，未导出备份');
          }
          pair = credentials.toJson();
        }
        records.add({
          'identity': entry.key,
          'record': _clean(record),
          if (pair != null) 'credentials': pair,
        });
      }
      files['account.json'] = {
        'accounts': records,
        'primaryAccountId': state['primaryAccountId'],
        ...tasks,
      };
    }
    files['meta.json'] = {
      'type': 'data_archive',
      'formatVersion': 65536,
      'appName': 'XMPlus',
      'versionCode': 1,
      'versionName': '1.0.0',
      'platform': Platform.operatingSystem,
      'exportTime': DateTime.now().toUtc().toIso8601String(),
      'origin': _origin,
      'files': files.keys.toList(),
    };
    final archive = Archive();
    var total = 0;
    for (final entry in files.entries) {
      final content = utf8.encode(jsonEncode(entry.value));
      total += content.length;
      if (total > maxBytes) throw const ConfigArchiveException('备份超过 64 MiB');
      archive.add(ArchiveFile(entry.key, content.length, content));
    }
    final bytes = ZipEncoder().encode(archive);
    if (bytes.length > maxBytes)
      throw const ConfigArchiveException('备份超过 64 MiB');
    return bytes;
  }

  Future<ArchiveImport> inspect(List<int> bytes) async {
    final Map<String, dynamic> payload;
    try {
      if (bytes.length > maxBytes || bytes.isEmpty)
        throw const FormatException();
      // Inspect the central directory before any entry can be inflated. archive
      // 4.6 also limits inflation to the declared size and verifies local headers.
      final directory = ZipDirectory();
      final names = <String>{};
      var total = 0;
      for (final header in directory.headers(
        InputMemoryStream(bytes),
        verify: true,
        files: false,
      )) {
        if (!_members.contains(header.filename) ||
            !names.add(header.filename) ||
            names.length > _members.length ||
            header.generalPurposeBitFlag & 1 != 0 ||
            !{0, 8}.contains(header.compressionMethod) ||
            header.diskNumberStart != 0 ||
            (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
            header.uncompressedSize < 0 ||
            header.compressedSize < 0) {
          throw const FormatException();
        }
        total += header.uncompressedSize;
        if (total > maxBytes) throw const FormatException();
      }
      if (!names.contains('meta.json') ||
          names.length < 2 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0) {
        throw const FormatException();
      }
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      payload = {};
      var actual = 0;
      for (final file in archive) {
        if (!file.isFile || file.isSymbolicLink || !names.contains(file.name))
          throw const FormatException();
        final content = file.content;
        actual += content.length;
        if (content.length != file.size || actual > maxBytes)
          throw const FormatException();
        final decoded = jsonDecode(utf8.decode(content));
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        payload[file.name] = decoded;
      }
      _validate(payload, names);
    } catch (_) {
      throw const ConfigArchiveException('备份无效、已损坏，或超过 64 MiB；仅支持 XMPlus 备份');
    }
    // No mutation, SMS, claim or report: candidate verification is config only.
    final account = payload['account.json'] as Map?;
    for (final record in account?['accounts'] as List? ?? const []) {
      if ((record as Map)['credentials'] == null) continue;
      final pair = Credentials.parse(record['credentials']);
      final client = XmlyClient(credentials: pair);
      try {
        final quota = await client.queryQuota();
        if (quota.remainingSeconds < 0)
          throw const ConfigArchiveException('备份账号无法核验');
      } finally {
        client.close();
      }
    }
    final missing = <String>{};
    Future<void> roots(Object? node) async {
      if (node is Map) {
        for (final entry in node.entries) {
          if (_rootKeys.contains(entry.key) &&
              entry.value is String &&
              (entry.value as String).isNotEmpty &&
              !await Directory(entry.value as String).exists()) {
            missing.add(entry.value as String);
          }
          await roots(entry.value);
        }
      } else if (node is List) {
        for (final child in node) {
          await roots(child);
        }
      }
    }

    await roots(payload);
    final sameOrigin = payload['meta.json']['origin'] == _origin;
    final summary = <String>[
      if (payload.containsKey('setting.json')) '替换应用设置',
      if (payload.containsKey('library.json')) '替换本地书签',
      if (account != null)
        '合并 ${(account['accounts'] as List).length} 个账号及账本，未完成任务保持暂停',
      if (account?['downloads'] != null && sameOrigin) '保留本机仍存在的已完成音频关联',
      if (account != null) '现有未确认扣时和已确认收据不会删除',
      if (account?['downloads'] != null ||
          (payload['library.json'] as Map?)?['downloads'] != null)
        '恢复下载记录及整专辑分页进度，任务保持暂停并需重新确认',
      if (account != null && !sameOrigin) '其他资料目录的下载收据仅作历史，不抵扣新下载',
      if ((payload['setting.json'] as Map?)?.containsKey('autoDownloads') ==
          true)
        '自动下载新声音需在本机重新开启',
      if (missing.isNotEmpty) '需重新选择 ${missing.length} 个下载目录',
    ];
    return ArchiveImport._(
      jsonEncode(payload),
      this,
      sameOrigin,
      summary,
      missing,
    );
  }

  Future<void> restore(
    ArchiveImport draft, {
    Map<String, String> relocatedRoots = const {},
  }) async {
    if (!identical(draft._owner, this))
      throw const ConfigArchiveException('请重新打开备份');
    final payload = jsonDecode(draft._payload) as Map<String, dynamic>;
    // A backup is data, not permission to spend quota on future voices.
    (payload['setting.json'] as Map?)?.remove('autoDownloads');
    Future<void> relocate(Object? node) async {
      if (node is Map) {
        for (final key in node.keys) {
          final value = node[key];
          if (_rootKeys.contains(key) && value is String && value.isNotEmpty) {
            final replacement = relocatedRoots[value];
            final target = replacement ?? value;
            if (!p.isAbsolute(target) || !await Directory(target).exists()) {
              throw const ConfigArchiveException('请为失效的下载目录选择新位置');
            }
            node[key] = p.normalize(
              await Directory(target).resolveSymbolicLinks(),
            );
          } else {
            await relocate(value);
          }
        }
      } else if (node is List) {
        for (final child in node) {
          await relocate(child);
        }
      }
    }

    await relocate(payload);
    final library = payload['library.json'] as Map?;
    final account = payload['account.json'] as Map?;
    final downloadData = account?.containsKey('downloads') == true
        ? account
        : library;
    final downloads = downloadData?['downloads'] as List?;
    for (final task in downloads ?? const []) {
      final wasProcessing = (task as Map)['state'] == 'processing';
      task['state'] = 'paused';
      task['userConfirmed'] = false;
      task['needsConfirmation'] = true;
      if (wasProcessing) task['processingFailed'] = true;
      task['bytesPerSecond'] = 0;
      task['retryAt'] = null;
      task['autoStart'] = false;
    }
    final albumJobs = downloadData?['downloadAlbums'] as List?;
    for (final job in albumJobs ?? const []) {
      (job as Map)['state'] = 'paused';
      job['error'] = null;
    }
    final queue =
        (account?['queue'] ?? library?['queue']) as Map<String, dynamic>?;
    await accounts.restoreArchive(
      settings: payload['setting.json'] as Map<String, dynamic>?,
      library: library?['library'] as Map<String, dynamic>?,
      importedAccounts: (account?['accounts'] as List?)
          ?.cast<Map<String, dynamic>>(),
      primaryAccountId: account?['primaryAccountId'] as String?,
      downloads: downloads,
      downloadAlbums: albumJobs,
      queue: queue,
      sameOrigin: draft.sameOrigin,
    );
  }

  static Object? _clean(Object? node) {
    if (node is Map) {
      return <String, dynamic>{
        for (final entry in node.entries)
          if (!_secretKeys.contains(entry.key) &&
              !_transientKeys.contains(entry.key) &&
              !RegExp(
                r'^(?:playUrl|downloadUrl|audioUrl|signedUrl)',
                caseSensitive: false,
              ).hasMatch(entry.key as String))
            entry.key as String: _clean(entry.value),
      };
    }
    if (node is List) return node.map(_clean).toList();
    return node;
  }

  static void _validate(Map<String, dynamic> payload, Set<String> names) {
    final meta = _map(payload['meta.json']);
    if (meta['type'] != 'data_archive' ||
        meta['appName'] != 'XMPlus' ||
        meta['formatVersion'] is! int ||
        (meta['formatVersion'] as int) >> 16 != 1 ||
        meta['versionCode'] is! int ||
        (meta['versionCode'] as int) < 1 ||
        meta['versionName'] is! String ||
        meta['platform'] is! String ||
        meta['exportTime'] is! String ||
        DateTime.tryParse(meta['exportTime'] as String) == null ||
        meta['origin'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(meta['origin'] as String) ||
        meta['files'] is! List)
      throw const FormatException();
    final listed = meta['files'] as List;
    if (listed.any((name) => name is! String || name == 'meta.json') ||
        listed.toSet().length != listed.length ||
        !names.difference({'meta.json'}).containsAll(listed) ||
        !listed.toSet().containsAll(names.difference({'meta.json'})))
      throw const FormatException();
    for (final name in names.difference({'meta.json', 'account.json'})) {
      _checkData(payload[name]);
    }
    final setting = payload['setting.json'];
    if (setting != null) _validateSettings(_map(setting));
    final library = payload['library.json'];
    if (library != null) {
      final value = _map(library);
      _validateTasks(value);
      if (value.containsKey('library')) {
        // Validate old backups above before discarding obsolete local favorites.
        for (final library in _map(value['library']).values) {
          if (library is Map) library.remove('favorites');
        }
      }
      // Validate legacy history above, but never restore it or its old outbox.
      if (value.containsKey('history')) _map(value.remove('history'));
      value.remove('officialProgress');
    }
    final account = payload['account.json'];
    if (account == null) return;
    final value = _map(account);
    if (value['accounts'] is! List ||
        (value['primaryAccountId'] != null &&
            value['primaryAccountId'] is! String) ||
        (value.containsKey('downloads') && value['downloads'] is! List) ||
        (value.containsKey('queue') && value['queue'] is! Map))
      throw const FormatException();
    final identities = <String>{}, credentialIdentities = <String>{};
    for (final raw in value['accounts'] as List) {
      final record = _map(raw);
      final identity = record['identity'];
      if (identity is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(identity) ||
          !identities.add(identity))
        throw const FormatException();
      _checkData(_map(record['record']));
      final data = record['record'] as Map;
      if (data['uid'] is! String ||
          !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(data['uid'] as String) ||
          data.containsKey('ledger') && data['ledger'] is! Map)
        throw const FormatException();
      if (data['ledger'] != null)
        _validateLedger(_map(data['ledger']), identity);
      final pair = record['credentials'];
      if (pair != null) {
        final fields = _map(pair);
        if (fields['token'] is! String || fields['device_id'] is! String)
          throw const FormatException();
        final credentials = Credentials.parse({
          'token': fields['token'],
          'device_id': fields['device_id'],
        });
        if (credentials.identity != identity ||
            (record['record'] as Map)['uid'] != credentials.uid)
          throw const FormatException();
        record['credentials'] = credentials.toJson();
        credentialIdentities.add(identity);
      }
    }
    if (credentialIdentities.isNotEmpty &&
            !credentialIdentities.contains(value['primaryAccountId']) ||
        credentialIdentities.isEmpty && value['primaryAccountId'] != null)
      throw const FormatException();
    _validateTasks(value);
  }

  static void _validateTasks(Map<String, dynamic> value) {
    final tasks = <String, DownloadTask>{};
    if (value.containsKey('downloads')) {
      if (value['downloads'] is! List) throw const FormatException();
      _checkData(value['downloads']);
      for (final item in value['downloads'] as List) {
        final task = _map(item);
        final parsed = DownloadTask.fromJson(task);
        if (tasks.containsKey(parsed.id) ||
            !p.isAbsolute(parsed.rootDirectory)) {
          throw const FormatException();
        }
        tasks[parsed.id] = parsed;
      }
    }
    if (value.containsKey('downloadAlbums')) {
      if (value['downloadAlbums'] is! List || !value.containsKey('downloads')) {
        throw const FormatException();
      }
      _checkData(value['downloadAlbums']);
      final ids = <String>{};
      for (final item in value['downloadAlbums'] as List) {
        final job = DownloadAlbumJob.fromJson(_map(item));
        if (job.id.isEmpty ||
            !ids.add(job.id) ||
            job.accountIdentity.isEmpty ||
            xmlyIdentifier(job.albumId) != job.albumId ||
            !p.isAbsolute(job.rootDirectory) ||
            job.total < 0 ||
            job.total > 5000 ||
            job.page < 1 ||
            job.page > 5000 ~/ xmlyAlbumPageSize ||
            job.seen.length !=
                (job.page * xmlyAlbumPageSize).clamp(0, job.total) ||
            job.seen.toSet().length != job.seen.length ||
            job.taskIds.toSet().length != job.taskIds.length ||
            job.taskIds.any((id) => !job.seen.contains(tasks[id]?.track.id)) ||
            !const {
              'queued',
              'running',
              'paused',
              'completed',
              'failed',
              'cancelled',
            }.contains(job.state)) {
          throw const FormatException();
        }
        for (final id in job.seen) {
          xmlyIdentifier(id);
        }
        _validateSettings(job.settings);
      }
    }
    if (value.containsKey('queue')) {
      _checkData(value['queue']);
      value['queue'] = PlaybackQueue.fromJson(value['queue']).toJson();
    }
  }

  static void _validateLedger(Map<String, dynamic> ledger, String identity) {
    final receipts = ledger['receipts'];
    if (receipts != null) {
      if (receipts is! List) throw const FormatException();
      for (final raw in receipts) {
        if (DownloadReceipt.fromJson(_map(raw)).accountIdentity != identity) {
          throw const FormatException();
        }
      }
    }
    final pending = ledger['usage_pending'];
    if (pending == null) return;
    final operation = _map(pending);
    // Online debt has no download task, and a persisted debt can have no watch.
    if (operation['operationId'] is! String ||
        (operation['operationId'] as String).isEmpty ||
        operation['accountIdentity'] != identity ||
        operation['trackId'] is! String ||
        operation['seconds'] is! int ||
        (operation['seconds'] as int) < 1 ||
        (operation['seconds'] as int) > UsageLedger.maxSeconds ||
        operation['balanceBefore'] is! int ||
        (operation['balanceBefore'] as int) < 0 ||
        (operation['balanceAfter'] != null &&
            (operation['balanceAfter'] is! int ||
                (operation['balanceAfter'] as int) < 0)) ||
        operation['createdAt'] is! int ||
        !{'submitting', 'uncertain'}.contains(operation['state'])) {
      throw const FormatException();
    }
    if ((operation['trackId'] as String).isNotEmpty)
      xmlyIdentifier(operation['trackId'] as String);
    DateTime.fromMillisecondsSinceEpoch(operation['createdAt'] as int);
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  static void _checkData(Object? value, [int depth = 0, String? rawTrackId]) {
    if (depth > 64) throw const FormatException();
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String ||
            _secretKeys.contains(entry.key) ||
            _transientKeys.contains(entry.key) ||
            RegExp(
              r'^(?:playUrl|downloadUrl|audioUrl|signedUrl)',
              caseSensitive: false,
            ).hasMatch(entry.key as String)) {
          throw const FormatException();
        }
        if (_rootKeys.contains(entry.key) && entry.value is! String)
          throw const FormatException();
        if (const {
              'usage_uncertain',
              'uncertain',
              'historical',
              'downloadExempt',
              'attempted',
              'terminal',
              'autoStart',
              'playing',
              'archived',
            }.contains(entry.key) &&
            entry.value is! bool)
          throw const FormatException();
        if (const {
              'usage_seconds',
              'pendingSeconds',
              'unreportedSeconds',
              'seconds',
              'balanceBefore',
              'balanceAfter',
              'balance_before',
              'balance_after',
              'position',
              'duration',
            }.contains(entry.key) &&
            entry.value != null &&
            (entry.value is! num ||
                !(entry.value as num).isFinite ||
                (entry.value as num) < 0)) {
          throw const FormatException();
        }
        // API metadata retains numeric IDs; persisted operations still use strings.
        if (entry.key == 'trackId' &&
            rawTrackId != null &&
            entry.value is int) {
          if (xmlyIdentifier(entry.value.toString()) !=
              xmlyIdentifier(rawTrackId)) {
            throw const FormatException();
          }
        } else if (const {
              'operationId',
              'accountIdentity',
              'taskId',
              'trackId',
            }.contains(entry.key) &&
            entry.value is! String)
          throw const FormatException();
        if (entry.key == 'state' && entry.value is! String)
          throw const FormatException();
        _checkData(
          entry.value,
          depth + 1,
          entry.key == 'raw' &&
                  value['id'] is String &&
                  value['album_id'] is String
              ? value['id'] as String
              : null,
        );
      }
    } else if (value is List) {
      for (final child in value) {
        _checkData(child, depth + 1);
      }
    } else if (value is num && !value.isFinite) {
      throw const FormatException();
    }
  }

  static void _validateSettings(Map<String, dynamic> settings) {
    if (settings.containsKey('autoClaim') && settings['autoClaim'] is! bool)
      throw const FormatException();
    if (settings.containsKey('showRequestFailureBanner') &&
        settings['showRequestFailureBanner'] is! bool)
      throw const FormatException();
    final appearance = settings['appearance'];
    if (settings.containsKey('catalogueAscending') &&
        settings['catalogueAscending'] is! bool) {
      throw const FormatException();
    }
    if (appearance != null) {
      final value = _map(appearance);
      if (value.containsKey('themeMode') &&
          !['system', 'light', 'dark'].contains(value['themeMode']))
        throw const FormatException();
      if (value.containsKey('oledBlack') && value['oledBlack'] is! bool)
        throw const FormatException();
      if (value.containsKey('seedColor') &&
          (value['seedColor'] is! int ||
              (value['seedColor'] as int) < 0 ||
              (value['seedColor'] as int) > 0xffffffff))
        throw const FormatException();
      _range(value, 'textScale', 0.8, 1.5);
    }
    void playback(Object? raw) {
      if (raw == null) return;
      PlaybackSettings.parse(_map(raw));
    }

    playback(settings['playback']);
    if (settings.containsKey('albumOverrides')) {
      for (final value in _map(settings['albumOverrides']).values) {
        playback(value);
      }
    }
    for (final key in [
      'download',
      'media',
      'account',
      'rewards',
      'sleepTimer',
    ]) {
      if (settings.containsKey(key)) _map(settings[key]);
    }
  }

  static void _range(Map value, String key, num minimum, num maximum) {
    if (!value.containsKey(key)) return;
    final number = value[key];
    if (number is! num ||
        !number.isFinite ||
        number < minimum ||
        number > maximum)
      throw const FormatException();
  }
}
