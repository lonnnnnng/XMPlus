// Ported from xmly/client.py (AGPL-3.0-or-later). No automatic reward claims.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../models/xmly_models.dart';
import '../services/request_diagnostics.dart';
import 'xmly_crypto.dart';

class XmlyClient {
  static const mobile = 'https://mobile.ximalaya.com';
  static const cachedAlbumOrigin = 'https://mobwsa.ximalaya.com';
  static const searchOrigin = 'https://www.ximalaya.com';
  static const collector = 'https://xdcs-collector.ximalaya.com';
  static const welfare = 'https://m.ximalaya.com';
  static const _maxResponse = 2 * 1024 * 1024;
  static const _maxCachedAlbumResponse = 16 * 1024 * 1024;
  static const _qualities = ['m4a_128', 'm4a_64', 'mp3_64', 'mp3_32', 'm4a_24'];
  static const _maxUrlCacheFile = 16 * 1024 * 1024;
  final Credentials? credentials;
  final String quality;
  final Dio _dio;
  final Completer<void> _closeSignal = Completer<void>();
  final Lock _resolveLock = Lock();
  final Map<String, DateTime> _cooldowns = {};
  final Map<String, Track> _metadata = {};
  final Map<String, Album> _albums = {};
  final Map<String, _CachedAudioUrl> _urls = {};
  int _urlEpoch = 0;
  bool _expired = false, _closed = false;
  String? _urlCachePath;
  int _urlCacheRevision = 0;
  bool _urlCacheLoaded = false, _discardUrlCacheLoad = false;
  final Set<String> _urlLoadInvalidations = {};
  Future<void> _urlCacheWork = Future<void>.value();
  Future<void> _urlCacheReady = Future<void>.value();
  Quota? _quota;
  void invalidateQuota() {
    _quota = null;
  }

  XmlyClient({
    this.credentials,
    Dio? dio,
    this.quality = 'auto',
    String? urlCacheDirectory,
  }) : _dio = dio ?? Dio() {
    if (quality != 'auto' && !_qualities.contains(quality))
      throw const XmlyException('invalid_quality', '音质设置无效', definitive: true);
    // This client has no shared cookie jar or redirect interceptor.
    _dio.interceptors.clear();
    _dio.options.headers.clear();
    _dio.options.connectTimeout = const Duration(seconds: 10);
    if (urlCacheDirectory != null) attachUrlCache(urlCacheDirectory);
  }
  String get identity => credentials?.identity ?? 'anonymous';
  String get cacheIdentity => credentials?.cacheIdentity ?? 'anonymous';
  bool get accountAvailable => credentials != null && !_expired;
  Map<String, String> context() {
    final value = _requireAccount();
    return {
      'uid': value.uid,
      'token': value.token.split('&').skip(1).join('&'),
      'device': 'android',
      'deviceId': value.deviceId,
      'version': '3.4.10',
      'channel': 'and-f5',
      'impl': 'com.ximalaya.ting.lite',
    };
  }

  Credentials _requireAccount() {
    if (credentials == null)
      throw const XmlyException(
        'login_required',
        '请先导入极速版登录信息',
        definitive: true,
      );
    if (_expired)
      throw const XmlyException(
        'login_expired',
        '登录信息已失效，请重新登录',
        definitive: true,
      );
    return credentials!;
  }

  static bool _cachedAlbumEndpoint(String method, String origin, String path) =>
      method == 'GET' &&
      origin == cachedAlbumOrigin &&
      RegExp(r'^/fmobile-album/album/track/ts-[0-9]+$').hasMatch(path);
  static bool _endpoint(String method, String origin, String path) {
    if (origin == cachedAlbumOrigin)
      return _cachedAlbumEndpoint(method, origin, path);
    if (origin == searchOrigin)
      return method == 'GET' && path == '/revision/search';
    if (origin == collector)
      return method == 'POST' && path == '/nyx/v1/history/merge/android';
    if (origin == welfare)
      return (method == 'GET' &&
              RegExp(
                r'^/lite-earn/ting/welfare/queryVipDurationTask/ts-[0-9]+$',
              ).hasMatch(path)) ||
          (method == 'POST' &&
              RegExp(r'^/lite-earn/ting/welfare/rewardDuration/ts-[0-9]+$')
                  .hasMatch(path));
    if (origin != mobile) return false;
    if (method == 'POST')
      return const [
        '/fmobile-track/fmobile/track/v2/baseInfo',
        '/lite-mobile/audi/func/v1/config',
        '/lite-mobile/audi/func/v1/report',
      ].contains(path);
    return method == 'GET' &&
        (const [
              '/mobile/v1/album/track/v2',
              '/nyx/v1/history/query/android',
            ].contains(path) ||
            RegExp(r'^/mobile/track/[1-9][0-9]{0,18}$').hasMatch(path) ||
            RegExp(r'^/fmobile-album/album/track/ts-[0-9]+$').hasMatch(path) ||
            RegExp(r'^/lite-mobile/index/v1/(?:subPages|modules)/[0-9]+$')
                .hasMatch(path) ||
            RegExp(r'^/fsubscribe-web/subscribe/comprehensive/rank/[0-9]+$')
                .hasMatch(path) ||
            RegExp(r'^/track-feed/v1/track-feed/dynamic/ts-[0-9]+$')
                .hasMatch(path));
  }

  static Duration _retryAfter(String? value) {
    var seconds = double.tryParse(value ?? '');
    if (seconds == null) {
      try {
        seconds =
            HttpDate.parse(value!)
                .difference(DateTime.now().toUtc())
                .inMilliseconds /
            1000;
      } catch (_) {
        seconds = 30;
      }
    }
    if (!seconds.isFinite) seconds = 30;
    return Duration(milliseconds: (seconds.clamp(1, 86400) * 1000).ceil());
  }

  Never _rateLimit(String origin, Duration delay) {
    _cooldowns[origin] = DateTime.now().add(delay);
    throw XmlyException(
      'rate_limited',
      '请求过于频繁，请在 ${delay.inSeconds + (delay.inMilliseconds % 1000 == 0 ? 0 : 1)} 秒后重试',
      retryAfter: delay,
      definitive: true,
    );
  }

  void _expire() {
    if (_closed) return;
    _expired = true;
    _quota = null;
    unawaited(clearUrlCache());
  }

