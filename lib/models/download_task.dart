import 'dart:collection';
import 'dart:convert';

import 'xmly_models.dart';

enum DownloadState {
  queued,
  awaitingDebit,
  downloading,
  paused,
  processing,
  completed,
  failed,
  cancelled,
}

/// Only durable task data belongs here. Resolved URLs and HTTP headers stay in memory.
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.accountIdentity,
    required this.track,
    required this.rootDirectory,
    required Map<String, dynamic> settings,
    required this.createdAt,
    this.state = DownloadState.queued,
    this.costSeconds = 0,
    this.expectedBalance,
    this.userConfirmed = false,
    this.needsConfirmation = false,
    this.error,
    this.warning,
    this.actualQuality,
    this.processingFailed = false,
    this.outputMissing = false,
    this.outputDeleted = false,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.retryCount = 0,
    this.receiptOperationId,
    this.finalPath,
    this.retryAt,
    this.attemptedAccounts = const [],
  }) : settings = settings is _SettingsSnapshot
           ? settings
           : _snapshot(settings);

  final String id, accountIdentity, rootDirectory;
  final Track track;
  final Map<String, dynamic> settings;
  final DateTime createdAt;
  final DownloadState state;
  final int costSeconds, receivedBytes, retryCount;
  final int? expectedBalance, totalBytes;
  final bool userConfirmed, needsConfirmation, processingFailed;
  final bool outputMissing, outputDeleted;
  final String? error, warning, actualQuality, receiptOperationId, finalPath;
  final double bytesPerSecond;
  final DateTime? retryAt;
  final List<String> attemptedAccounts;

  bool get deduplicates => state != DownloadState.cancelled;
  bool get active => const {
    DownloadState.queued,
    DownloadState.awaitingDebit,
    DownloadState.downloading,
    DownloadState.processing,
  }.contains(state);

  static const _keep = Object();
  DownloadTask copyWith({
    Track? track,
    DownloadState? state,
    int? costSeconds,
    Map<String, dynamic>? settings,
    String? rootDirectory,
    String? accountIdentity,
    List<String>? attemptedAccounts,
    Object? expectedBalance = _keep,
    bool? userConfirmed,
    bool? needsConfirmation,
    Object? error = _keep,
    int? receivedBytes,
    Object? totalBytes = _keep,
    double? bytesPerSecond,
    int? retryCount,
    Object? receiptOperationId = _keep,
    Object? finalPath = _keep,
    Object? retryAt = _keep,
    Object? warning = _keep,
    Object? actualQuality = _keep,
    bool? processingFailed,
    bool? outputMissing,
    bool? outputDeleted,
  }) => DownloadTask(
    id: id,
    accountIdentity: accountIdentity ?? this.accountIdentity,
    track: track ?? this.track,
    rootDirectory: rootDirectory ?? this.rootDirectory,
    settings: settings ?? this.settings,
    createdAt: createdAt,
    state: state ?? this.state,
    costSeconds: costSeconds ?? this.costSeconds,
    expectedBalance: identical(expectedBalance, _keep)
        ? this.expectedBalance
        : expectedBalance as int?,
    userConfirmed: userConfirmed ?? this.userConfirmed,
    needsConfirmation: needsConfirmation ?? this.needsConfirmation,
    error: identical(error, _keep) ? this.error : error as String?,
    warning: identical(warning, _keep) ? this.warning : warning as String?,
    actualQuality: identical(actualQuality, _keep)
        ? this.actualQuality
        : actualQuality as String?,
    processingFailed: processingFailed ?? this.processingFailed,
    outputMissing: outputMissing ?? this.outputMissing,
    outputDeleted: outputDeleted ?? this.outputDeleted,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: identical(totalBytes, _keep)
        ? this.totalBytes
        : totalBytes as int?,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    retryCount: retryCount ?? this.retryCount,
    receiptOperationId: identical(receiptOperationId, _keep)
        ? this.receiptOperationId
        : receiptOperationId as String?,
    finalPath: identical(finalPath, _keep)
        ? this.finalPath
        : finalPath as String?,
    retryAt: identical(retryAt, _keep) ? this.retryAt : retryAt as DateTime?,
    attemptedAccounts: attemptedAccounts ?? this.attemptedAccounts,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountIdentity': accountIdentity,
    'track': track.toJson(),
    'rootDirectory': rootDirectory,
    'settings': settings,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'state': state.name,
    'costSeconds': costSeconds,
    'expectedBalance': expectedBalance,
    'userConfirmed': userConfirmed,
    'needsConfirmation': needsConfirmation,
    'error': error,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'warning': warning,
    'actualQuality': actualQuality,
    'processingFailed': processingFailed,
    'outputMissing': outputMissing,
    'outputDeleted': outputDeleted,
    'bytesPerSecond': bytesPerSecond,
    'retryCount': retryCount,
    'receiptOperationId': receiptOperationId,
    'finalPath': finalPath,
    'retryAt': retryAt?.toUtc().toIso8601String(),
    'attemptedAccounts': attemptedAccounts,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> value) {
    int integer(String key, [int fallback = 0]) {
      final number = value[key];
      if (number == null) return fallback;
      if (number is! int || number < 0) throw const FormatException('下载任务数字无效');
      return number;
    }

    final rate = value['bytesPerSecond'] ?? 0;
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['accountIdentity'] is! String ||
        (value['accountIdentity'] as String).isEmpty ||
        value['rootDirectory'] is! String ||
        value['track'] is! Map ||
        value['settings'] is! Map ||
        rate is! num ||
        !rate.isFinite ||
        rate < 0 ||
        value['userConfirmed'] is! bool ||
        value['needsConfirmation'] is! bool) {
      throw const FormatException('下载任务资料无效');
    }
    return DownloadTask(
      id: value['id'] as String,
      accountIdentity: value['accountIdentity'] as String,
      track: Track.fromJson(Map<String, dynamic>.from(value['track'] as Map)),
      rootDirectory: value['rootDirectory'] as String,
      settings: Map<String, dynamic>.from(value['settings'] as Map),
      createdAt: DateTime.parse(value['createdAt'] as String),
      state: DownloadState.values.byName(value['state'] as String),
      costSeconds: integer('costSeconds'),
      expectedBalance: value['expectedBalance'] == null
          ? null
          : integer('expectedBalance'),
      userConfirmed: value['userConfirmed'] as bool,
      needsConfirmation: value['needsConfirmation'] as bool,
      error: value['error'] as String?,
      receivedBytes: integer('receivedBytes'),
      warning: value['warning'] as String?,
      actualQuality: value['actualQuality'] as String?,
      processingFailed: value['processingFailed'] as bool? ?? false,
      outputMissing: value['outputMissing'] as bool? ?? false,
      outputDeleted: value['outputDeleted'] as bool? ?? false,
      totalBytes: value['totalBytes'] == null ? null : integer('totalBytes'),
      bytesPerSecond: rate.toDouble(),
      retryCount: integer('retryCount'),
      receiptOperationId: value['receiptOperationId'] as String?,
      finalPath: value['finalPath'] as String?,
      retryAt: value['retryAt'] == null
          ? null
          : DateTime.parse(value['retryAt'] as String),
      attemptedAccounts: List<String>.unmodifiable(
        (value['attemptedAccounts'] as List? ?? const []).cast<String>(),
      ),
    );
  }

  static Map<String, dynamic> _snapshot(Map<String, dynamic> settings) {
    Object? freeze(Object? value) {
      if (value is Map) {
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          if (entry.key is! String ||
              RegExp(
                r'(?:url|uri)$|^(?:headers?|cookie2?|token|device_?id|x-tk|credentials?|password)$',
                caseSensitive: false,
              ).hasMatch(entry.key as String)) {
            throw const FormatException('下载设置不能包含登录信息或媒体地址');
          }
          result[entry.key as String] = freeze(entry.value);
        }
        return Map<String, dynamic>.unmodifiable(result);
      }
      if (value is List) return List<dynamic>.unmodifiable(value.map(freeze));
      if (value == null ||
          value is String ||
          value is bool ||
          (value is num && value.isFinite))
        return value;
      throw const FormatException('下载设置无效');
    }

    // Check encodability at the boundary rather than during a later debit commit.
    jsonEncode(settings);
    return _SettingsSnapshot(freeze(settings) as Map<String, dynamic>);
  }
}

class _SettingsSnapshot extends MapView<String, dynamic> {
  _SettingsSnapshot(Map<String, dynamic> value) : super(value);
}
