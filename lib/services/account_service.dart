import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/download_task.dart';
import '../models/xmly_models.dart';
import '../storage/app_storage.dart';
import '../storage/credential_store.dart';

class AccountException implements Exception {
  const AccountException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class AccountService {
  AccountService({
    required this.storage,
    required this.secrets,
    this.quiesce,
    this.quiesceForRestore,
    this.settle,
  });

  final AppStorage storage;
  final CredentialStore secrets;

  /// Stop new work and pause/save old playback/downloads. Must await all users.
  final Future<void> Function()? quiesce;

  /// Pause producers and capture local usage without settling unknown reports.
  final Future<void> Function()? quiesceForRestore;

  /// Settle actual old-account usage; must throw if settlement is incomplete.
  final Future<void> Function()? settle;
  final Lock _accounts = Lock();
  final Map<String, XmlyClient> _clients = {};
  final Map<String, XmlyClient> _settlementClients = {};
  final Set<String> _missingCredentials = {};
  bool _loaded = false;
  bool _closed = false;
  bool _admissionPaused = false;

  String get _prefix =>
      'xmly.${sha256.convert(utf8.encode(storage.directory))}.';
  String get _urlCacheDirectory => p.join(storage.directory, 'audio-url-cache');
  bool get admissionPaused => _admissionPaused || _closed || !_loaded;
  bool get credentialCleanupPending =>
      (storage.state['credentialCleanup'] as List? ?? const []).isNotEmpty;
  String? get primaryAccountId => storage.state['primaryAccountId'] as String?;
  XmlyClient? get activeClient => _clients[storage.state['activeAccountId']];
  List<String> get accountIds => List.unmodifiable(_clients.keys);
  List<String> get missingCredentialAccountIds =>
      List.unmodifiable(_missingCredentials);

  XmlyClient clientFor(String identity) {
    _ensureLoaded();
    final client = _settlementClients[identity] ?? _clients[identity];
    if (client == null && _missingCredentials.contains(identity)) {
      throw const AccountException('credential_missing', '安全凭据缺失，请重新导入原账号');
    }
    if (client == null) throw const AccountException('missing', '请先登录此账号');
    return client;
  }

  /// New task admission shares the transaction mutex. Keep the callback short:
  /// return its admitted task, not the entire transfer/playback lifetime.
  Future<T> runWithAccount<T>(
    String identity,
    Future<T> Function(XmlyClient client) admit,
  ) => _accounts.synchronized(() async {
    _ensureLoaded();
    if (_admissionPaused) {
      throw const AccountException('paused', '账号正在切换，请稍后重试');
    }
    return admit(clientFor(identity));
  });

  /// Restores credentials locally only. Never validates, claims or debits here.
  Future<void> load() => _accounts.synchronized(() async {
    if (_closed) throw const AccountException('closed', '账号服务已关闭');
    if (_loaded) return;
    final restored = <String, XmlyClient>{};
    final referenced = <String>{};
    final missing = <String>{};
    try {
      final accounts = storage.state['accounts'] as Map;
      for (final entry in accounts.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const AccountException('corrupt', '账号资料损坏，请恢复备份');
        }
        final account = entry.value as Map;
        final ref = account['credentialRef'];
        if (ref == null) continue; // Retained nonsecret billing history.
        if (ref is! String || !_validRef(ref, entry.key as String)) {
          throw const AccountException('corrupt', '账号凭据引用无效，请恢复备份');
        }
        referenced.add(entry.key as String);
        final String? secret;
        try {
          secret = await secrets.read(ref);
        } catch (_) {
          throw const AccountException(
            'credential_read_failed',
            '无法读取安全凭据，原资料已保留',
          );
        }
        if (secret == null) {
          missing.add(entry.key as String);
          continue;
        }
        final Credentials credentials;
        try {
          credentials = Credentials.parse(secret);
        } catch (_) {
          throw const AccountException('credential_invalid', '安全凭据无效，请重新导入原账号');
        }
        if (credentials.identity != entry.key ||
            credentials.uid != account['uid']) {
          throw const AccountException('credential_invalid', '安全凭据与账号资料不一致');
        }
        restored[entry.key as String] = XmlyClient(
          credentials: credentials,
          urlCacheDirectory: _urlCacheDirectory,
        );
      }
      if ((referenced.isNotEmpty &&
              (!referenced.contains(primaryAccountId) ||
                  !referenced.contains(storage.state['activeAccountId']))) ||
          (referenced.isEmpty &&
              (primaryAccountId != null ||
                  storage.state['activeAccountId'] != null))) {
        throw const AccountException('corrupt', '主账号资料无效，请恢复备份');
      }
      // A process cannot prove a POST completed across a crash.
      if (_containsSubmitting(accounts)) {
        await storage.transaction(
          (state) => _recoverSubmitting(state['accounts']),
        );
      }
      _clients.addAll(restored);
      _missingCredentials.addAll(missing);
      _loaded = true;
      await _cleanupSecrets();
      for (final client in restored.values) {
        await client.flushUrlCache();
      }
    } catch (_) {
      for (final client in restored.values) {
        client.close();
      }
      for (final client in restored.values) {
        await client.flushUrlCache();
      }
      _clients.clear();
      _missingCredentials.clear();
      _loaded = false;
      rethrow;
    }
  });