  Future<void> _retryWait(Duration delay) async {
    final ready = Completer<void>();
    final timer = Timer(delay, ready.complete);
    try {
      await Future.any<void>([ready.future, _closeSignal.future]);
    } finally {
      timer.cancel();
    }
  }

  Future<Map<String, dynamic>> request(
    String method,
    String origin,
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    bool account = true,
    bool signed = false,
    bool form = false,
  }) async {
    if (_closed)
      throw const XmlyException('client_closed', '连接已关闭', definitive: true);
    method = method.toUpperCase();
    if (!_endpoint(method, origin, path) || (account && origin == searchOrigin))
      throw const XmlyException(
        'invalid_endpoint',
        '请求地址不受支持',
        definitive: true,
      );
    if (signed &&
        (origin != mobile ||
            path != '/fmobile-track/fmobile/track/v2/baseInfo'))
      throw const XmlyException(
        'invalid_endpoint',
        '签名请求地址不受支持',
        definitive: true,
      );
    final authenticated = account && credentials != null;
    if (authenticated) _requireAccount();
    if (signed && !authenticated)
      throw const XmlyException('login_required', '签名请求需要登录', definitive: true);
    final readOnly =
        method == 'GET' ||
        (origin == mobile &&
            method == 'POST' &&
            const [
              '/fmobile-track/fmobile/track/v2/baseInfo',
              '/lite-mobile/audi/func/v1/config',
            ].contains(path)) ||
        (origin == collector &&
            method == 'POST' &&
            path == '/nyx/v1/history/merge/android');
    final rewardClaim =
        method == 'POST' &&
        origin == welfare &&
        RegExp(r'^/lite-earn/ting/welfare/rewardDuration/ts-[0-9]+$')
            .hasMatch(path);
    for (var attempt = 0; attempt < 5; attempt++) {
      final until = _cooldowns[origin];
      if (until != null && until.isAfter(DateTime.now())) {
        await _retryWait(until.difference(DateTime.now()));
      }
      if (_closed)
        throw const XmlyException('client_closed', '连接已关闭', definitive: true);
      final cancel = CancelToken();
      final diagnostic = RequestDiagnostic(
        account: identity,
        method: method,
        url: '$origin$path',
      );
      try {
        return await _attempt(
          method,
          origin,
          path,
          query,
          data,
          authenticated,
          signed,
          form,
          cancel,
          diagnostic,
        ).timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            cancel.cancel();
            unawaited(
              diagnostic.fail(TimeoutException('request (25 seconds)')),
            );
            throw TimeoutException('request');
          },
        );
      } on _RetryableStatus {
        if (!readOnly || attempt == 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '喜马拉雅服务暂时不可用' : '请求结果未知，请核对后重试',
          );
      } on DioException catch (error) {
        if (error.error case final XmlyException limit
            when limit.code == 'response_too_large')
          throw limit;
        if (cancel.cancelError?.error case final XmlyException limit
            when limit.code == 'response_too_large')
          throw limit;
        if (!readOnly || attempt == 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on TimeoutException {
        if (!readOnly || attempt == 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on IOException {
        if (!readOnly || attempt == 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on XmlyException catch (error) {
        final safeRewardRejection =
            rewardClaim &&
            error.code == 'rejected' &&
            diagnostic.status == 200 &&
            error.definitive;
        if ((error.code != 'rate_limited' && !safeRewardRejection) ||
            attempt == 4)
          rethrow;
      }
      final backoff = Duration(seconds: 1 << attempt);
      final cooldown = _cooldowns[origin]?.difference(DateTime.now());
      await _retryWait(
        cooldown != null && cooldown > backoff ? cooldown : backoff,
      );
    }
    throw const XmlyException('network', '请求失败');
  }

  Future<Map<String, dynamic>> _attempt(
    String method,
    String origin,
    String path,
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    bool authenticated,
    bool signed,
    bool form,
    CancelToken cancel,
    RequestDiagnostic diagnostic,
  ) async {
    final responseLimit = _cachedAlbumEndpoint(method, origin, path)
        ? _maxCachedAlbumResponse
        : _maxResponse;
    late final limitError = XmlyException(
      'response_too_large',
      '响应超过 ${responseLimit ~/ (1024 * 1024)} MiB 上限',
    );
    final headers = <String, String>{
      'Accept': origin == collector ? '*/*' : 'application/json',
      if (origin == collector) 'User-Agent': 'ting_3.4.10.3(Android,30)',
      if (authenticated) 'Cookie': credentials!.cookie,
      if (signed) 'x-tk': XmlyCrypto.freshTicket(credentials!),
    };
    final options =
        Options(
          method: method,
          headers: headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 25),
          sendTimeout: const Duration(seconds: 25),
          contentType: form
              ? Headers.formUrlEncodedContentType
              : Headers.jsonContentType,
        ).compose(
          _dio.options,
          '$origin$path',
          queryParameters: query,
          data: data,
          cancelToken: cancel,
          onReceiveProgress: (received, _) {
            if (received > responseLimit) cancel.cancel(limitError);
          },
        );
    diagnostic.url = options.uri.toString();
    diagnostic.requestHeaders = options.headers;
    diagnostic.requestBody = data == null
        ? '(无请求体)'
        : form
        ? Transformer.urlEncodeMap(data, ListFormat.multi)
        : jsonEncode(data);
    final bytes = BytesBuilder(copy: false);
    diagnostic.responseByteCount = () => bytes.length;
    try {
      final response = await _dio.fetch<ResponseBody>(options);
      final body = response.data;
      final status = response.statusCode ?? 0;
      diagnostic.status = status;
      diagnostic.responseHeaders = response.headers.map;
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (body != null) {
        diagnostic.completeness = '响应体未接收完整（接收中或传输中断）';
        if (length != null && length > responseLimit) {
          diagnostic.completeness =
              '未读取响应体：声明长度 $length 超过 $responseLimit 字节上限';
          await body.stream.listen((_) {}).cancel();
          if (status == 200) throw limitError;
        } else {
          try {
            await for (final chunk in body.stream) {
              final remaining = responseLimit - bytes.length;
              if (chunk.length > remaining) {
                if (remaining > 0)
                  bytes.add(Uint8List.sublistView(chunk, 0, remaining));
                diagnostic.completeness = '响应体已截断：$responseLimit 字节上限';
                cancel.cancel(limitError);
                throw limitError;
              }
              bytes.add(chunk);
            }
            diagnostic.completeness = length != null && length != bytes.length
                ? '响应体不完整：声明 $length 字节，收到 ${bytes.length} 字节'
                : '完整（HTTP 客户端解码后的响应体）';
          } catch (error) {
            diagnostic.transportError = '$error';
            if (status == 200) rethrow;
          }
        }
      }
      if (status != 200) {
        if (status == 429)
          _rateLimit(
            origin,
            _retryAfter(response.headers.value('retry-after')),
          );
        if (status == 401 || (status == 403 && authenticated)) {
          if (authenticated) _expire();
          throw const XmlyException(
            'login_expired',
            '登录信息已失效，请重新登录',
            definitive: true,
          );
        }
        if (status >= 500 && status <= 599) throw _RetryableStatus();
        throw XmlyException(
          status >= 400 && status < 500 ? 'rejected' : 'protocol',
          '接口返回 HTTP $status',
          definitive: status >= 400 && status < 500,
        );
      }
      if (body == null) throw const XmlyException('invalid_json', '接口响应为空');
      final responseBytes = bytes.takeBytes();
      diagnostic.responseByteCount = () => responseBytes.length;
      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(
          utf8.decode(responseBytes, allowMalformed: false),
        );
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        payload = decoded;
      } catch (_) {
        throw const XmlyException('invalid_json', '接口返回无效 JSON');
      }
      final code = '${payload['ret'] ?? 0}';
      if (code != (origin == searchOrigin ? '200' : '0')) {
        if (code == '429') _rateLimit(origin, const Duration(seconds: 30));
        if (code == '401') {
          if (authenticated) _expire();
          throw const XmlyException(
            'login_expired',
            '登录信息已失效，请重新登录',
            definitive: true,
          );
        }
        if (['5', '403', '726'].contains(code))
          throw const XmlyException(
            'permission_denied',
            '未获得本次请求的完整权限，请检查账号、听时和版权限制',
            definitive: true,
          );
        throw const XmlyException('rejected', '喜马拉雅拒绝了请求', definitive: true);
      }
      return payload;
    } catch (error) {
      await diagnostic.fail(error);
      rethrow;
    }
  }

  static void _paging(int page, int pageSize, {int maxPageSize = 50}) {
    if (page < 1 || page > 10000 || pageSize < 1 || pageSize > maxPageSize)
      throw XmlyException(
        'invalid_page',
        '页码范围为 1..10000，每页 1..$maxPageSize',
        definitive: true,
      );
  }

  static int _total(Object? value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.truncateToDouble())
      throw const XmlyException('invalid_page', '服务端分页总数无效');
    return value.toInt();
  }

  void _remember(Track value) {
    _metadata[value.number] = value;
    while (_metadata.length > 512) {
      _metadata.remove(_metadata.keys.first);
    }
  }

  Future<SearchPage> search(
    String query, {
    String kind = 'track',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (query.trim().isEmpty ||
        query.length > 200 ||
        !['track', 'album'].contains(kind))
      throw const XmlyException(
        'invalid_search',
        '请输入 1..200 字的关键词',
        definitive: true,
      );
    _paging(page, pageSize);
    // Endpoint contract: qilishidai/ximalaya-API, Search_API.md; see NOTICE.
    final response = await request(
      'GET',
      searchOrigin,
      '/revision/search',
      account: false,
      query: {
        'kw': query.trim(),
        'core': kind,
        'page': page,
        'rows': pageSize,
        'device': 'iPhone',
        'condition': 'relation',
        'spellchecker': 'true',
      },
    );
    final values = xmlyMap(
      xmlyMap(xmlyMap(response['data'])['result'])['response'],
    );
    if (values['docs'] is! List)
      throw const XmlyException('invalid_catalogue', '搜索结果无效');
    final docs = (values['docs'] as List).take(pageSize);
    final tracks = <Track>[], albums = <Album>[];
    for (final raw in docs) {
      if (raw is! Map) throw const XmlyException('invalid_catalogue', '搜索结果无效');
      if (kind == 'album') {
        final item = Album.fromApi(xmlyMap(raw));
        albums.add(item);
        _albums[item.id] = item;
        while (_albums.length > 512) {
          _albums.remove(_albums.keys.first);
        }
      } else {
        final item = Track.fromApi(xmlyMap(raw));
        tracks.add(item);
        _remember(item);
      }
    }
    return SearchPage(
      tracks: tracks,
      albums: albums,
      page: page,
      pageSize: pageSize,
      total: _total(values['numFound'] ?? 0),
      kind: kind,
    );
  }

  /// A validated ascending prefix, not necessarily a complete catalogue: the
  /// cache server can cap page one at 200 despite the requested 100000 items.
  Future<AlbumPage> cachedAlbum(String albumId) async {
    final number = xmlyIdentifier(albumId);
    _requireAccount();
    try {
      final response = await request(
        'GET',
        cachedAlbumOrigin,
        '/fmobile-album/album/track/ts-${DateTime.now().millisecondsSinceEpoch}',
        query: {
          'albumId': number,
          'device': 'android',
          'isAsc': 'true',
          'isQueryInvitationBrand': 'true',
          'pageId': 1,
          'pageSize': 100000,
        },
      );
      return await _readAlbumPage(
        response,
        number,
        page: 1,
        pageSize: 100000,
        ascending: true,
        cached: true,
      );
    } on XmlyException catch (error) {
      if (const [
        'rate_limited',
        'login_expired',
        'login_required',
        'permission_denied',
        'client_closed',
      ].contains(error.code))
        rethrow;
      throw const XmlyException('invalid_cached_catalogue', '历史目录不可用，请使用实时目录');
    } on FormatException {
      throw const XmlyException('invalid_cached_catalogue', '历史目录不可用，请使用实时目录');
    } on TypeError {
      throw const XmlyException('invalid_cached_catalogue', '历史目录不可用，请使用实时目录');
    }
  }

  Future<AlbumPage> album(
    String albumId, {
    int page = 1,
    int pageSize = xmlyAlbumPageSize,
    bool ascending = true,
  }) async {
    final number = xmlyIdentifier(albumId);
    _paging(page, pageSize, maxPageSize: xmlyAlbumPageSize);
    final query = <String, dynamic>{
      'albumId': number,
      'pageId': page,
      'pageSize': pageSize,
      'isAsc': '$ascending',
      'device': 'android',
      'isQueryInvitationBrand': 'true',
    };
    Map<String, dynamic> response;
    if (accountAvailable) {
      try {
        response = await request(
          'GET',
          mobile,
          '/fmobile-album/album/track/ts-${DateTime.now().millisecondsSinceEpoch}',
          query: query,
        );
      } on XmlyException catch (error) {
        if (error.code != 'login_expired') rethrow;
        response = await request(
          'GET',
          mobile,
          '/mobile/v1/album/track/v2',
          query: query,
          account: false,
        );
      }
    } else {
      response = await request(
        'GET',
        mobile,
        '/mobile/v1/album/track/v2',
        query: query,
        account: false,
      );
    }
    return _readAlbumPage(
      response,
      number,
      page: page,
      pageSize: pageSize,
      ascending: ascending,
    );
  }

  Future<AlbumPage> _readAlbumPage(
    Map<String, dynamic> response,
    String number, {
    required int page,
    required int pageSize,
    required bool ascending,
    bool cached = false,
  }) async {
    if (response['data'] is! Map)
      throw const XmlyException('invalid_catalogue', '专辑列表无效');
    final data = xmlyMap(response['data']);
    final total = _total(cached ? data['totalCount'] : data['totalCount'] ?? 0);
    if (cached) {
      if ('${response['ret']}' != '0' || _total(data['pageId']) != 1)
        throw const XmlyException('invalid_catalogue', '历史目录分页无效');
      pageSize = _total(data['pageSize']);
      final maxPage = _total(data['maxPageId']);
      if (pageSize < 1 ||
          pageSize > 100000 ||
          total > 5000 ||
          (total > 0
              ? maxPage != (total + pageSize - 1) ~/ pageSize
              : maxPage > 1)) {
        throw const XmlyException('invalid_catalogue', '历史目录分页无效');
      }
    } else if ((data.containsKey('pageId') && _total(data['pageId']) != page) ||
        (data.containsKey('pageSize') &&
            _total(data['pageSize']) != pageSize)) {
      throw const XmlyException('invalid_catalogue', '专辑分页无效');
    }
    if (data['list'] is! List ||
        (data['list'] as List).length > pageSize ||
        (cached &&
            ((data['list'] as List).length > total ||
                (total > 0 && (data['list'] as List).isEmpty)))) {
      throw const XmlyException('invalid_catalogue', '专辑列表无效');
    }
    final albumData = xmlyMap(response['album']);
    for (final key in ['albumId', 'id']) {
      if (albumData[key] != null &&
          xmlyIdentifier('${albumData[key]}') != number)
        throw const XmlyException('id_mismatch', '专辑信息不匹配');
    }
    var album = Album.fromApi({
      ...?_albums[number]?.raw,
      ...albumData,
      'albumId': number,
      'tracks': total,
      'totalCount': total,
      'total': total,
    });
    if (album.title.isEmpty && (data['list'] as List).isNotEmpty) {
      final first = xmlyMap((data['list'] as List).first);
      final title = first['albumTitle'] ?? first['album_title'];
      if (title is String && title.isNotEmpty)
        album = Album.fromApi({...album.raw, 'title': title});
    }
    if (!cached &&
        album.title.isEmpty &&
        !_albums.containsKey(number) &&
        (data['list'] as List).isNotEmpty) {
      final first = xmlyMap((data['list'] as List).first);
      final firstId = xmlyIdentifier(
        '${first['trackId'] ?? first['id'] ?? ''}',
      );
      final info = await _info(firstId);
      _matchingId(info, firstId);
      final firstTrack = Track.fromApi(info);
      if (firstTrack.albumId.isNotEmpty && firstTrack.albumId != number)
        throw const XmlyException('id_mismatch', '专辑与声音信息不匹配');
      album = Album(
        id: number,
        title: firstTrack.album,
        artist: album.artist.isEmpty ? firstTrack.artist : album.artist,
        intro: album.intro,
        coverUrl: album.coverUrl ?? firstTrack.coverUrl,
        total: total,
        raw: {
          ...album.raw,
          'title': firstTrack.album,
          'nickname': album.artist.isEmpty ? firstTrack.artist : album.artist,
          'cover_url': (album.coverUrl ?? firstTrack.coverUrl)?.toString(),
        },
      );
    }
    final tracks = <Track>[];
    final identifiers = <String>{};
    for (final raw in data['list'] as List) {
      if (raw is! Map)
        throw const XmlyException('invalid_catalogue', '专辑声音信息无效');
      if (cached && raw['albumId'] == null && raw['album_id'] == null)
        throw const XmlyException('invalid_catalogue', '历史目录缺少专辑信息');
      for (final key in ['albumId', 'album_id']) {
        if (raw[key] != null && xmlyIdentifier('${raw[key]}') != number)
          throw const XmlyException('id_mismatch', '专辑包含其他专辑的声音');
      }
      final position = (page - 1) * pageSize + tracks.length + 1;
      final value = Track.fromApi(
        xmlyMap(raw),
        album: album,
        position: ascending
            ? position
            : (total > 0 ? total - position + 1 : null),
      );
      if (!identifiers.add(value.id))
        throw const XmlyException('duplicate_page', '专辑声音重复，请刷新重试');
      tracks.add(value);
    }
    _albums[number] = album;
    while (_albums.length > 512) {
      _albums.remove(_albums.keys.first);
    }
    // Cached flags are metadata, never authority for track()/resolve().
    if (!cached) {
      for (final value in tracks) {
        _remember(value);
      }
    }
    return AlbumPage(
      album: album,
      tracks: tracks,
      page: page,
      pageSize: pageSize,
      total: total,
    );
  }

  Future<Quota> _activity(String name, [int? seconds]) async {
    final value = _requireAccount();
    final params = <String, String>{
      'deviceId': value.deviceId,
      'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
      'uid': value.uid,
      if (seconds != null) 'duration': '$seconds',
    };
    final signature = XmlyCrypto.activitySignature(params);
    params.remove('uid');
    params['signature'] = signature;
    final result = await request(
      'POST',
      mobile,
      '/lite-mobile/audi/func/v1/$name',
      data: params,
    );
    final data = xmlyMap(result['data']);
    String decode(String field) {
      try {
        if (data[field] is! String) throw const FormatException();
        final plaintext = XmlyCrypto.decrypt(
          data[field] as String,
          XmlyCrypto.durationKey,
        );
        final divider = plaintext.lastIndexOf('|');
        if (divider < 0) throw const FormatException();
        final stamp = int.parse(plaintext.substring(divider + 1));
        if ((DateTime.now().millisecondsSinceEpoch - stamp).abs() >= 180000)
          throw const FormatException();
        return plaintext.substring(0, divider);
      } catch (_) {
        throw const XmlyException('invalid_quota', '听时信息缺失或已过期');
      }
    }

    var newDevice = _quota?.newDevice ?? false;
    if (name == 'config') {
      final flag = decode('newDevice');
      if (!['true', 'false'].contains(flag))
        throw const XmlyException('invalid_quota', '设备授权信息无效');
      newDevice = flag == 'true';
    }
    final remaining = newDevice && !data.containsKey('availableListenDuration')
        ? 0
        : int.tryParse(decode('availableListenDuration'));
    if (remaining == null || remaining < 0)
      throw const XmlyException('invalid_quota', '听时余额无效');
    return _quota = Quota(
      remainingSeconds: remaining,
      newDevice: newDevice,
      checkedAt: DateTime.now(),
    );
  }

  Future<Quota> queryQuota() => _activity('config');
  Future<Quota> debitSeconds(int seconds) {
    if (seconds < 1 || seconds > 2147483647)
      throw const XmlyException(
        'invalid_duration',
        '听时必须为正整数秒',
        definitive: true,
      );
    return _activity('report', seconds);
  }

  Future<Map<String, dynamic>> _info(String number, [Quota? reward]) async {
    if (accountAvailable) {
      final params = <String, dynamic>{'device': 'android', 'trackId': number};
      if (reward != null)
        params.addAll({
          'a1': reward.newDevice ? '1' : '${reward.remainingSeconds}',
          'a2': '${DateTime.now().millisecondsSinceEpoch}',
          'a3': '0',
        });
      Map<String, dynamic> result;
      try {
        result = await request(
          'POST',
          mobile,
          '/fmobile-track/fmobile/track/v2/baseInfo',
          data: {'data': XmlyCrypto.encrypt(params, XmlyCrypto.playKey)},
          signed: true,
        );
      } on XmlyException catch (error) {
        if (error.code != 'login_expired' || reward != null) rethrow;
        return request(
          'GET',
          mobile,
          '/mobile/track/$number',
          account: false,
          query: {'device': 'android'},
        );
      }
      try {
        final decoded = jsonDecode(
          XmlyCrypto.decrypt(result['data'] as String, XmlyCrypto.playKey),
        );
        var info = decoded is Map ? decoded['trackInfo'] : null;
        if (info is String) info = jsonDecode(info);
        if (info is! Map) throw const FormatException();
        return xmlyMap(info);
      } catch (_) {
        throw const XmlyException('invalid_authorization', '授权声音信息无效');
      }
    }
    return request(
      'GET',
      mobile,
      '/mobile/track/$number',
      account: false,
      query: {'device': 'android'},
    );
  }

  static void _matchingId(Map<String, dynamic> info, String number) {
    if ('${info['trackId'] ?? info['id'] ?? ''}' != number)
      throw const XmlyException(
        'id_mismatch',
        '返回的声音 ID 不匹配',
        definitive: true,
      );
  }

  Future<Track> track(String trackId) async {
    final number = xmlyIdentifier(trackId);
    final cached = _metadata[number];
    if (cached != null) return cached;
    final info = await _info(number);
    _matchingId(info, number);
    final value = Track.fromApi(info);
    _remember(value);
    return value;
  }

  static final _mediaRedirectPath = RegExp(
    r'^/mobile/redirect/free/play/[1-9][0-9]{0,18}(?:/[01])?$',
  );
  static Uri mediaUri(Object? value) {
    if (value is! String ||
        value.length > 16384 ||
        RegExp(r'[\x00-\x1f]').hasMatch(value))
      throw const XmlyException('invalid_media', '音频地址无效');
    try {
      final uri = Uri.parse(value);
      final host = uri.host.toLowerCase();
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          (uri.port != 80 && uri.port != 443))
        throw const FormatException();
      if (host == 'xmcdn.com' || host.endsWith('.xmcdn.com')) return uri;
      // The observed official media gateway has no query and must use HTTPS's default port.
      if (host == 'mobile.ximalaya.com' &&
          !uri.hasQuery &&
          _mediaRedirectPath.hasMatch(uri.path)) {
        return uri.replace(scheme: 'https', port: 443);
      }
      throw const FormatException();
    } on FormatException {
      throw const XmlyException('invalid_media', '不受支持的音频来源', definitive: true);
    }
  }

  static String _urlKey(String number, String quality) => '$number:$quality';

  /// Attach only after a credential transaction commits. Failed candidates must
  /// never load, write or revoke another mounted client's namespace.
  void attachUrlCache(String directory) {
    if (_closed || _expired || _urlCachePath != null) return;
    _urlCachePath = p.join(
      p.normalize(p.absolute(directory)),
      'urls.$cacheIdentity',
    );
    _urlCacheReady = _queueUrlCache(() async {
      try {
        await _loadUrlCache();
      } finally {
        _urlCacheLoaded = true;
        _urlLoadInvalidations.clear();
      }
    });
    if (_discardUrlCacheLoad || _urlLoadInvalidations.isNotEmpty) {
      _saveUrlCache(revoke: true);
    } else if (_urls.values.any((entry) => entry.verified)) {
      _saveUrlCache();
    }
  }

  Future<void> _queueUrlCache(Future<void> Function() operation) {
    return _urlCacheWork = _urlCacheWork.then((_) async {
      try {
        await operation();
      } catch (_) {
        // Signed URLs are regenerable. Cache I/O must not damage app state or
        // turn an authorized download into a failed payment/playback operation.
      }
    });
  }

  /// Await pending local reads/writes before handing off a namespace or its lock.
  Future<void> flushUrlCache() => _urlCacheWork;

  /// Explicit revocation, unlike close(). Safe to await after closing the client.
  Future<void> clearUrlCache() {
    _invalidateUrls(null);
    return flushUrlCache();
  }

  File _urlCacheFile(int slot) => File('$_urlCachePath.$slot.json');

  Future<void> _loadUrlCache() async {
    Map<String, _CachedAudioUrl>? latest;
    var revision = 0;
    final now = DateTime.now();
    for (var slot = 0; slot < 2; slot++) {
      try {
        final file = _urlCacheFile(slot);
        if (!await file.exists() || await file.length() > _maxUrlCacheFile)
          continue;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in file.openRead(0, _maxUrlCacheFile + 1)) {
          bytes.add(chunk);
        }
        if (bytes.length > _maxUrlCacheFile) continue;
        final value = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (value is! Map<String, dynamic> ||
            value['version'] != 1 ||
            value['namespace'] != cacheIdentity ||
            value['revision'] is! int ||
            (value['revision'] as int) < 0 ||
            value['entries'] is! List ||
            (value['entries'] as List).length > 512)
          continue;
        final entries = <String, _CachedAudioUrl>{};
        final seen = <String>{};
        for (final row in value['entries'] as List) {
          if (row is! Map ||
              row['track'] is! String ||
              row['quality'] is! String ||
              !_qualities.contains(row['quality']) ||
              !row.containsKey('deadline')) {
            throw const FormatException();
          }
          final number = xmlyIdentifier(row['track'] as String);
          if (number != row['track']) throw const FormatException();
          final quality = row['quality'] as String;
          final key = _urlKey(number, quality);
          if (!seen.add(key)) throw const FormatException();
          final uri = mediaUri(row['uri']);
          final expiry = row['deadline'];
          if (expiry != null &&
              (expiry is! int || expiry < 0 || expiry > 8640000000000000)) {
            throw const FormatException();
          }
          final deadline = _urlDeadline(
            uri,
            expiry == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(expiry as int),
          );
          Track? authorizedTrack;
          bool? requiresReward;
          if (row['authorizedTrack'] is Map && row['requiresReward'] is bool) {
            authorizedTrack = Track.fromJson(xmlyMap(row['authorizedTrack']));
            if (authorizedTrack.number != number) throw const FormatException();
            requiresReward = row['requiresReward'] as bool;
          }
          if (deadline == null || deadline.isAfter(now)) {
            entries[key] = _CachedAudioUrl(
              number,
              quality,
              uri,
              deadline,
              verified: true,
              authorizedTrack: authorizedTrack,
              requiresReward: requiresReward,
            );
          }
        }
        if (latest == null || (value['revision'] as int) > revision) {
          latest = entries;
          revision = value['revision'] as int;
        }
      } catch (_) {
        /* Ignore either corrupt/unreadable slot independently. */
      }
    }
    _urlCacheRevision = revision;
    if (_closed || _expired || _discardUrlCacheLoad || latest == null) return;
    for (final entry in latest.entries) {
      // Track/lease invalidations issued while this read was pending win over
      // disk. Unrelated tracks survive a concurrent force refresh.
      if (!_urlLoadInvalidations.contains(entry.key))
        _urls.putIfAbsent(entry.key, () => entry.value);
    }
    while (_urls.length > 512) {
      _urls.remove(_urls.keys.first);
    }
  }

  void _saveUrlCache({bool revoke = false}) {
    if (_urlCachePath == null) return;
    unawaited(
      _queueUrlCache(() async {
        var removed = true;
        if (revoke) {
          // Both generations must lose revoked leases; otherwise a corrupt newest
          // slot could resurrect one from the previous generation on restart.
          for (var slot = 0; slot < 2; slot++) {
            for (final file in [
              _urlCacheFile(slot),
              File('${_urlCacheFile(slot).path}.tmp'),
            ]) {
              try {
                if (await file.exists()) await file.delete();
              } catch (_) {
                removed = false;
              }
            }
          }
        }
        if (revoke && removed && _urls.values.every((entry) => !entry.verified))
          return;
        // On failed deletion, empty/clean generations are also best-effort
        // tombstones. Nothing here is an entitlement or part of the usage ledger.
        for (var count = 0; count < (revoke ? 2 : 1); count++) {
          try {
            await _writeUrlCache();
          } catch (_) {
            /* Keep the last readable slot. */
          }
        }
      }),
    );
  }

  Future<void> _writeUrlCache() async {
    final revision = _urlCacheRevision + 1;
    final now = DateTime.now();
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'namespace': cacheIdentity,
        'revision': revision,
        'entries': [
          for (final entry in _urls.values)
            if (entry.verified &&
                (entry.deadline == null || entry.deadline!.isAfter(now)))
              {
                'track': entry.number,
                'quality': entry.quality,
                'uri': entry.uri.toString(),
                'deadline': entry.deadline?.millisecondsSinceEpoch,
                if (entry.authorizedTrack != null &&
                    entry.requiresReward != null)
                  'authorizedTrack': entry.authorizedTrack!.toJson(),
                if (entry.authorizedTrack != null &&
                    entry.requiresReward != null)
                  'requiresReward': entry.requiresReward,
              },
        ],
      }),
    );
    if (bytes.length > _maxUrlCacheFile) return;
    final target = _urlCacheFile(revision % 2);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    _urlCacheRevision = revision;
  }

  static DateTime? _urlDeadline(Uri uri, [DateTime? deadline]) {
    for (final entry in uri.queryParametersAll.entries) {
      if (![
        'expires',
        'expire',
        'expiration',
        'deadline',
        'e',
      ].contains(entry.key.toLowerCase()))
        continue;
      for (final value in entry.value) {
        var expires = double.tryParse(value);
        if (expires == null || !expires.isFinite) continue;
        if (expires > 1000000000000) expires /= 1000;
        if (expires > 1000000000) {
          final expiry = DateTime.fromMillisecondsSinceEpoch(
            min(expires * 1000 - 5000, 8640000000000000).toInt(),
          );
          if (deadline == null || expiry.isBefore(deadline)) deadline = expiry;
        }
      }
    }
    return deadline;
  }

  Future<ResolvedAudio> resolve(
    String trackId, {
    bool force = false,
    bool preferCached = false,
    String? quality,
  }) => _resolveLock.synchronized(() async {
    if (_closed)
      throw const XmlyException('client_closed', '连接已关闭', definitive: true);
    final requestedQuality = quality ?? this.quality;
    if (requestedQuality != 'auto' && !_qualities.contains(requestedQuality)) {
      throw const XmlyException('invalid_quality', '音质设置无效', definitive: true);
    }
    final number = xmlyIdentifier(trackId);
    if (force) invalidate(number);
    final epoch = _urlEpoch;
    await _urlCacheReady;
    if (_closed)
      throw const XmlyException('client_closed', '连接已关闭', definitive: true);
    if (preferCached &&
        !force &&
        !_expired &&
        (credentials == null || accountAvailable) &&
        epoch == _urlEpoch) {
      for (final candidateQuality
          in requestedQuality == 'auto' ? _qualities : [requestedQuality]) {
        final key = _urlKey(number, candidateQuality);
        final entry = _urls[key];
        if (entry == null ||
            !entry.verified ||
            entry.authorizedTrack == null ||
            entry.requiresReward == null ||
            (entry.deadline != null &&
                !entry.deadline!.isAfter(DateTime.now())))
          continue;
        final track = entry.authorizedTrack!;
        if ((credentials == null && entry.requiresReward!) ||
            (!entry.requiresReward! &&
                track.isPaid != false &&
                track.isAuthorized != true))
          continue;
        if (entry.requiresReward!) {
          _requireAccount();
          final quota = await queryQuota();
          if (!quota.newDevice && quota.remainingSeconds <= 0)
            throw const XmlyException(
              'insufficient_quota',
              '听时不足，请前往官方 App 获取听时',
              definitive: true,
            );
        }
        // Revocation/expiry while awaiting quota must win over this lease.
        if (_closed ||
            _expired ||
            (credentials != null && !accountAvailable) ||
            epoch != _urlEpoch ||
            !identical(_urls[key], entry) ||
            (entry.deadline != null &&
                !entry.deadline!.isAfter(DateTime.now())))
          break;
        _remember(track);
        return await _resolvedAudio(entry, track, entry.requiresReward!);
      }
    }
    var info = await _info(number);
    _matchingId(info, number);
    Quota? reward;
    if ((info['isPaid'] ?? info['is_paid']) != false &&
        info['isAuthorized'] != true) {
      _requireAccount();
      reward = await queryQuota();
      if (!reward.newDevice && reward.remainingSeconds <= 0)
        throw const XmlyException(
          'insufficient_quota',
          '听时不足，请前往官方 App 获取听时',
          definitive: true,
        );
      info = await _info(number, reward);
      _matchingId(info, number);
    }
    if (info['isPreview'] == true || info['isTrial'] == true)
      throw const XmlyException(
        'preview_only',
        '仅获得试听音频，不能下载完整声音',
        definitive: true,
      );
    final candidates = <String, Uri>{};
    void add(String type, Object? value, {bool encrypted = false}) {
      if (value is! String || value.isEmpty || candidates.containsKey(type))
        return;
      final decoded =
          encrypted &&
              !value.startsWith('https://') &&
              !value.startsWith('http://')
          ? XmlyCrypto.decrypt(value, XmlyCrypto.playKey)
          : value;
      candidates[type] = mediaUri(decoded);
    }

    add('mp3_64', info['playUrl64']);
    add('mp3_32', info['playUrl32']);
    if (credentials != null) {
      Object? urls = info['playUrlList'];
      if (urls is String) {
        try {
          urls = jsonDecode(urls);
        } catch (_) {
          throw const XmlyException('invalid_media', '音频列表格式无效');
        }
      }
      if (urls != null && urls is! List)
        throw const XmlyException('invalid_media', '音频列表格式无效');
      if (urls is List) {
        for (final item in urls) {
          if (item is Map &&
              item['type'] is String &&
              _qualities.contains((item['type'] as String).toLowerCase()))
            add(
              (item['type'] as String).toLowerCase(),
              item['url'],
              encrypted: true,
            );
        }
      }
    }
    if (candidates.isEmpty)
      throw const XmlyException(
        'permission_denied',
        '当前没有获得完整音频地址，请检查听时与版权权限',
        definitive: true,
      );
    final chosen =
        requestedQuality != 'auto' && candidates.containsKey(requestedQuality)
        ? requestedQuality
        : _qualities.firstWhere(candidates.containsKey);
    final uri = candidates[chosen]!;
    final now = DateTime.now();
    final key = _urlKey(number, chosen);
    final cached = _urls[key];
    final entry =
        cached != null &&
            (cached.deadline == null || cached.deadline!.isAfter(now))
        ? cached
        : _CachedAudioUrl(number, chosen, uri, _urlDeadline(uri));
    // An invalidation during authorization must not repopulate the session cache.
    if (!_closed &&
        !_expired &&
        epoch == _urlEpoch &&
        !identical(cached, entry)) {
      _urls[key] = entry;
      var evictedVerified = false;
      while (_urls.length > 512) {
        evictedVerified =
            _urls.remove(_urls.keys.first)!.verified || evictedVerified;
      }
      if (evictedVerified) _saveUrlCache();
    }
    final track = Track.fromApi(info);
    _remember(track);
    if (!_closed &&
        !_expired &&
        epoch == _urlEpoch &&
        identical(_urls[key], entry)) {
      entry.authorizedTrack = track;
      entry.requiresReward = reward != null;
      if (entry.verified) _saveUrlCache();
    }
    return await _resolvedAudio(entry, track, reward != null);
  });

  Future<ResolvedAudio> _resolvedAudio(
    _CachedAudioUrl entry,
    Track track,
    bool requiresReward,
  ) async {
    final key = _urlKey(entry.number, entry.quality);
    final audio = ResolvedAudio(
      uri: entry.uri,
      expiresAt: entry.deadline,
      requiresReward: requiresReward,
      track: track,
      actualQuality: entry.quality,
      accountIdentity: identity,
      cacheFinalUri: (finalUri) {
        final validated = mediaUri(finalUri.toString());
        final deadline = _urlDeadline(validated, entry.deadline);
        if (!_closed && !_expired && identical(_urls[key], entry)) {
          if (deadline != null && !deadline.isAfter(DateTime.now())) {
            _invalidateLease(key, entry);
          } else if (!entry.verified ||
              entry.uri != validated ||
              entry.deadline != deadline) {
            entry.uri = validated;
            entry.deadline = deadline;
            entry.verified = true;
            _saveUrlCache();
          }
        }
        return deadline;
      },
      invalidateCachedUri: () {
        _invalidateLease(key, entry);
      },
    );
    final host = audio.uri.host.toLowerCase();
    if (!host.startsWith('audiopay') || !host.endsWith('.xmcdn.com'))
      return audio;
    var uri = audio.uri;
    final epoch = _urlEpoch;
    for (var redirects = 0; ; redirects++) {
      final cancel = CancelToken();
      final diagnostic = RequestDiagnostic(
        account: identity,
        method: 'GET',
        url: uri.toString(),
      );
      try {
        final next = await Future.any<Uri?>([
          (() async {
            uri = mediaUri(uri.toString());
            final options = Options(
              method: 'GET',
              headers: const {
                'User-Agent': 'XMPlus/1.0',
                'Accept': 'audio/*, application/octet-stream',
                'Accept-Encoding': 'identity',
                'Range': 'bytes=0-11',
              },
              responseType: ResponseType.stream,
              followRedirects: false,
              maxRedirects: 0,
              validateStatus: (_) => true,
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
            ).compose(_dio.options, uri.toString(), cancelToken: cancel);
            // Never reuse API cookies, tickets, or caller-supplied media headers.
            diagnostic.requestHeaders = options.headers;
            final response = await _dio.fetch<ResponseBody>(options);
            final status = response.statusCode ?? 0;
            diagnostic.status = status;
            diagnostic.responseHeaders = response.headers.map;
            diagnostic.completeness = '仅探测音频前缀，未下载完整响应体';
            if ([301, 302, 303, 307, 308].contains(status)) {
              final location = response.headers.value('location');
              if (location == null || location.isEmpty || redirects >= 5)
                throw const XmlyException('invalid_media', '音频重定向过多或无效');
              try {
                return mediaUri(uri.resolve(location).toString());
              } on FormatException {
                throw const XmlyException('invalid_media', '音频重定向地址无效');
              }
            }
            final bytes = BytesBuilder(copy: false);
            diagnostic.responseByteCount = () => bytes.length;
            final successful = status == 200 || status == 206;
            final limit = successful ? 12 : 4096;
            final body = response.data;
            if (body != null) {
              await for (final chunk in body.stream) {
                final count = min(chunk.length, limit - bytes.length);
                if (count > 0)
                  bytes.add(Uint8List.sublistView(chunk, 0, count));
                if (bytes.length == limit) break;
              }
            }
            if (!successful)
              throw XmlyException(
                'media_http',
                status == 401 || status == 403
                    ? '音频授权已失效，请重新获取'
                    : '音频请求返回 HTTP $status',
              );
            final type = (response.headers.value('content-type') ?? '')
                .split(';')
                .first
                .trim()
                .toLowerCase();
            if (!(type.startsWith('audio/') ||
                type.startsWith('video/') ||
                type == 'application/octet-stream' ||
                type == 'binary/octet-stream' ||
                type == 'application/ogg' ||
                type.isEmpty))
              throw const XmlyException('invalid_media', '响应不是音频，未缓存错误页面');
            final prefix = bytes.takeBytes();
            diagnostic.responseByteCount = () => prefix.length;
            bool text(int offset, String value) {
              if (prefix.length < offset + value.length) return false;
              for (var i = 0; i < value.length; i++) {
                if (prefix[offset + i] != value.codeUnitAt(i)) return false;
              }
              return true;
            }

            if (!(text(0, 'ID3') ||
                text(0, 'fLaC') ||
                text(0, 'OggS') ||
                (text(0, 'RIFF') && text(8, 'WAVE')) ||
                text(4, 'ftyp') ||
                (prefix.length >= 4 &&
                    prefix[0] == 0xff &&
                    (((prefix[1] & 0xe0) == 0xe0 &&
                            (prefix[1] & 0x06) != 0 &&
                            (prefix[2] & 0xf0) != 0xf0 &&
                            (prefix[2] & 0xf0) != 0 &&
                            (prefix[2] & 0x0c) != 0x0c) ||
                        ((prefix[1] & 0xf6) == 0xf0 &&
                            (prefix[2] & 0x3c) != 0x3c)))))
              throw const XmlyException('invalid_media', '响应不是可识别的音频，未缓存错误页面');
            if (status == 206 &&
                !RegExp(r'^bytes 0-[0-9]+/(?:[0-9]+|\*)$')
                    .hasMatch(response.headers.value('content-range') ?? ''))
              throw const XmlyException('invalid_media', '音频范围响应无效');
            return null;
          })(),
          _closeSignal.future.then<Uri?>((_) {
            throw const XmlyException(
              'client_closed',
              '连接已关闭',
              definitive: true,
            );
          }),
        ]).timeout(const Duration(seconds: 25));
        if (_closed)
          throw const XmlyException('client_closed', '连接已关闭', definitive: true);
        if (_expired || epoch != _urlEpoch || !identical(_urls[key], entry))
          throw const XmlyException('cache_source_changed', '音频来源已变化，请重新获取');
        if (next != null) {
          uri = next;
          continue;
        }
        audio.rememberFinalUri(uri);
        return audio;
      } catch (error) {
        cancel.cancel();
        _invalidateLease(key, entry);
        if (error is! XmlyException) diagnostic.transportError = '$error';
        await diagnostic.fail(error);
        if (error is XmlyException) rethrow;
        throw const XmlyException('network', '音频地址请求失败或超时');
      } finally {
        // Dio's stream wrapper must also cancel its underlying HTTP response.
        cancel.cancel();
      }
    }
  }

  void _invalidateLease(String key, _CachedAudioUrl entry) {
    if (_closed || !identical(_urls[key], entry)) return;
    _urlEpoch++;
    _urls.remove(key);
    if (!_urlCacheLoaded) _urlLoadInvalidations.add(key);
    _saveUrlCache(revoke: true);
  }

  void _invalidateUrls(String? number) {
    _urlEpoch++;
    if (number == null) {
      _urls.clear();
      _discardUrlCacheLoad = true;
      _urlLoadInvalidations.clear();
    } else {
      _urls.removeWhere((_, entry) => entry.number == number);
      if (!_urlCacheLoaded) {
        for (final quality in _qualities) {
          _urlLoadInvalidations.add(_urlKey(number, quality));
        }
      }
    }
    _saveUrlCache(revoke: true);
  }

  void invalidate([String? trackId]) {
    if (_closed) return;
    _invalidateUrls(
      trackId == null || trackId.isEmpty ? null : xmlyIdentifier(trackId),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closeSignal.isCompleted) _closeSignal.complete();
    _urlEpoch++;
    _dio.close(force: true);
    _metadata.clear();
    _albums.clear();
    // Keep the last validated leases for queued writes; callers drain before
    // releasing AppStorage's lock. Old callbacks cannot write after close.
  }
}

class _CachedAudioUrl {
  Uri uri;
  DateTime? deadline;
  final String number, quality;
  bool verified;
  Track? authorizedTrack;
  bool? requiresReward;
  _CachedAudioUrl(
    this.number,
    this.quality,
    this.uri,
    this.deadline, {
    this.verified = false,
    this.authorizedTrack,
    this.requiresReward,
  });
}

class _RetryableStatus implements Exception {}
