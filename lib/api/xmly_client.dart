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
import '../services/network_retry.dart';
import '../services/request_diagnostics.dart';
import 'xmly_crypto.dart';

class XmlyClient {
  static final Map<String, _BalanceChanges> _balanceChanges = {};
  static final _readPolicyKey = Object();
  static const mobile = 'https://mobile.ximalaya.com';
  static const cachedAlbumOrigin = 'https://mobwsa.ximalaya.com';
  static const searchOrigin = 'https://www.ximalaya.com';
  static const collector = 'https://xdcs-collector.ximalaya.com';
  static const welfare = 'https://m.ximalaya.com';
  static const paidOrigin = 'https://mpaywsa.ximalaya.com';
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

  /// Serializes balance mutations for one account/device, including clients
  /// using refreshed credentials. Callers acquire account/ledger locks first.
  Future<T> withBalanceChange<T>(Future<T> Function() action) async {
    final key = _requireAccount().identity;
    final changes = _balanceChanges.putIfAbsent(key, _BalanceChanges.new);
    changes.users++;
    try {
      return await changes.lock.synchronized(action);
    } finally {
      if (--changes.users == 0) _balanceChanges.remove(key);
    }
  }

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
    if (origin == paidOrigin)
      return method == 'GET' &&
          RegExp(r'^/mobile/track/pay/[1-9][0-9]{0,18}/ts-[0-9]+$')
              .hasMatch(path);
    if (origin == searchOrigin)
      return method == 'GET' &&
          const {
            '/revision/search',
            '/revision/track/simple',
            '/revision/comment/queryComments',
            '/revision/comment/queryReplies',
          }.contains(path);
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
        '/lite-mobile/like/v1/like',
        '/lite-mobile/like/v1/dislike',
        '/subscribe/album/subscribe/delete',
        '/subscribe/album-subscribe/and/ask-anchor-info',
      ].contains(path);
    return method == 'GET' &&
        (const [
              '/mobile/v1/album/track/v2',
              '/nyx/v1/history/query/android',
              '/lite-mobile/like/v1/user-likes',
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

  static Duration _retryAfter(String? value) =>
      serverRetryAfter(value) ?? const Duration(seconds: 30);

  Never _rateLimit(String origin, Duration delay) {
    _cooldowns[origin] = DateTime.fromMillisecondsSinceEpoch(
      min(
        DateTime.now().millisecondsSinceEpoch + delay.inMilliseconds,
        8640000000000000,
      ),
    );
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

  /// Retry/cancellation belongs to this operation, not the shared account client.
  /// Only semantically read-only requests inherit it; writes are never replayed.
  Future<T> withReadPolicy<T>(
    Future<T> Function() action, {
    required int rateLimitRetries,
    Duration minimumRateLimitDelay = Duration.zero,
    Future<void>? cancelled,
    Future<void> Function()? checkpoint,
  }) {
    if (rateLimitRetries < 0 ||
        rateLimitRetries > 1000 ||
        minimumRateLimitDelay.isNegative) {
      throw const XmlyException('invalid_retry', '限流重试设置无效');
    }
    return runZoned(
      action,
      zoneValues: {
        _readPolicyKey: _ReadPolicy(
          rateLimitRetries,
          minimumRateLimitDelay,
          cancelled,
          checkpoint,
        ),
      },
    );
  }

  Future<void> _checkRead(_ReadPolicy? policy) async {
    await policy?.checkpoint?.call();
    if (_closed) {
      throw const XmlyException('client_closed', '连接已关闭', definitive: true);
    }
    if (policy?.stopped == true) {
      throw const XmlyException('request_cancelled', '请求已停止', definitive: true);
    }
  }

  Future<T> _readAttempt<T>(
    Future<T> action,
    CancelToken cancel,
    _ReadPolicy? policy,
  ) async {
    try {
      final result = await Future.any<T>([
        action,
        _closeSignal.future.then<T>((_) {
          cancel.cancel();
          throw const XmlyException('client_closed', '连接已关闭', definitive: true);
        }),
        if (policy?.cancelled != null)
          policy!.cancelled!.then<T>((_) async {
            cancel.cancel();
            await _checkRead(policy);
            throw const XmlyException(
              'request_cancelled',
              '请求已停止',
              definitive: true,
            );
          }),
      ]);
      await _checkRead(policy);
      return result;
    } finally {
      cancel.cancel();
    }
  }

  Future<void> _retryWait(Duration delay, [_ReadPolicy? policy]) async {
    await _checkRead(policy);
    try {
      await waitToRetry(
        delay,
        closed: Future.any<void>([
          _closeSignal.future,
          if (policy?.cancelled != null) policy!.cancelled!,
        ]),
        checkpoint: () => _checkRead(policy),
      );
    } catch (_) {
      // Preserve the caller's typed stop exception rather than leaking the
      // shared wait helper's generic close error into a paused download.
      await _checkRead(policy);
      rethrow;
    }
    await _checkRead(policy);
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
            ].contains(path));
    final policy = readOnly
        ? Zone.current[_readPolicyKey] as _ReadPolicy?
        : null;
    var failures = 0, rateRetries = 0;
    while (true) {
      await _checkRead(policy);
      Duration? rateDelay;
      final until = _cooldowns[origin];
      if (until != null && until.isAfter(DateTime.now())) {
        final delay = until.difference(DateTime.now());
        if (policy?.rateLimitRetries == 0) {
          throw XmlyException(
            'rate_limited',
            '请求过于频繁，请稍后重试',
            retryAfter: delay,
          );
        }
        await _retryWait(delay, policy);
      }
      await _checkRead(policy);
      final cancel = CancelToken();
      final diagnostic = RequestDiagnostic(
        account: identity,
        method: method,
        url: '$origin$path',
      );
      try {
        final action = _attempt(
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
        );
        final attempt = readOnly
            ? _readAttempt(action, cancel, policy)
            : action;
        return await attempt.timeout(
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
        if (!readOnly || failures++ >= 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '喜马拉雅服务暂时不可用' : '请求结果未知，请核对后重试',
          );
      } on DioException catch (error) {
        await _checkRead(policy);
        if (error.error case final XmlyException limit
            when limit.code == 'response_too_large')
          throw limit;
        if (cancel.cancelError?.error case final XmlyException limit
            when limit.code == 'response_too_large')
          throw limit;
        if (!readOnly || failures++ >= 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on TimeoutException {
        if (!readOnly || failures++ >= 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on IOException {
        if (!readOnly || failures++ >= 4)
          throw XmlyException(
            readOnly ? 'network' : 'uncertain',
            readOnly ? '请求失败或超时' : '请求结果未知，请核对后重试',
          );
      } on XmlyException catch (error) {
        if (!readOnly || error.code != 'rate_limited') rethrow;
        if (policy != null) {
          if (rateRetries++ >= policy.rateLimitRetries) rethrow;
          final server = error.retryAfter ?? Duration.zero;
          rateDelay = server > policy.minimumRateLimitDelay
              ? server
              : policy.minimumRateLimitDelay;
        } else if (failures++ >= 4) {
          rethrow;
        }
      }
      final backoff = Duration(seconds: 1 << max(0, min(failures - 1, 4)));
      final cooldown = _cooldowns[origin]?.difference(DateTime.now());
      var delay = cooldown != null && cooldown > backoff ? cooldown : backoff;
      if (rateDelay != null && rateDelay > delay) delay = rateDelay;
      await _retryWait(delay, policy);
    }
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
    diagnostic.responseBytes = bytes.toBytes;
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
      diagnostic.responseBytes = () => responseBytes;
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
    Map<String, dynamic>? authenticated;
    if (accountAvailable) {
      try {
        authenticated = await request(
          'GET',
          mobile,
          '/fmobile-album/album/track/ts-${DateTime.now().millisecondsSinceEpoch}',
          query: query,
        );
      } on XmlyException catch (error) {
        // Preserve the public fallback on expiry; only transport failures may
        // otherwise discard a source. Permissions, throttling and bad data fail.
        if (error.code != 'login_expired' && error.code != 'network') rethrow;
      }
    }
    Map<String, dynamic>? public;
    try {
      public = await request(
        'GET',
        mobile,
        '/mobile/v1/album/track/v2',
        query: query,
        account: false,
      );
    } on XmlyException catch (error) {
      if (error.code != 'network' || authenticated == null) rethrow;
    }
    final response = authenticated != null && public != null
        ? _mergeAlbumPages(
            authenticated,
            public,
            number,
            page,
            pageSize,
            ascending,
          )
        : authenticated ?? public!;
    return _readAlbumPage(
      response,
      number,
      page: page,
      pageSize: pageSize,
      ascending: ascending,
    );
  }

  static int? _albumOrder(Map<String, dynamic> raw) {
    int? order;
    for (final key in ['orderNo', 'orderNum', 'order_no']) {
      final value = xmlyPositive(raw[key]);
      if (value == null) continue;
      if (order != null && order != value)
        throw const XmlyException('invalid_catalogue', '专辑声音序号冲突');
      order = value;
    }
    return order;
  }

  static Map<String, dynamic> _albumMetadata(
    Map<String, dynamic> preferred,
    Map<String, dynamic> other,
  ) {
    bool present(Object? value) => value != null && value != '';
    final result = <String, dynamic>{
      ...other,
      for (final entry in preferred.entries)
        if (present(entry.value)) entry.key: entry.value,
    };
    // Normalize aliases so a public alias cannot shadow authenticated metadata.
    for (final keys in [
      ['album_id', 'albumId'],
      ['album_title', 'albumTitle'],
      ['is_paid', 'isPaid'],
      [
        'coverLarge',
        'coverMiddle',
        'coverSmall',
        'cover_path',
        'album_cover_path',
        'cover_url',
        'albumImage',
      ],
    ]) {
      for (final source in [preferred, other]) {
        final values = keys.map((key) => source[key]).where(present);
        if (values.isEmpty) continue;
        for (final key in keys) result[key] = values.first;
        break;
      }
    }
    final order = _albumOrder(preferred) ?? _albumOrder(other);
    if (order != null) {
      for (final key in ['orderNo', 'orderNum', 'order_no'])
        result[key] = order;
    }
    for (final source in [preferred, other]) {
      final names = [
        source['nickname'],
        xmlyMap(source['userInfo'])['nickname'],
      ].where(present);
      if (names.isEmpty) continue;
      result['nickname'] = names.first;
      break;
    }
    if (preferred['duration'] is! num || (preferred['duration'] as num) <= 0) {
      if (other['duration'] is num && (other['duration'] as num) > 0)
        result['duration'] = other['duration'];
    }
    return result;
  }

  Map<String, dynamic> _mergeAlbumPages(
    Map<String, dynamic> authenticated,
    Map<String, dynamic> public,
    String number,
    int page,
    int pageSize,
    bool ascending,
  ) {
    final sources = [
      _albumPageData(authenticated, number, page, pageSize, ascending),
      _albumPageData(public, number, page, pageSize, ascending),
    ];
    final total = _total(sources.first['totalCount'] ?? 0);
    if (_total(sources.last['totalCount'] ?? 0) != total)
      throw const XmlyException('catalogue_changed', '专辑总数不一致，请刷新重试');
    final items = <String, Map<String, dynamic>>{};
    final orders = <int, String>{};
    final successors = <String, Set<String>>{};
    final incoming = <String, int>{};
    void before(String left, String right) {
      if (successors[left]!.add(right)) incoming[right] = incoming[right]! + 1;
    }

    // Both relative orders constrain the result. Unlike officialPosition, real
    // server ordinals may also order disjoint runs between two common anchors.
    for (final source in sources) {
      String? previous;
      for (final raw in source['list'] as List) {
        final item = xmlyMap(raw);
        final id = xmlyIdentifier('${item['trackId'] ?? item['id']}');
        final existing = items[id];
        final order = _albumOrder(item);
        if (existing != null &&
            order != null &&
            _albumOrder(existing) != null &&
            _albumOrder(existing) != order)
          throw const XmlyException('invalid_catalogue', '专辑声音序号冲突');
        items[id] = existing == null ? item : _albumMetadata(existing, item);
        successors.putIfAbsent(id, () => <String>{});
        incoming.putIfAbsent(id, () => 0);
        if (order != null) {
          if (orders.containsKey(order) && orders[order] != id)
            throw const XmlyException('invalid_catalogue', '专辑声音序号重复');
          orders[order] = id;
        }
        if (previous != null) before(previous, id);
        previous = id;
      }
    }
    final ordinals = orders.keys.toList()..sort();
    if (!ascending) {
      for (var index = ordinals.length - 1; index > 0; index--)
        before(orders[ordinals[index]]!, orders[ordinals[index - 1]]!);
    } else {
      for (var index = 1; index < ordinals.length; index++)
        before(orders[ordinals[index - 1]]!, orders[ordinals[index]]!);
    }
    final ready = incoming.keys.where((id) => incoming[id] == 0).toSet();
    final merged = <Map<String, dynamic>>[];
    while (ready.isNotEmpty) {
      if (ready.length != 1)
        throw const XmlyException('invalid_catalogue', '专辑声音顺序不明确');
      final id = ready.single;
      ready.remove(id);
      merged.add(items[id]!);
      for (final next in successors[id]!) {
        incoming[next] = incoming[next]! - 1;
        if (incoming[next] == 0) ready.add(next);
      }
    }
    if (merged.length != items.length)
      throw const XmlyException('invalid_catalogue', '专辑声音顺序冲突');
    return {
      ...authenticated,
      'album': _albumMetadata(
        xmlyMap(authenticated['album']),
        xmlyMap(public['album']),
      ),
      'data': {...sources.first, 'list': merged},
    };
  }

  Map<String, dynamic> _albumPageData(
    Map<String, dynamic> response,
    String number,
    int page,
    int pageSize,
    bool ascending, {
    bool cached = false,
  }) {
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
              : maxPage > 1))
        throw const XmlyException('invalid_catalogue', '历史目录分页无效');
    } else if ((data.containsKey('pageId') && _total(data['pageId']) != page) ||
        (data.containsKey('pageSize') &&
            _total(data['pageSize']) != pageSize)) {
      throw const XmlyException('invalid_catalogue', '专辑分页无效');
    }
    if (data['list'] is! List ||
        (data['list'] as List).length > pageSize ||
        (data['list'] as List).length >
            (total - (page - 1) * pageSize).clamp(0, pageSize) ||
        (cached && total > 0 && (data['list'] as List).isEmpty))
      throw const XmlyException('invalid_catalogue', '专辑列表无效');
    for (final source in [xmlyMap(response['album']), data]) {
      for (final key in ['albumId', if (!identical(source, data)) 'id']) {
        if (source[key] != null && xmlyIdentifier('${source[key]}') != number)
          throw const XmlyException('id_mismatch', '专辑信息不匹配');
      }
    }
    final identifiers = <String>{};
    final orders = <int>{};
    int? previousOrder;
    for (final raw in data['list'] as List) {
      if (raw is! Map)
        throw const XmlyException('invalid_catalogue', '专辑声音信息无效');
      if (cached && raw['albumId'] == null && raw['album_id'] == null)
        throw const XmlyException('invalid_catalogue', '历史目录缺少专辑信息');
      for (final key in ['albumId', 'album_id']) {
        if (raw[key] != null && xmlyIdentifier('${raw[key]}') != number)
          throw const XmlyException('id_mismatch', '专辑包含其他专辑的声音');
      }
      final id = xmlyIdentifier('${raw['trackId'] ?? raw['id'] ?? ''}');
      if (!identifiers.add(id))
        throw const XmlyException('duplicate_page', '专辑声音重复，请刷新重试');
      final order = _albumOrder(xmlyMap(raw));
      if (order != null) {
        if (!orders.add(order) ||
            (previousOrder != null &&
                (ascending ? order <= previousOrder : order >= previousOrder)))
          throw const XmlyException('invalid_catalogue', '专辑声音序号冲突');
        previousOrder = order;
      }
    }
    return data;
  }

  Future<AlbumPage> _readAlbumPage(
    Map<String, dynamic> response,
    String number, {
    required int page,
    required int pageSize,
    required bool ascending,
    bool cached = false,
  }) async {
    final data = _albumPageData(
      response,
      number,
      page,
      pageSize,
      ascending,
      cached: cached,
    );
    final total = _total(cached ? data['totalCount'] : data['totalCount'] ?? 0);
    if (cached) {
      pageSize = _total(data['pageSize']);
    } else if ((data['list'] as List).length !=
        (total - (page - 1) * pageSize).clamp(0, pageSize)) {
      throw const XmlyException('incomplete_catalogue', '专辑分页不完整，请刷新重试');
    }
    final albumData = xmlyMap(response['album']);
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
    for (final raw in data['list'] as List) {
      final position = (page - 1) * pageSize + tracks.length + 1;
      final value = Track.fromApi(
        {...xmlyMap(raw), if (total > 0) 'totalCount': total},
        album: album,
        position: ascending
            ? position
            : (total > 0 ? total - position + 1 : null),
      );
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

  Track _withCatalogueMetadata(Track value) {
    final previous = _metadata[value.number];
    final sameAlbum =
        value.albumId.isNotEmpty && previous?.albumId == value.albumId;
    final total =
        xmlyPositive(value.raw['totalCount']) ??
        (sameAlbum ? xmlyPositive(previous!.raw['totalCount']) : null);
    final position =
        value.officialPosition ??
        (sameAlbum ? previous!.officialPosition : null);
    return Track.fromJson({
      ...value.toJson(),
      'raw': {
        ...value.raw,
        if (total != null) 'totalCount': total,
        if (position != null) 'officialPosition': position,
      },
    });
  }

  /// Official sound manuscript only, never the track's promotional introduction.
  /// Public web reads must not carry this client's mobile account credentials.
  Future<String?> fetchManuscript(String trackId) async {
    final number = xmlyIdentifier(trackId);
    final response = await request(
      'GET',
      searchOrigin,
      '/revision/track/simple',
      account: false,
      query: {'trackId': number},
    );
    final data = response['data'];
    final info = data is Map ? data['trackInfo'] : null;
    if (info is! Map) {
      throw const XmlyException('protocol', '文稿响应格式无效');
    }
    final track = xmlyMap(info);
    if (track.containsKey('trackId') || track.containsKey('id')) {
      _matchingId(track, number);
    }
    final lyric = track['lyric'], draft = track['draft'];
    if ((lyric != null && lyric is! String) ||
        (draft != null && draft is! String)) {
      throw const XmlyException('protocol', '文稿内容格式无效');
    }
    if (lyric is String && lyric.trim().isNotEmpty) return lyric;
    return draft is String && draft.trim().isNotEmpty ? draft : null;
  }

  Future<Track> track(String trackId, {bool force = false}) async {
    final number = xmlyIdentifier(trackId);
    final cached = _metadata[number];
    if (!force && cached != null) return cached;
    final info = await _info(number);
    _matchingId(info, number);
    final value = _withCatalogueMetadata(Track.fromApi(info));
    _remember(value);
    return value;
  }

  /// Validate a full paid authorization before it can enter the normal media
  /// probe/cache path. Sample metadata may coexist with an authorized full file.
  static ({Uri uri, String quality}) paidAudio(
    Map<String, dynamic> metadata, {
    required String trackId,
    required String albumId,
    required String uid,
  }) {
    if (metadata['ret'] != 0)
      throw const XmlyException(
        'permission_denied',
        '未获得付费声音的完整权限',
        definitive: true,
      );
    _matchingId(metadata, xmlyIdentifier(trackId));
    if ('${metadata['albumId'] ?? ''}' != xmlyIdentifier(albumId))
      throw const XmlyException(
        'id_mismatch',
        '返回的专辑 ID 不匹配',
        definitive: true,
      );
    if (metadata['isAuthorized'] != true)
      throw const XmlyException(
        'permission_denied',
        '未获得付费声音的完整权限',
        definitive: true,
      );
    if (metadata['isPreview'] == true || metadata['isTrial'] == true)
      throw const XmlyException(
        'preview_only',
        '仅获得试听音频，不能下载完整声音',
        definitive: true,
      );
    final uri = mediaUri(XmlyCrypto.paidMediaUrl(metadata, uid: uid));
    if (uri.path.toLowerCase().contains('_preview_'))
      throw const XmlyException(
        'preview_only',
        '仅获得试听音频，不能下载完整声音',
        definitive: true,
      );
    // Official parseChargeJsonAndGetUrl selects the default 64-kbit resource,
    // not the requested quality or highestQualityLevel (which is only a ceiling).
    return (uri: uri, quality: uri.path.endsWith('.m4a') ? 'm4a_64' : 'mp3_64');
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
    int mediaAuthRetries = 3,
    bool Function()? isActive,
  }) => _resolveLock.synchronized(() async {
    if (mediaAuthRetries < 0 || mediaAuthRetries > 3)
      throw const XmlyException('invalid_retry', '音频授权重试次数无效');
    for (var attempt = 0; ; attempt++) {
      if (isActive != null && !isActive())
        throw const XmlyException('cache_source_changed', '音频来源已变化');
      try {
        return await _resolveOnce(
          trackId,
          force: force || attempt > 0,
          preferCached: preferCached && attempt == 0,
          quality: quality,
        );
      } on XmlyException catch (error) {
        if (error.code != 'media_unauthorized' || attempt >= mediaAuthRetries)
          rethrow;
      }
    }
  });

  /// Only for a task with a matching, confirmed, non-historical debit receipt.
  /// Reuses an already verified lease; never obtains a new authorization.
  Future<ResolvedAudio?> cachedPrepaidAudio(
    String trackId, {
    String? quality,
  }) => _resolveLock.synchronized(() async {
    final requestedQuality = quality ?? this.quality;
    if (requestedQuality != 'auto' && !_qualities.contains(requestedQuality)) {
      throw const XmlyException('invalid_quality', '音质设置无效', definitive: true);
    }
    final number = xmlyIdentifier(trackId);
    final epoch = _urlEpoch;
    await _urlCacheReady;
    if (_closed || !accountAvailable || epoch != _urlEpoch) return null;
    for (final candidateQuality
        in requestedQuality == 'auto' ? _qualities : [requestedQuality]) {
      final key = _urlKey(number, candidateQuality);
      final entry = _urls[key];
      if (entry == null ||
          !entry.verified ||
          entry.authorizedTrack == null ||
          entry.requiresReward != true ||
          (entry.deadline != null &&
              !entry.deadline!.isAfter(DateTime.now()))) {
        continue;
      }
      final track = entry.authorizedTrack!;
      final ResolvedAudio audio;
      try {
        audio = await _resolvedAudio(entry, track, true);
      } on XmlyException catch (error) {
        if (error.code == 'media_unauthorized') return null;
        rethrow;
      }
      if (_closed ||
          !accountAvailable ||
          epoch != _urlEpoch ||
          !identical(_urls[key], entry) ||
          (entry.deadline != null &&
              !entry.deadline!.isAfter(DateTime.now()))) {
        return null;
      }
      _remember(track);
      return audio;
    }
    return null;
  });

  Future<ResolvedAudio> _resolveOnce(
    String trackId, {
    required bool force,
    required bool preferCached,
    String? quality,
  }) async {
    if (_closed)
      throw const XmlyException('client_closed', '连接已关闭', definitive: true);
    final requestedQuality = quality ?? this.quality;
    if (requestedQuality != 'auto' && !_qualities.contains(requestedQuality)) {
      throw const XmlyException('invalid_quality', '音质设置无效', definitive: true);
    }
    final number = xmlyIdentifier(trackId);
    if (force) {
      _invalidateUrls(
        number,
        quality: requestedQuality == 'auto' ? null : requestedQuality,
      );
      await flushUrlCache();
    }
    await _checkRead(Zone.current[_readPolicyKey] as _ReadPolicy?);
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
    final track = _withCatalogueMetadata(Track.fromApi(info));
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
    if (candidates.isEmpty &&
        accountAvailable &&
        (info['isPaid'] ?? info['is_paid']) != false) {
      final metadata = await request(
        'GET',
        paidOrigin,
        '/mobile/track/pay/$number/ts-${DateTime.now().millisecondsSinceEpoch}',
        query: {'device': 'android'},
      );
      final paid = paidAudio(
        metadata,
        trackId: number,
        albumId: track.albumId,
        uid: _requireAccount().uid,
      );
      candidates[paid.quality] = paid.uri;
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
    final key = _urlKey(number, chosen);
    final cached = _urls[key];
    // We have just obtained fresh authority. Only the explicit preferCached
    // branch may select an old lease; its URL cannot override this response.
    final entry = _CachedAudioUrl(number, chosen, uri, _urlDeadline(uri));
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
      if (evictedVerified || cached?.verified == true) _saveUrlCache();
    }
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
  }

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
    final policy = Zone.current[_readPolicyKey] as _ReadPolicy?;
    await _checkRead(policy);
    var uri = audio.uri;
    final epoch = _urlEpoch;
    var redirects = 0, rateRetries = 0;
    while (true) {
      final cancel = CancelToken();
      final diagnostic = RequestDiagnostic(
        account: identity,
        method: 'GET',
        url: uri.toString(),
      );
      try {
        final next = await _readAttempt(
          Future.any<Uri?>([
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
              diagnostic.responseBytes = bytes.toBytes;
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
              if (status == 429) {
                _rateLimit(
                  uri.origin,
                  _retryAfter(response.headers.value('retry-after')),
                );
              }
              if (!successful)
                throw XmlyException(
                  status == 401 || status == 403
                      ? 'media_unauthorized'
                      : 'media_http',
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
              diagnostic.responseBytes = () => prefix;
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
                throw const XmlyException(
                  'invalid_media',
                  '响应不是可识别的音频，未缓存错误页面',
                );
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
          ]),
          cancel,
          policy,
        ).timeout(const Duration(seconds: 25));
        if (_closed)
          throw const XmlyException('client_closed', '连接已关闭', definitive: true);
        if (_expired || epoch != _urlEpoch || !identical(_urls[key], entry))
          throw const XmlyException('cache_source_changed', '音频来源已变化，请重新获取');
        if (next != null) {
          redirects++;
          uri = next;
          continue;
        }
        audio.rememberFinalUri(uri);
        return audio;
      } catch (error) {
        cancel.cancel();
        if (error is XmlyException &&
            error.code == 'media_unauthorized' &&
            identical(_urls[key], entry)) {
          // A rejected track authorization cannot fall back to a cached
          // sibling quality. Revoke even if the caller stopped the probe.
          _invalidateUrls(entry.number);
        }
        if (_closed || policy?.stopped == true) {
          // A cancelled read must not wait for the diagnostic disk queue before
          // releasing its caller. Preserve the failure record independently.
          unawaited(diagnostic.fail(error));
          await _checkRead(policy);
        }
        if (error is XmlyException && error.code == 'rate_limited') {
          await diagnostic.fail(error);
          if (rateRetries++ >= (policy?.rateLimitRetries ?? 4)) rethrow;
          final server = error.retryAfter ?? Duration.zero;
          final minimum = policy?.minimumRateLimitDelay ?? Duration.zero;
          await _retryWait(server > minimum ? server : minimum, policy);
          continue;
        }
        _invalidateLease(key, entry);
        if (error is! XmlyException) diagnostic.transportError = '$error';
        await diagnostic.fail(error);
        await _checkRead(policy);
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

  void _invalidateUrls(String? number, {String? quality}) {
    _urlEpoch++;
    if (number == null) {
      _urls.clear();
      _discardUrlCacheLoad = true;
      _urlLoadInvalidations.clear();
    } else {
      _urls.removeWhere(
        (_, entry) =>
            entry.number == number &&
            (quality == null || entry.quality == quality),
      );
      if (!_urlCacheLoaded) {
        for (final candidate in quality == null ? _qualities : [quality]) {
          _urlLoadInvalidations.add(_urlKey(number, candidate));
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

class _ReadPolicy {
  _ReadPolicy(
    this.rateLimitRetries,
    this.minimumRateLimitDelay,
    Future<void>? cancelled,
    this.checkpoint,
  ) {
    this.cancelled = cancelled?.then((_) {
      stopped = true;
    });
  }
  final int rateLimitRetries;
  final Duration minimumRateLimitDelay;
  late final Future<void>? cancelled;
  final Future<void> Function()? checkpoint;
  bool stopped = false;
}

class _BalanceChanges {
  final lock = Lock();
  int users = 0;
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