  Future<void> commit(
    Credentials credentials, {
    bool makePrimary = true,
    String? recoveryIdentity,
  }) => _accounts.synchronized(() async {
    _ensureLoaded();
    final identity = credentials.identity;
    if (recoveryIdentity != null &&
        (identity != recoveryIdentity ||
            (!_missingCredentials.contains(recoveryIdentity) &&
                !_clients.containsKey(recoveryIdentity)))) {
      throw const AccountException(
        'credential_mismatch',
        '请导入原账号的 Cookie，并保留原设备 ID',
      );
    }
    // A same-identity renewal that keeps both selections is not an account
    // switch. Explicit recovery also permits renewing a backup account.
    final recovering =
        recoveryIdentity != null ||
        (_clients.containsKey(identity) &&
            storage.state['activeAccountId'] == identity &&
            (!makePrimary || primaryAccountId == identity));
    // A candidate is never mounted during validation.
    final candidate = XmlyClient(credentials: credentials);
    var committed = false;
    String? newRef;
    try {
      final quota = await candidate.queryQuota();
      if (quota.remainingSeconds < 0) {
        throw const AccountException('quota_invalid', '无法核验账号可用听时');
      }
      if ((storage.state['accounts'] as Map).containsKey(identity)) {
        // New admissions remain locked; only existing same-identity usage
        // can use the verified token revision while the old token expires.
        _settlementClients[identity] = candidate;
      }
      if (recovering && quiesceForRestore != null) {
        // Repair only this identity's credential. Unknown operations remain
        // blocked and reachable for reconciliation after authentication.
        _admissionPaused = true;
        await quiesceForRestore!();
      } else {
        if (recovering && _containsUnknown(storage.state['accounts'])) {
          throw const AccountException(
            'integration_required',
            '请先连接账号恢复的任务暂停及听时保存服务',
          );
        }
        await _prepareChange();
      }
      final previous = (storage.state['accounts'] as Map)[identity] as Map?;
      final oldRef = previous?['credentialRef'] as String?;
      newRef = '$_prefix$identity.${const Uuid().v4()}';
      // Journal the key before writing the secret, so crashes/partial writes
      // leave a reachable cleanup entry rather than an orphaned credential.
      await storage.transaction((state) => _scheduleCleanup(state, newRef!));
      try {
        final encoded = jsonEncode(credentials.toJson());
        await secrets.write(newRef, encoded);
        if (await secrets.read(newRef) != encoded) {
          throw const AccountException(
            'credential_write_failed',
            '安全凭据未能保存，原账号已保留',
          );
        }
      } catch (_) {
        throw const AccountException(
          'credential_write_failed',
          '安全凭据未能保存，原账号已保留',
        );
      }
      await storage.transaction((state) {
        final accounts = state['accounts'] as Map<String, dynamic>;
        if (!recovering) _assertSettled(accounts);
        // Same uid/device identity retains every existing ledger/receipt.
        final record = Map<String, dynamic>.from(
          accounts[identity] as Map? ?? {},
        );
        record.addAll({
          'credentialRef': newRef,
          'uid': credentials.uid,
          'deviceHint': credentials.deviceId.length <= 4
              ? '****'
              : '…${credentials.deviceId.substring(credentials.deviceId.length - 4)}',
          'quota': quota.toJson(),
          'archived': false,
        });
        record.putIfAbsent('ledger', () => <String, dynamic>{});
        accounts[identity] = record;
        if (!recovering && (makePrimary || state['primaryAccountId'] == null)) {
          state['primaryAccountId'] = identity;
          state['activeAccountId'] = identity;
        }
        (state['credentialCleanup'] as List).remove(newRef);
        if (oldRef != null) _scheduleCleanup(state, oldRef);
      });
      committed = true;
      await _replaceClient(candidate);
    } finally {
      _settlementClients.remove(identity);
      if (!committed) candidate.close();
      // No old key is ever deleted before a successful reference commit.
      if (newRef != null) await _cleanupSecrets();
      _admissionPaused = false;
    }
  });

