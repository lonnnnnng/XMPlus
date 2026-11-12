// Ported from the AGPL-3.0-or-later xmly Python component; see LICENSE/NOTICE.
import 'dart:convert';
import 'package:crypto/crypto.dart';

const int xmlyAlbumPageSize = 200;

class XmlyException implements Exception {
  final String code, message;
  final Duration? retryAfter;
  final bool definitive;
  const XmlyException(this.code, this.message, {this.retryAfter, this.definitive = false});
  @override
  String toString() => message;
}

String xmlyIdentifier(String value) {
  final match = RegExp(r'^(?:xmly:)?([1-9][0-9]{0,18})$').firstMatch(value);
  if (match == null) throw const XmlyException('invalid_id', '喜马拉雅 ID 必须是正整数或 xmly:正整数', definitive: true);
  return match[1]!;
}

int? xmlyPositive(Object? value) {
  if (value is int) return value > 0 ? value : null;
  if (value is! String || !RegExp(r'^[0-9]+$').hasMatch(value)) return null;
  final number = int.tryParse(value);
  return number != null && number > 0 ? number : null;
}

Map<String, dynamic> xmlyMap(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
String _text(Object? value) => value == null ? '' : value.toString();
int _count(Object? value) => value is num && value.isFinite && value >= 0 ? value.toInt() : 0;
bool? _flag(Object? value) => value is bool ? value : null;
Map<String, dynamic> _publicRaw(Map<String, dynamic> raw) {
  final result = <String, dynamic>{};
  for (final key in ['id', 'trackId', 'albumId', 'album_id', 'title', 'nickname', 'albumTitle', 'album_title',
    'duration', 'orderNo', 'orderNum', 'order_no', 'episode', 'sequence', 'index', 'officialPosition', 'isPaid', 'is_paid',
    'isAuthorized', 'intro', 'coverLarge', 'coverMiddle', 'coverSmall', 'cover_path', 'album_cover_path', 'cover_url',
    'albumImage', 'tracks', 'totalCount', 'total', 'year', 'date']) {
    final value = raw[key];
    if (value is String || value is bool || (value is num && value.isFinite)) result[key] = value;
  }
  final nickname = raw['userInfo'] is Map ? (raw['userInfo'] as Map)['nickname'] : null;
  if (nickname is String) result['userInfo'] = Map<String, dynamic>.unmodifiable({'nickname': nickname});
  return result;
}
Uri? _cover(Map<String, dynamic> raw) {
  for (final key in ['coverLarge', 'coverMiddle', 'coverSmall', 'cover_path', 'album_cover_path', 'cover_url', 'albumImage']) {
    final value = raw[key];
    if (value is! String || value.length > 16384 || RegExp(r'[\x00-\x20]').hasMatch(value)) continue;
    final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
    if (uri != null && ['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty && uri.userInfo.isEmpty) {
      return uri.scheme == 'http' && (uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com'))
        ? uri.replace(scheme: 'https') : uri;
    }
  }
  return null;
}

class Credentials {
  final String token, deviceId;
  Credentials({required String token, required String deviceId}) : token = token.trim().replaceFirst(RegExp(r'^1&_token='), ''), deviceId = deviceId.trim() {
    if (!RegExp(r'^[1-9][0-9]{0,19}&[A-Za-z0-9._~+/=\-]{1,8192}$').hasMatch(this.token)) {
      throw const XmlyException('invalid_credentials', '账号凭据必须是数字 UID 与登录令牌', definitive: true);
    }
    if (!RegExp(r'^[A-Za-z0-9_.:\-]{1,128}$').hasMatch(this.deviceId)) {
      throw const XmlyException('invalid_credentials', '请填写原设备 ID', definitive: true);
    }
  }
  static Credentials parse(Object input) {
    Object? value = input;
    if (value is String) {
      final text = value.trim();
      if (text.startsWith('{')) {
        try { value = jsonDecode(text); } catch (_) { throw const XmlyException('invalid_credentials', '登录信息 JSON 格式错误', definitive: true); }
      } else {
        value = {'cookie': text};
      }
    }
    if (value is! Map) throw const XmlyException('invalid_credentials', '登录信息格式错误', definitive: true);
    var map = xmlyMap(value);
    if (map['xmly'] is Map) map = xmlyMap(map['xmly']);
    if (map['config'] is Map) map = xmlyMap(map['config']);
    final headers = xmlyMap(map['headers']);
    final cookie = headers['cookie'] ?? headers['Cookie'] ?? map['cookie'];
    var token = map['token'];
    var device = map['device_id'] ?? map['deviceId'];
    if (cookie is String) {
      final parts = <String, String>{};
      for (final match in RegExp(r"""(?:^|[;:\s"'`])1&_(token|device)\s*=\s*([^;\s"'`\\,]+)""").allMatches(cookie)) {
        final key = '1&_${match[1]}', value = match[2]!;
        if (parts.containsKey(key) && parts[key] != value) {
          throw const XmlyException('invalid_credentials', '包含多组登录信息，请只保留一个账号的 Cookie', definitive: true);
        }
        parts[key] = value;
      }
      token ??= parts['1&_token'];
      final fields = (parts['1&_device'] ?? '').split('&');
      if (fields.length > 1) device ??= fields[1];
    }
    if (token is! String || device is! String) throw const XmlyException('invalid_credentials', '缺少账号令牌或原设备 ID', definitive: true);
    return Credentials(token: token, deviceId: device);
  }
  String get uid => token.split('&').first;
  String get identity => sha256.convert(utf8.encode('$uid|$deviceId')).toString();
  String get cacheIdentity => sha256.convert(utf8.encode('$token|android&$deviceId&3.4.10')).toString();
  String get cookie => '1&_token=$token; 1&_device=android&$deviceId&3.4.10; channel=and-f5; impl=com.ximalaya.ting.lite; appid=1463';
  Map<String, dynamic> toJson() => {'token': token, 'device_id': deviceId};
  @override
  String toString() => 'Credentials(redacted)';
}

class Album {
  final String id, title, artist, intro;
  final Uri? coverUrl;
  final int total;
  final Map<String, dynamic> raw;
  Album({required String id, this.title = '', this.artist = '', this.intro = '', this.coverUrl, this.total = 0, Map<String, dynamic> raw = const {}}) : id = xmlyIdentifier(id), raw = Map.unmodifiable(_publicRaw(raw));
  factory Album.fromApi(Map<String, dynamic> value) => Album(
    id: _text(value['albumId'] ?? value['id']), title: _text(value['title']),
    artist: _text(value['nickname'] ?? xmlyMap(value['userInfo'])['nickname']), intro: _text(value['intro']),
    coverUrl: _cover(value), total: _count(value['tracks'] ?? value['totalCount'] ?? value['total']), raw: value);
  factory Album.fromJson(Map<String, dynamic> value) => Album(
    id: _text(value['id']), title: _text(value['title']), artist: _text(value['artist']), intro: _text(value['intro']),
    coverUrl: _cover(value), total: _count(value['total']), raw: xmlyMap(value['raw']));
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'intro': intro, 'cover_url': coverUrl?.toString(), 'total': total, 'raw': raw};
}

class Track {
  final String id, title, artist, album, albumId, intro;
  final double duration;
  final int? orderNo, episode;
  final bool? isPaid, isAuthorized;
  final Uri? coverUrl;
  final Map<String, dynamic> raw;
  Track({required String id, this.title = '', this.artist = '', this.album = '', String albumId = '', double duration = 0,
    this.orderNo, this.episode, this.isPaid, this.isAuthorized, this.coverUrl, this.intro = '', Map<String, dynamic> raw = const {}})
    : id = 'xmly:${xmlyIdentifier(id)}', albumId = albumId.isEmpty ? '' : xmlyIdentifier(albumId),
      duration = duration.isFinite && duration >= 0 ? duration : 0, raw = Map.unmodifiable(_publicRaw(raw));
  String get number => id.substring(5);
  int? get officialPosition => xmlyPositive(raw['officialPosition']);
  factory Track.fromApi(Map<String, dynamic> value, {Album? album, int? position}) {
    final duration = value['duration'];
    return Track(id: _text(value['trackId'] ?? value['id']), title: _text(value['title']),
      artist: _text(value['nickname'] ?? xmlyMap(value['userInfo'])['nickname'] ?? album?.artist),
      album: _text(value['album_title'] ?? value['albumTitle'] ?? album?.title),
      albumId: _text(value['album_id'] ?? value['albumId'] ?? album?.id),
      duration: duration is num ? duration.toDouble() : 0,
      orderNo: xmlyPositive(value['orderNo']) ?? xmlyPositive(value['orderNum']), episode: xmlyPositive(value['episode']),
      isPaid: _flag(value['is_paid'] ?? value['isPaid']), isAuthorized: _flag(value['isAuthorized']),
      coverUrl: _cover(value) ?? album?.coverUrl, intro: _text(value['intro']),
      raw: {...value, if (position != null) 'officialPosition': position});
  }
  factory Track.fromJson(Map<String, dynamic> value) => Track(id: _text(value['id']), title: _text(value['title']), artist: _text(value['artist']),
    album: _text(value['album']), albumId: _text(value['album_id']), duration: value['duration'] is num ? (value['duration'] as num).toDouble() : 0,
    orderNo: xmlyPositive(value['order_no']), episode: xmlyPositive(value['episode']), isPaid: _flag(value['is_paid']),
    isAuthorized: _flag(value['is_authorized']), coverUrl: _cover(value), intro: _text(value['intro']), raw: xmlyMap(value['raw']));
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'album': album, 'album_id': albumId,
    'duration': duration, 'order_no': orderNo, 'episode': episode, 'is_paid': isPaid, 'is_authorized': isAuthorized,
    'cover_url': coverUrl?.toString(), 'intro': intro, 'raw': raw};
}

/// The persisted queue is always restored paused; playback state is not data.
class PlaybackQueue {
  PlaybackQueue({required this.tracks, required this.cursor,
      required this.sourceAlbumId, String? source, this.albumPage, this.albumTotal,
      int? albumPageSize})
      : source = source ?? (sourceAlbumId.isEmpty ? 'custom' : 'album'),
        albumPageSize = albumPage == null ? albumPageSize : albumPageSize ?? xmlyAlbumPageSize,
        needsRepair = false {
    if (tracks.length > 5000 || cursor < -1 || cursor >= tracks.length ||
        (tracks.isNotEmpty && cursor < 0)) {
      throw const FormatException('播放队列损坏');
    }
    if (!const {'album', 'updates', 'custom'}.contains(this.source) ||
        (this.source == 'album') != sourceAlbumId.isNotEmpty) {
      throw const FormatException('播放队列来源损坏');
    }
    if (sourceAlbumId.isNotEmpty && xmlyIdentifier(sourceAlbumId) != sourceAlbumId) {
      throw const FormatException('播放队列损坏');
    }
    if ((albumPage == null) != (albumTotal == null) ||
        (albumPage == null) != (this.albumPageSize == null) ||
        (albumPage != null && (this.source != 'album' || tracks.isEmpty ||
          (this.albumPageSize != 50 && this.albumPageSize != xmlyAlbumPageSize) ||
          albumPage! < 1 || albumPage! > 5000 ~/ this.albumPageSize! ||
          albumTotal! < 0 || albumTotal! > 5000))) {
      throw const FormatException('播放队列分页损坏');
    }
    final ids = <String>{};
    for (final track in tracks) {
      if (!ids.add(track.id) ||
          (sourceAlbumId.isNotEmpty && track.albumId != sourceAlbumId)) {
        throw const FormatException('播放队列损坏');
      }
    }
  }
  PlaybackQueue._empty({this.needsRepair = false})
      : tracks = const [], cursor = -1, sourceAlbumId = '', source = 'custom',
        albumPage = null, albumTotal = null, albumPageSize = null;

  final List<Track> tracks;
  final int cursor;
  /// Last loaded natural ascending page at albumPageSize; total 0 is unknown.
  /// Old paged queues without a size used 50; pre-paging queues omit all three.
  final int? albumPage, albumTotal, albumPageSize;
  final String sourceAlbumId, source;
  final bool needsRepair;

  factory PlaybackQueue.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('播放队列损坏');
    if (value.isEmpty) return PlaybackQueue._empty();
    // Older restore code added only these markers to an otherwise empty queue.
    if (value.length == 3 && value['playing'] == false &&
        value['autoStart'] == false && value['state'] == 'paused') {
      return PlaybackQueue._empty(needsRepair: true);
    }
    final tracks = value['tracks'], cursor = value['cursor'];
    final album = value['sourceAlbumId'], source = value['source'];
    if (tracks is! List || tracks.length > 5000 || cursor is! int || album is! String) {
      throw const FormatException('播放队列损坏');
    }
    if (source != null && source is! String) {
      throw const FormatException('播放队列来源损坏');
    }
    final page = value['albumPage'], total = value['albumTotal'];
    if ((value.containsKey('albumPage') || value.containsKey('albumTotal')) &&
        (page is! int || total is! int)) {
      throw const FormatException('播放队列分页损坏');
    }
    final size = value.containsKey('albumPageSize') ? value['albumPageSize'] :
      (page == null ? null : 50);
    if (value.containsKey('albumPageSize') && size is! int) {
      throw const FormatException('播放队列分页损坏');
    }
    final restored = <Track>[];
    for (final item in tracks) {
      if (item is! Map) throw const FormatException('播放队列损坏');
      restored.add(Track.fromJson(Map<String, dynamic>.from(item)));
    }
    return PlaybackQueue(tracks: restored, cursor: cursor,
      sourceAlbumId: album, source: source as String?,
      albumPage: page as int?, albumTotal: total as int?, albumPageSize: size as int?);
  }

  Map<String, dynamic> toJson() =>
    tracks.isEmpty && sourceAlbumId.isEmpty && source == 'custom' ? {} : {
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'cursor': cursor, 'sourceAlbumId': sourceAlbumId, 'source': source,
      if (albumPage != null) 'albumPage': albumPage,
      if (albumTotal != null) 'albumTotal': albumTotal,
      if (albumPageSize != null) 'albumPageSize': albumPageSize,
    };
}

