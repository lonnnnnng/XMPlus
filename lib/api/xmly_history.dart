// SPDX-License-Identifier: AGPL-3.0-or-later
// Port of xmly/history.py. Cloud progress is independent of listening debit.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/xmly_models.dart';
import 'xmly_client.dart';

class XmlyHistory {
  XmlyHistory(this.client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final XmlyClient client;
  final DateTime Function() _clock;
  static const _material =
      '23627d1451047b8d257a96af5db359538f081d651df75b4aa169508547208159';

  static String signature(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final text =
        '${keys.map((key) => '$key=${params[key]}&').join()}$_material';
    // Native PLAY performs ASCII lowercasing, not Unicode case folding.
    final asciiLower = String.fromCharCodes(
      text.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c),
    );
    return md5.convert(utf8.encode(asciiLower)).toString();
  }

  static int _integer(Object? value, [int fallback = 0]) => value is int
      ? value
      : value is String
      ? int.tryParse(value) ?? fallback
      : fallback;

  static String _id(String value) {
    final match = RegExp(r'^(?:xmly:)?([1-9][0-9]{0,18})$').firstMatch(value);
    if (match == null) throw ArgumentError('喜马拉雅 ID 无效');
    return match[1]!;
  }

  Map<String, String> _context() {
    final context = client.context();
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(context['uid'] ?? '') ||
        (context['token'] ?? '').isEmpty ||
        context['device'] != 'android' ||
        (context['deviceId'] ?? '').isEmpty ||
        (context['version'] ?? '').isEmpty ||
        (context['channel'] ?? '').isEmpty ||
        context['impl'] != 'com.ximalaya.ting.lite') {
      throw XmlyException('auth_required', '历史同步需要有效的极速版登录态');
    }
    return context;
  }

  static Map<String, dynamic>? normalize(Object? raw) {
    if (raw is! Map ||
        ![1, 9].contains(_integer(raw['type'])) ||
        _integer(raw['deleteTime']) > 0)
      return null;
    String track, album;
    try {
      track = _id('${raw['childId']}');
      album = _id('${raw['itemId']}');
    } on ArgumentError {
      return null;
    }
    final duration = _integer(raw['length']).clamp(0, 2147483647);
    var position = _integer(raw['breakSecond']).clamp(0, 2147483647);
    if (duration > 0) position = position.clamp(0, duration);
    final cover = Album.fromApi({
      'albumId': album,
      'cover_url': raw['itemCoverUrl'],
    }).coverUrl;
    return {
      'track_id': 'xmly:$track',
      'album_id': album,
      'position': position.toDouble(),
      'duration': duration.toDouble(),
      'title': '${raw['childTitle'] ?? ''}',
      'album_title': '${raw['itemTitle'] ?? ''}',
      if (cover != null) 'cover_url': cover.toString(),
      'updated_at': _integer(raw['endedAt']).clamp(0, 2115354119000) / 1000.0,
    };
  }

  static Map<String, dynamic> _data(Map<String, dynamic> response) {
    Object? data = response['data'];
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        data = null;
      }
    }
    if (data is! Map<String, dynamic>) {
      throw XmlyException('invalid_response', '历史记录格式无效');
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> records() => _records();

  Future<List<Map<String, dynamic>>> _records({
    bool Function()? isActive,
    void Function(Iterable<Map<String, dynamic>>)? onPage,
  }) async {
    final context = _context();
    final identity = client.cacheIdentity;
    final items = <String, Map<String, dynamic>>{};
    final pages = <String>{};
    for (var page = 1; page <= 50; page++) {
      if (isActive != null && !isActive()) return const [];
      final response = await client.request(
        'GET',
        XmlyClient.mobile,
        '/nyx/v1/history/query/android',
        query: {
          'pageId': '$page',
          'pageSize': '100',
          'syncPoint': '0',
          'timeStamp': '${_clock().millisecondsSinceEpoch}',
          'uid': context['uid'],
        },
      );
      if (isActive != null && !isActive()) return const [];
      if (identity != client.cacheIdentity) {
        throw XmlyException('account_changed', '查询期间账号已变更，请重试');
      }
      final data = _data(response);
      final raw = data['listenModels'];
      final more = data['hasMore'] ?? false;
      if (raw is! List || more is! bool || raw.length > 100) {
        throw XmlyException('invalid_response', '历史分页格式无效');
      }
      if (raw.isNotEmpty && !pages.add(jsonEncode(raw))) {
        throw XmlyException('repeated_page', '历史服务返回重复分页');
      }
      for (final row in raw) {
        final item = normalize(row);
        if (item == null) continue;
        final id = item['track_id'] as String;
        if (!items.containsKey(id) ||
            (item['updated_at'] as double) >
                (items[id]!['updated_at'] as double)) {
          items[id] = item;
        }
      }
      onPage?.call(items.values);
      if (!more) {
        return items.values.toList()..sort(
          (a, b) =>
              (b['updated_at'] as double).compareTo(a['updated_at'] as double),
        );
      }
      if (raw.isEmpty) throw XmlyException('invalid_response', '历史分页未返回记录');
    }
    throw XmlyException('history_limit', '历史记录超过 5000 条上限');
  }

  Future<Map<String, dynamic>> list({int page = 1, int pageSize = 50}) async {
    if (page < 1 || page > 10000 || pageSize < 1 || pageSize > 50) {
      throw ArgumentError('历史分页参数无效');
    }
    final items = await records();
    return {
      'items': items.skip((page - 1) * pageSize).take(pageSize).toList(),
      'page': page,
      'page_size': pageSize,
      'total': items.length,
    };
  }

  Future<Map<String, dynamic>?> progress({
    String albumId = '',
    String trackId = '',
    Duration? timeout,
  }) async {
    final album = albumId.isEmpty ? '' : _id(albumId);
    final track = trackId.isEmpty ? '' : 'xmly:${_id(trackId)}';
    if (album.isEmpty && track.isEmpty) throw ArgumentError('请指定声音或专辑');
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError('历史查询等待时间无效');
    }
    var active = true;
    Map<String, dynamic>? latest;
    final scan = _records(
      isActive: () => active,
      onPage: (items) {
        latest = null;
        for (final item in items) {
          if ((album.isEmpty || item['album_id'] == album) &&
              (track.isEmpty || item['track_id'] == track) &&
              (latest == null ||
                  (item['updated_at'] as double) >
                      (latest!['updated_at'] as double))) {
            latest = item;
          }
        }
      },
    ).then((_) => latest);
    try {
      return await (timeout == null
          ? scan
          : scan.timeout(
              timeout,
              onTimeout: () {
                if (latest == null) {
                  throw const XmlyException('history_timeout', '云进度查询超时');
                }
                return {...latest!, 'incomplete': true};
              },
            ));
    } finally {
      // An in-flight page may finish later; do not fetch more or change playback.
      active = false;
    }
  }

  /// Explicit write only; retries reuse the same absolute history snapshot.
  Future<void> sync(
    Track track,
    double position,
    int startedAtMs,
    int endedAtMs,
  ) async {
    if (!track.id.startsWith('xmly:')) throw ArgumentError('只能同步喜马拉雅声音');
    final id = _id(track.id);
    final album = _id(
      track.albumId.isNotEmpty
          ? track.albumId
          : '${track.raw['album_id'] ?? track.raw['albumId'] ?? ''}',
    );
    if (!position.isFinite ||
        position < 0 ||
        position > 2147483647 ||
        startedAtMs <= 0 ||
        startedAtMs > endedAtMs ||
        endedAtMs > 2115354119000) {
      throw ArgumentError('播放进度或收听起止时间无效');
    }
    if (track.duration.isFinite && track.duration > 0) {
      position = position.clamp(0, track.duration);
    }
    if (endedAtMs == startedAtMs) {
      endedAtMs = _clock().millisecondsSinceEpoch.clamp(
        startedAtMs,
        2115354119000,
      );
    }
    final direction = track.raw['direction'] ?? 0;
    if (direction is! int || (direction != 0 && direction != 1)) {
      throw ArgumentError('专辑播放顺序无效');
    }
    final params = <String, String>{
      'mergeRecords': jsonEncode([
        {
          'endedAt': '$endedAtMs',
          'startedAt': '$startedAtMs',
          'type': '1',
          'itemId': album,
          'childId': id,
          'breakSecond': '${position.truncate()}',
          'direction': direction,
        },
      ]),
    };
    params['signature'] = signature({...params, ..._context()});
    final identity = client.cacheIdentity;
    final response = await client.request(
      'POST',
      XmlyClient.collector,
      '/nyx/v1/history/merge/android',
      data: params,
      form: true,
    );
    if (identity != client.cacheIdentity) {
      throw XmlyException('account_changed', '同步期间账号已变更');
    }
    if (_integer(_data(response)['syncPoint'], -1) < 0) {
      throw XmlyException('history_unconfirmed', '未能确认历史进度同步');
    }
  }
}