  /// Validates all candidates before staging keys; settings/library/account refs
  /// then change together. Absent sections and existing billing records survive.
  Future<void> restoreArchive({
    Map<String, dynamic>? settings,
    Map<String, dynamic>? library,
    List<Map<String, dynamic>>? importedAccounts,
    String? primaryAccountId,
    List<dynamic>? downloads,
    List<dynamic>? downloadAlbums,
    Map<String, dynamic>? queue,
    required bool sameOrigin,
  }) => _accounts.synchronized(() async {
    _ensureLoaded();
    final candidates = <String, XmlyClient>{};
    final quotas = <String, Quota>{};
    final refs = <String, String>{};
    var committed = false;
    try {
      for (final record in importedAccounts ?? const <Map<String, dynamic>>[]) {
        final pair = record['credentials'];
        if (pair == null) continue;
        final credentials = Credentials.parse(pair);
        final identity = credentials.identity;
        if (identity != record['identity'] ||
            candidates.containsKey(identity)) {
          throw const AccountException('archive_invalid', '备份账号资料无效');
        }
        final candidate = XmlyClient(credentials: credentials);
        candidates[identity] = candidate;
        final quota = await candidate.queryQuota();
        if (quota.remainingSeconds < 0) {
          throw const AccountException('quota_invalid', '无法核验备份账号');
        }
        quotas[identity] = quota;
        refs[identity] = '$_prefix$identity.${const Uuid().v4()}';
      }
      if (quiesceForRestore == null &&
          (quiesce == null ||
              settle == null ||
              _containsUnknown(storage.state['accounts']))) {
        throw const AccountException(
          'integration_required',
          '请先连接备份恢复的任务暂停及听时保存服务',
        );
      }
      _admissionPaused = true;
      for (final entry in candidates.entries) {
        if (_clients.containsKey(entry.key))
          _settlementClients[entry.key] = entry.value;
      }
      if (quiesceForRestore != null) {
        await quiesceForRestore!();
      } else {
        await quiesce!();
        await settle!();
      }
      final restoredDownloads = downloads == null
          ? null
          : sameOrigin
          ? await _retainLocalDownloads(downloads)
          : downloads;
      // Unlike switching/removing an account, restore preserves every existing
      // unknown operation, and never resumes work or clears its billing block.
      if (refs.isNotEmpty) {
        await storage.transaction((state) {
          for (final ref in refs.values) {
            _scheduleCleanup(state, ref);
          }
        });
        for (final entry in candidates.entries) {
          final encoded = jsonEncode(entry.value.credentials!.toJson());
          try {
            await secrets.write(refs[entry.key]!, encoded);
            if (await secrets.read(refs[entry.key]!) != encoded) {
              throw const AccountException(
                'credential_write_failed',
                '无法保存备份账号，原资料已保留',
              );
            }
          } catch (_) {
            throw const AccountException(
              'credential_write_failed',
              '无法保存备份账号，原资料已保留',
            );
          }
        }
      }
      await storage.transaction((state) {
        if (settings != null) state['settings'] = settings;
        if (library != null) state['library'] = library;
        if (restoredDownloads != null) {
          state['downloads'] = restoredDownloads;
          state['downloadAlbums'] = downloadAlbums ?? <dynamic>[];
        }
        if (queue != null) state['queue'] = queue;
        final records = state['accounts'] as Map<String, dynamic>;
        for (final imported
            in importedAccounts ?? const <Map<String, dynamic>>[]) {
          final identity = imported['identity'] as String;
          final existing = Map<String, dynamic>.from(
            records[identity] as Map? ?? {},
          );
          final incoming = Map<String, dynamic>.from(imported['record'] as Map);
          _recoverSubmitting(incoming);
          if (!sameOrigin) _historicReceipts(incoming);
          final merged =
              _mergeArchive(incoming, existing) as Map<String, dynamic>;
          if (records.containsKey(identity)) {
            // Online debt is a current balance, not an append-only receipt.
            // Even absent local fields must not be resurrected by an old backup.
            final ledger = Map<String, dynamic>.from(
              merged['ledger'] as Map? ?? {},
            );
            final current = existing['ledger'] as Map? ?? const {};
            ledger.removeWhere((key, _) => key.startsWith('usage_'));
            ledger.addAll({
              for (final entry in current.entries)
                if (entry.key is String &&
                    (entry.key as String).startsWith('usage_'))
                  entry.key as String: entry.value,
            });
            merged['ledger'] = ledger;
          }
          merged.putIfAbsent('ledger', () => <String, dynamic>{});
          final ref = refs[identity];
          if (ref != null) {
            final credentials = candidates[identity]!.credentials!;
            final oldRef = existing['credentialRef'] as String?;
            merged.addAll({
              'credentialRef': ref,
              'uid': credentials.uid,
              'deviceHint': credentials.deviceId.length <= 4
                  ? '****'
                  : '…${credentials.deviceId.substring(credentials.deviceId.length - 4)}',
              'quota': quotas[identity]!.toJson(),
              'archived': false,
            });
            (state['credentialCleanup'] as List).remove(ref);
            if (oldRef != null) _scheduleCleanup(state, oldRef);
          }
          records[identity] = merged;
        }
        if (importedAccounts != null &&
            primaryAccountId != null &&
            records[primaryAccountId] is Map &&
            records[primaryAccountId]['credentialRef'] is String) {
          state['primaryAccountId'] = primaryAccountId;
          state['activeAccountId'] = primaryAccountId;
        }
      });
      committed = true;
      for (final candidate in candidates.values) {
        await _replaceClient(candidate);
      }
    } finally {
      for (final identity in candidates.keys) {
        _settlementClients.remove(identity);
      }
      if (!committed) {
        for (final candidate in candidates.values) {
          candidate.close();
        }
      }
      if (refs.isNotEmpty) await _cleanupSecrets();
      _admissionPaused = false;
    }
  });