class Quota {
  final int remainingSeconds;
  final bool newDevice;
  final DateTime checkedAt;
  Quota({required this.remainingSeconds, required this.newDevice, required this.checkedAt}) {
    if (remainingSeconds < 0) throw const XmlyException('invalid_quota', '听时余额无效');
  }
  Map<String, dynamic> toJson() => {'remaining_seconds': remainingSeconds, 'new_device': newDevice, 'checked_at': checkedAt.millisecondsSinceEpoch};
  factory Quota.fromJson(Map<String, dynamic> value) {
    if (value['remaining_seconds'] is! int || value['new_device'] is! bool || value['checked_at'] is! int) throw const XmlyException('invalid_quota', '听时信息无效');
    return Quota(remainingSeconds: value['remaining_seconds'] as int, newDevice: value['new_device'] as bool, checkedAt: DateTime.fromMillisecondsSinceEpoch(value['checked_at'] as int));
  }
}
class ResolvedAudio {
  Uri _uri;
  Uri get uri => _uri;
  final Map<String, String> headers;
  final bool requiresReward;
  final Track track;
  final String actualQuality, accountIdentity;
  DateTime? _expiresAt;
  DateTime? get expiresAt => _expiresAt;
  final DateTime? Function(Uri) _cacheFinalUri;
  final void Function() invalidateCachedUri;
  ResolvedAudio({required Uri uri, this.headers = const {}, required this.requiresReward,
    required this.track, required this.actualQuality, required this.accountIdentity,
    required DateTime? expiresAt, required DateTime? Function(Uri) cacheFinalUri,
    required this.invalidateCachedUri}) : _uri = uri, _expiresAt = expiresAt,
      _cacheFinalUri = cacheFinalUri;

  /// Called only after the byte producer validates a successful media response.
  void rememberFinalUri(Uri uri) {
    final deadline = _cacheFinalUri(uri);
    _uri = uri;
    if (deadline != null && (_expiresAt == null || deadline.isBefore(_expiresAt!))) _expiresAt = deadline;
  }
}
class SearchPage {
  final List<Track> tracks;
  final List<Album> albums;
  final int page, pageSize, total;
  final String kind;
  SearchPage({this.tracks = const [], this.albums = const [], required this.page, required this.pageSize, required this.total, required this.kind});
}
class AlbumPage {
  final Album album;
  final List<Track> tracks;
  final int page, pageSize, total;
  AlbumPage({required this.album, required this.tracks, required this.page, required this.pageSize, required this.total});
}
