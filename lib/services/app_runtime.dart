import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/xmly_client.dart';
import '../api/xmly_catalogue.dart';
import '../api/xmly_rewards.dart';
import '../storage/app_storage.dart';
import '../storage/credential_store.dart';
import 'account_service.dart';
import 'album_cache.dart';
import 'android_background_service.dart';
import 'auto_download_service.dart';
import 'usage_ledger.dart';
import '../models/xmly_models.dart';
import 'download_service.dart';
import 'media_pipeline.dart';
import 'player_service.dart';
import 'system_media_service.dart';
import 'request_diagnostics.dart';

class AppRuntime extends ChangeNotifier {
  AppRuntime({required this.storage, required this.secrets}) {
    RequestDiagnostics.instance.configure(storage.directory);
    anonymous = XmlyClient(
      urlCacheDirectory: p.join(storage.directory, 'audio-url-cache'),
    );
    albumCache = AlbumCache(p.join(storage.directory, 'album-cache'));
    accounts = AccountService(
      storage: storage,
      secrets: secrets,
      quiesce: quiesce,
      settle: settle,
      quiesceForRestore: _quiesceForRestore,
    );
    ledger = UsageLedger(storage: storage, clientFor: accounts.clientFor);
    settlementHandlers.add(ledger.stopWatch);
    settlementHandlers.add(ledger.settle);
    pipeline = MediaPipeline(accounts: accounts, anonymous: anonymous);
    downloads = DownloadService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      transfer: pipeline.transfer,
      processOnly: pipeline.processOnly,
      discardSource: pipeline.discardSource,
      anonymous: anonymous,
      beforeAdmission: _claimForDownload,
    );
    autoDownloads = AutoDownloadService(
      storage: storage,
      checkAccount: _checkAutomaticAccount,
      loadCatalogue: (identity, albumId) =>
          XmlyCatalogue(accounts.clientFor(identity)).album(albumId),
      hasTask: (identity, trackId) => downloads.tasks.any(
        (task) => task.accountIdentity == identity && task.track.id == trackId,
      ),
      enqueueNew: (identity, track, allowed) async {
        _checkAutomaticAccount(identity);
        final batch = await prepareDownloads(
          [track],
          accountIdentity: identity,
          automatic: true,
        );
        if (!allowed()) return;
        _checkAutomaticAccount(identity);
        await downloads.enqueueAutomatic(
          batch,
          allowed: () {
            if (!allowed()) return false;
            try {
              _checkAutomaticAccount(identity);
              return true;
            } catch (_) {
              return false;
            }
          },
        );
      },
    );
    player = PlayerService(
      storage: storage,
      accounts: accounts,
      ledger: ledger,
      downloads: downloads,
      pipeline: pipeline,
      anonymous: anonymous,
      prepareDownload: (tracks) => prepareDownloads(tracks),
      confirmDownload: (batch) async =>
          await confirmDownload?.call(batch) ?? false,
      exitApplication: () async {
        scheduledExit = true;
        if (requestExit != null) {
          await requestExit!();
        } else {
          scheduledExit = false;
          lifecycleError = '当前窗口不能执行退出';
          notifyListeners();
        }
      },
    );
    pauseHandlers.add(player.quiesce);
    pauseHandlers.add(downloads.pauseAll);
  }

  final AppStorage storage;
  final CredentialStore secrets;
  late final XmlyClient anonymous;
  late final AlbumCache albumCache;
  late final AccountService accounts;
  late final UsageLedger ledger;
  late final MediaPipeline pipeline;
  late final DownloadService downloads;
  late final AutoDownloadService autoDownloads;
  late final PlayerService player;
  SystemMediaService? _systemMedia;
  AndroidBackgroundService? _androidBackground;
  Future<bool> Function(DownloadBatch)? confirmDownload;
  Future<void> Function()? requestExit;
  bool scheduledExit = false, _closed = false;
  StreamSubscription<void>? _playerChanges;
  StreamSubscription<void>? _downloadChanges;
  final List<Future<void> Function()> pauseHandlers = [];
  StreamSubscription<void>? _automaticChanges;
  final List<Future<void> Function()> settlementHandlers = [];
  final Map<String, DownloadState> _cachedDownloadStates = {};
  bool _restoringDownloads = false;
  bool closing = false;
  String? lifecycleError;
  Timer? _rewardTimer;
  bool _refreshingRewards = false;
  final Map<String, Quota> _rewardChecks = {};

  XmlyClient get client => accounts.activeClient ?? anonymous;
  Future<void> load() async {
    await anonymous.flushUrlCache();
    await accounts.load();
    await ledger.load();
    await albumCache.load();
    albumCache.addListener(_albumCacheChanged);
    await downloads.load();
    if (Platform.isAndroid) {
      _androidBackground = await AndroidBackgroundService.start(downloads);
    }
    for (final task in downloads.tasks) {
      _cachedDownloadStates[task.id] = task.state;
    }
    await player.load();
    if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS) {
      _systemMedia = await SystemMediaService.start(
        player: player,
        albumCache: albumCache,
      );
    }
    _playerChanges = player.changes.listen((_) => notifyListeners());
    _downloadChanges = downloads.changes.listen((_) {
      _refreshDownloadedAlbums();
      notifyListeners();
    });
    _automaticChanges = autoDownloads.changes.listen((_) => notifyListeners());
    unawaited(autoDownloads.scanAll());
    _configureRewards();
  }

  void _albumCacheChanged() => notifyListeners();

  void _refreshDownloadedAlbums() {
    if (closing || _closed) return;
    for (final task in downloads.tasks) {
      final previous = _cachedDownloadStates[task.id];
      _cachedDownloadStates[task.id] = task.state;
      if (_restoringDownloads ||
          task.track.albumId.isEmpty ||
          downloads.albumJobs.any((job) => job.albumId == task.track.albumId) ||
          (previous != null &&
              !(task.state == DownloadState.queued && previous != task.state) &&
              !(task.state == DownloadState.completed &&
                  previous != task.state))) {
        continue;
      }
      try {
        final originalClient = task.accountIdentity == 'anonymous'
            ? anonymous
            : accounts.clientFor(task.accountIdentity);
        unawaited(
          albumCache
              .refresh(task.track.albumId, originalClient)
              .catchError((Object _) {}),
        );
      } catch (_) {
        // Optional public metadata never changes media admission or its result.
      }
    }
  }

  void changed() {
    _configureRewards();
    notifyListeners();
  }

  Future<String> downloadRoot() async {
    final settings = storage.state['settings'] as Map;
    final configured = (settings['download'] as Map?)?['rootDirectory'];
    if (configured is String && configured.isNotEmpty) return configured;
    final parent = Platform.isAndroid
        ? await getExternalStorageDirectory() ??
              await getApplicationSupportDirectory()
        : await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
    final directory = await Directory(p.join(parent.path, 'XMPlus'))
        .create(recursive: true);
    await storage.transaction((state) {
      final settings = state['settings'] as Map;
      final download =
          settings.putIfAbsent('download', () => <String, dynamic>{}) as Map;
      download['rootDirectory'] = directory.path;
    });
    return directory.path;
  }

  Future<DownloadBatch> prepareDownloads(
    List<Track> tracks, {
    String? accountIdentity,
    bool automatic = false,
    bool? polling,
    bool previewBilling = true,
  }) async {
    final root = await downloadRoot();
    final settings = storage.state['settings'] as Map;
    final identity =
        accountIdentity ?? accounts.primaryAccountId ?? 'anonymous';
    final selected = <Track>[];
    final pages = <String, Map<int, AlbumPage>>{};
    final pattern =
        (settings['download'] as Map?)?['filenamePattern'] as String? ??
        '{index} - {title} [{trackId}]';
    for (final track in tracks) {
      if (pattern.contains('{index}') &&
          track.orderNo == null &&
          track.officialPosition == null &&
          track.albumId.isNotEmpty) {
        final albumPages = pages.putIfAbsent(track.albumId, () => {});
        final source = identity == 'anonymous'
            ? anonymous
            : accounts.clientFor(identity);
        Track? matching;
        for (var page = 1; ; page++) {
          final result = albumPages[page] ??= await source.album(
            track.albumId,
            page: page,
            pageSize: xmlyAlbumPageSize,
            ascending: true,
          );
          matching = result.tracks
              .where((item) => item.id == track.id)
              .firstOrNull;
          if (matching != null || page * xmlyAlbumPageSize >= result.total)
            break;
        }
        if (matching == null) {
          throw const XmlyException('missing_official_order', '专辑中没有找到此声音');
        }
        selected.add(matching);
      } else {
        selected.add(track);
      }
    }
    return downloads.prepare(
      selected,
      accountIdentity: identity,
      rootDirectory: root,
      previewBilling: previewBilling,
      settings: {
        'download': {
          ...(settings['download'] as Map? ?? const {}),
          'polling':
              polling ?? (settings['download'] as Map?)?['polling'] != false,
          if (automatic) 'retryLimit': 0,
        },
        'media': settings['media'] ?? <String, dynamic>{},
        'tags': settings['tags'] ?? <String, dynamic>{},
        'albumTags': settings['albumTags'] ?? <String, dynamic>{},
      },
    );
  }

  Future<DownloadBatch> prepareAlbumDownloads(
    String albumId, {
    String? accountIdentity,
    bool? polling,
  }) async {
    final settings = storage.state['settings'] as Map;
    return downloads.prepareAlbum(
      albumId,
      accountIdentity:
          accountIdentity ?? accounts.primaryAccountId ?? 'anonymous',
      rootDirectory: await downloadRoot(),
      previewBilling: false,
      settings: {
        'download': {
          ...(settings['download'] as Map? ?? const {}),
          'polling':
              polling ?? (settings['download'] as Map?)?['polling'] != false,
        },
        'media': settings['media'] ?? <String, dynamic>{},
        'tags': settings['tags'] ?? <String, dynamic>{},
        'albumTags': settings['albumTags'] ?? <String, dynamic>{},
      },
    );
  }

  Future<int?> _claimForDownload(String identity, XmlyClient client) async {
    if (closing || (storage.state['settings'] as Map)['autoClaim'] != true)
      return null;
    final record = (storage.state['accounts'] as Map)[identity] as Map?;
    if (record == null ||
        record['rewardPaused'] == true ||
        ledger.isBlocked(identity))
      return null;
    final checked = _rewardChecks[identity];
    if (checked != null &&
        DateTime.now().difference(checked.checkedAt) <
            const Duration(minutes: 5)) {
      var remaining = checked.remainingSeconds - ledger.debt(identity).ceil();
      for (final receipt in ledger.receipts(identity)) {
        if (receipt.state == DebitState.confirmed &&
            receipt.balanceAfter != null &&
            !receipt.createdAt.isBefore(checked.checkedAt) &&
            receipt.balanceAfter! < remaining) {
          remaining = receipt.balanceAfter!;
        }
      }
      if (remaining >= 7200) return null;
    }
    return _refreshAccountRewards(identity, client);
  }

  Future<int?> _refreshAccountRewards(
    String identity,
    XmlyClient client,
  ) async {
    final rewards = XmlyRewards(client, automaticEnabled: true);
    var increase = 0;
    try {
      final before = await client.queryQuota();
      final after = await rewards.refresh();
      _rewardChecks[identity] = after;
      increase = after.remainingSeconds - before.remainingSeconds;
    } catch (_) {
      // Claim availability must not prevent an otherwise authorized download.
      return null;
    }
    if (rewards.lastError.isNotEmpty) {
      await storage.transaction((state) {
        ((state['accounts'] as Map)[identity] as Map)['rewardPaused'] = true;
      });
    }
    return increase > 0 ? increase : null;
  }

  void _checkAutomaticAccount(String identity) {
    if (closing ||
        _closed ||
        accounts.admissionPaused ||
        !accounts.accountIds.contains(identity)) {
      throw const XmlyException('missing_account', '请先登录原账号');
    }
    if (ledger.isBlocked(identity))
      throw const XmlyException('usage_uncertain', '请先核对未确认的听时');
  }

  Future<void> pauseDownload(String id) async {
    if (player.currentTaskId == id) await player.pause();
    await downloads.pause(id);
    await pipeline.pauseTask(id);
  }

  Future<void> cancelDownload(String id) async {
    await player.stopTaskReference(id);
    await downloads.cancel(id);
    await pipeline.pauseTask(id);
  }

  Future<void> pauseAllDownloads() async {
    if (player.currentTaskId != null) await player.pause();
    await downloads.pauseAll();
  }

  Future<void> reacquireDownload(String id) async {
    await player.stopTaskReference(id);
    await downloads.pause(id);
    await downloads.retry(id, reacquire: true);
  }

  Future<void> relocateDownload(String id, String directory) async {
    await player.stopTaskReference(id);
    await downloads.pause(id);
    await pipeline.detachTask(id);
    await downloads.relocate(id, directory);
  }

  Future<void> reloadAfterRestore() async {
    _restoringDownloads = true;
    _rewardChecks.clear();
    try {
      await downloads.reload();
      _cachedDownloadStates
        ..clear()
        ..addEntries(
          downloads.tasks.map((task) => MapEntry(task.id, task.state)),
        );
      await ledger.load();
      await player.reload();
      lifecycleError = null;
      changed();
      autoDownloads.resume();
    } catch (_) {
      lifecycleError = '恢复内容已保存，但任务加载未完成；原资料目录已保留';
      notifyListeners();
      rethrow;
    } finally {
      _restoringDownloads = false;
    }
  }

  void _configureRewards() {
    final enabled = (storage.state['settings'] as Map)['autoClaim'] == true;
    if (!enabled) {
      _rewardTimer?.cancel();
      _rewardTimer = null;
    } else {
      _rewardTimer ??= Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_refreshRewards()),
      );
    }
  }

  Future<void> _refreshRewards() async {
    if (_refreshingRewards ||
        closing ||
        (storage.state['settings'] as Map)['autoClaim'] != true)
      return;
    _refreshingRewards = true;
    try {
      for (final identity in accounts.accountIds.toList()) {
        final record = (storage.state['accounts'] as Map)[identity] as Map;
        if (record['rewardPaused'] == true) continue;
        try {
          await accounts.runWithAccount(identity, (client) async {
            await _refreshAccountRewards(identity, client);
          });
        } catch (_) {
          // A failed account refresh never triggers account rotation or replay.
        }
      }
    } finally {
      _refreshingRewards = false;
    }
  }

  Future<void> _quiesceForRestore() async {
    autoDownloads.suspend();
    try {
      await player.quiesce(preserveUnknown: true);
      await downloads.pauseAll();
      await ledger.captureForRestore();
    } finally {
      // The account mutex still blocks new admissions until restore finishes.
      if (!closing) autoDownloads.resume();
    }
  }

  Future<void> quiesce() async {
    autoDownloads.suspend();
    try {
      for (final pause in List.of(pauseHandlers)) {
        await pause();
      }
    } finally {
      if (!closing) autoDownloads.resume();
    }
  }

  Future<void> settle() async {
    for (final settle in List.of(settlementHandlers)) {
      await settle();
    }
  }

  Future<bool> close() async {
    if (_closed) return true;
    if (closing) return false;
    closing = true;
    autoDownloads.suspend();
    _rewardTimer?.cancel();
    _rewardTimer = null;
    try {
      await quiesce();
      await settle();
      await _systemMedia?.close();
      await _androidBackground?.close();
      await albumCache.close();
      albumCache.removeListener(_albumCacheChanged);
      await accounts.close();
      await player.close(quiesced: true);
      await _playerChanges?.cancel();
      await autoDownloads.close();
      await _automaticChanges?.cancel();
      await downloads.close();
      await _downloadChanges?.cancel();
      await pipeline.close();
      anonymous.close();
      await anonymous.flushUrlCache();
      await RequestDiagnostics.instance.close();
      await storage.close();
      _closed = true;
      return true;
    } catch (_) {
      lifecycleError = '保存或结算未完成，请核对后再退出';
      closing = false;
      autoDownloads.resume();
      notifyListeners();
      return false;
    }
  }
}