  Future<List<dynamic>> _retainLocalDownloads(List<dynamic> imported) async {
    final local = <String, DownloadTask>{};
    for (final raw in storage.state['downloads'] as List) {
      final task = DownloadTask.fromJson(Map<String, dynamic>.from(raw as Map));
      if (task.state == DownloadState.completed && task.finalPath != null) {
        local[task.id] = task;
      }
    }
    final restored = <dynamic>[];
    for (final raw in imported) {
      final incoming = DownloadTask.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      final existing = local[incoming.id];
      var keep = false;
      if (existing != null &&
          existing.accountIdentity == incoming.accountIdentity &&
          existing.track.id == incoming.track.id &&
          p.equals(
            p.normalize(existing.rootDirectory),
            p.normalize(incoming.rootDirectory),
          ) &&
          p.isWithin(existing.rootDirectory, existing.finalPath!)) {
        try {
          keep =
              await FileSystemEntity.type(
                    existing.finalPath!,
                    followLinks: false,
                  ) ==
                  FileSystemEntityType.file &&
              await File(existing.finalPath!).length() > 0;
        } on FileSystemException {
          // Missing/inaccessible outputs use the normal paused restore path.
        }
      }
      // Reuse only a current local association, never a path supplied by a ZIP.
      restored.add(keep ? existing!.toJson() : raw);
    }
    return restored;
  }

  static void _historicReceipts(Object? node) {
    if (node is Map) {
      if (node['operationId'] is String &&
          node['trackId'] is String &&
          node['taskId'] is String) {
        node['historical'] = true;
        node['downloadExempt'] = false;
        if (node['state'] == 'confirmed') {
          node['originalState'] = 'confirmed';
          node['state'] = 'historical';
        }
      }
      for (final child in node.values) {
        _historicReceipts(child);
      }
    } else if (node is List) {
      for (final child in node) {
        _historicReceipts(child);
      }
    }
  }

  // Existing records win conflicts; missing imported entries are unioned, never
  // used to erase a local unknown operation or confirmed receipt.
  static Object? _mergeArchive(Object? incoming, Object? existing) {
    if (incoming is Map && existing is Map) {
      final result = Map<String, dynamic>.from(incoming);
      for (final entry in existing.entries) {
        result[entry.key as String] = result.containsKey(entry.key)
            ? _mergeArchive(result[entry.key], entry.value)
            : entry.value;
      }
      return result;
    }
    if (incoming is List && existing is List) {
      String key(Object? item) => item is Map && item['operationId'] is String
          ? 'operation:${item['operationId']}'
          : jsonEncode(item);
      final result = {for (final item in incoming) key(item): item};
      for (final item in existing) {
        result[key(item)] = item;
      }
      return result.values.toList();
    }
    return existing;
  }

  Future<void> setPrimary(String identity) => _accounts.synchronized(() async {
    clientFor(identity);
    if (primaryAccountId == identity &&
        storage.state['activeAccountId'] == identity)
      return;
    try {
      await _prepareChange();
      await storage.transaction((state) {
        _assertSettled(state['accounts'] as Map);
        state['primaryAccountId'] = identity;
        state['activeAccountId'] = identity;
      });
    } finally {
      _admissionPaused = false;
    }
  });

  Future<void> remove(String identity) => _accounts.synchronized(() async {
    clientFor(identity);
    try {
      await _prepareChange();
      await storage.transaction((state) {
        final accounts = state['accounts'] as Map;
        _assertSettled(accounts);
        final account = accounts[identity] as Map;
        final oldRef = account.remove('credentialRef') as String;
        account['archived'] = true;
        _scheduleCleanup(state, oldRef);
        final remaining = accounts.keys
            .where(
              (id) =>
                  id != identity &&
                  (accounts[id] as Map)['credentialRef'] is String,
            )
            .toList();
        if (state['primaryAccountId'] == identity) {
          state['primaryAccountId'] = remaining.isEmpty
              ? null
              : remaining.first;
        }
        if (state['activeAccountId'] == identity) {
          state['activeAccountId'] = state['primaryAccountId'];
        }
      });
      final removed = _clients.remove(identity);
      if (removed != null) {
        removed.close();
        await removed.clearUrlCache();
      }
      await _cleanupSecrets();
    } finally {
      _admissionPaused = false;
    }
  });

  Future<void> _replaceClient(XmlyClient candidate) async {
    final old = _clients[candidate.identity];
    if (old != null) {
      old.close();
      if (old.cacheIdentity != candidate.cacheIdentity) {
        await old.clearUrlCache();
      } else {
        // One namespace, one writer: finish the old queue before loading it in
        // the newly committed client, including a same-token re-import.
        await old.flushUrlCache();
      }
    }
    candidate.attachUrlCache(_urlCacheDirectory);
    _clients[candidate.identity] = candidate;
    _missingCredentials.remove(candidate.identity);
  }

  Future<void> _prepareChange() async {
    if (quiesce == null || settle == null) {
      throw const AccountException('integration_required', '请先连接任务暂停及听时结算服务');
    }
    _admissionPaused = true;
    await quiesce!();
    await settle!();
    _assertSettled(storage.state['accounts'] as Map);
  }

  static void _assertSettled(Map accounts) {
    for (final account in accounts.values) {
      if (_unsettled(account)) {
        throw const AccountException('unsettled', '仍有未结算或结果未知的扣时，请先核对原账号');
      }
    }
  }

  static bool _containsUnknown(Object? node) {
    if (node is Map) {
      return node['usage_uncertain'] == true ||
          node['uncertain'] == true ||
          node['state'] == 'uncertain' ||
          node['state'] == 'submitting' ||
          node['usage_pending'] is Map ||
          node.values.any(_containsUnknown);
    }
    return node is List && node.any(_containsUnknown);
  }

  // Accept the original online ledger fields and the download receipt states.
  static bool _unsettled(Object? node) {
    if (node is Map) {
      if (node['usage_uncertain'] == true ||
          node['uncertain'] == true ||
          node['state'] == 'uncertain' ||
          node['state'] == 'submitting' ||
          node['usage_pending'] is Map)
        return true;
      for (final key in [
        'usage_seconds',
        'pendingSeconds',
        'unreportedSeconds',
      ]) {
        final debt = node[key];
        if (debt != null &&
            (debt is! num || !debt.isFinite || debt < 0 || debt >= 1))
          return true;
      }
      return node.values.any(_unsettled);
    }
    return node is List && node.any(_unsettled);
  }

  static bool _containsSubmitting(Object? node) => node is Map
      ? node['state'] == 'submitting' || node.values.any(_containsSubmitting)
      : node is List && node.any(_containsSubmitting);

  static void _recoverSubmitting(Object? node) {
    if (node is Map) {
      if (node['state'] == 'submitting') node['state'] = 'uncertain';
      for (final item in node.values) {
        _recoverSubmitting(item);
      }
    } else if (node is List) {
      for (final item in node) {
        _recoverSubmitting(item);
      }
    }
  }

  static void _scheduleCleanup(Map<String, dynamic> state, String key) {
    final pending =
        state.putIfAbsent('credentialCleanup', () => <dynamic>[]) as List;
    if (!pending.contains(key)) pending.add(key);
  }

  bool _validRef(String ref, String identity) => RegExp(
    '^${RegExp.escape('$_prefix$identity.')}[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\$',
  ).hasMatch(ref);

  /// Failed deletion remains journalled for the next load/commit. It does not
  /// roll back an already committed account or discard access to an old key.
  Future<void> _cleanupSecrets() async {
    final pending = List.of(
      storage.state['credentialCleanup'] as List? ?? const [],
    );
    final referenced = (storage.state['accounts'] as Map).values
        .whereType<Map>()
        .map((account) => account['credentialRef'])
        .toSet();
    for (final ref in pending) {
      if (ref is! String ||
          !ref.startsWith(_prefix) ||
          referenced.contains(ref))
        continue;
      try {
        await secrets.delete(ref);
        await storage.transaction(
          (state) => (state['credentialCleanup'] as List).remove(ref),
        );
      } catch (_) {
        // The persistent journal is the retry queue; never log secret values.
      }
    }
  }

  void _ensureLoaded() {
    if (_closed) throw const AccountException('closed', '账号服务已关闭');
    if (!_loaded) throw const AccountException('not_loaded', '请先读取账号资料');
  }

  /// Does not own AppStorage; caller closes storage after all services finish.
  /// A failed settlement leaves this service available for manual resolution.
  /// Startup rollback preserves state because no work has been admitted yet.
  Future<void> close({bool preserveState = false}) =>
      _accounts.synchronized(() async {
        if (_closed) return;
        if (!preserveState && _loaded && _clients.isNotEmpty) {
          try {
            await _prepareChange();
          } catch (_) {
            _admissionPaused = false;
            rethrow;
          }
        }
        if (!preserveState) await _cleanupSecrets();
        for (final client in _clients.values) {
          client.close();
        }
        for (final client in _clients.values) {
          await client.flushUrlCache();
        }
        _clients.clear();
        _closed = true;
        _admissionPaused = true;
      });
}
