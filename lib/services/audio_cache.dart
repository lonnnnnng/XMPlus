import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import 'request_diagnostics.dart';

/// The sole upstream byte producer for one account/track/task directory.
/// URLs and caller identity headers never enter the on-disk index.
class AudioCache {
  static const blockSize = 1024 * 1024;
  static final _openDirectories = <String>{};
  final String directory;
  ResolvedAudio _audio;
  final Future<ResolvedAudio> Function(bool Function() isActive)? _refresh;
  final Future<void> Function()? _checkpoint;
  final void Function(int, int?, double)? _onProgress;
  final _blocks = <int, String>{};
  final _waiting = <int, Completer<void>>{};
  final _priority = LinkedHashSet<int>();
  final Lock _disk = Lock();
  Completer<void> _changed = Completer<void>();
  HttpClient? _client;
  Future<void>? _running;
  Completer<void>? _interruptedWait;
  int _producerEpoch = 0;
  Object? _failure;
  StackTrace? _failureStack;
  bool _closed = false, _paused = false, _background = false;
  bool _validated = false, _ranges = true, _refreshed = false;
  int? _length;
  int _generation = 0, _revision = 0;
  int? _partialBlock;
  int _partialBytes = 0;
  String? _etag, _modified;
  String _format = '';
  final Stopwatch _speedClock = Stopwatch()..start();
  int _speedBytes = 0;
  RequestDiagnostic? _diagnostic;

  AudioCache._(
    this.directory,
    this._audio,
    this._refresh,
    this._checkpoint,
    this._onProgress,
  );

  static Future<AudioCache> open({
    required String directory,
    required ResolvedAudio audio,
    Future<ResolvedAudio> Function(bool Function() isActive)? refresh,
    Future<void> Function()? checkpoint,
    void Function(int received, int? total, double rate)? onProgress,
  }) async {
    final path = p.normalize(p.absolute(directory));
    if (!_openDirectories.add(Platform.isWindows ? path.toLowerCase() : path)) {
      throw const XmlyException('cache_in_use', '此缓存正在使用');
    }
    final cache = AudioCache._(path, audio, refresh, checkpoint, onProgress);
    try {
      cache._validateUri(audio.uri);
      await Directory(path).create(recursive: true);
      await cache._load();
      return cache;
    } catch (_) {
      _openDirectories.remove(Platform.isWindows ? path.toLowerCase() : path);
      rethrow;
    }
  }

  int? get length => _length;
  bool get supportsRanges => _ranges;
  String get sourceFormat => _format;
  int get generation => _generation;

  void updateAuthorization(ResolvedAudio audio) {
    if (_running != null)
      throw const XmlyException('cache_in_use', '请先暂停原媒体请求');
    if (audio.accountIdentity != _audio.accountIdentity ||
        audio.track.id != _audio.track.id) {
      throw const XmlyException('cache_identity', '音频授权与缓存身份不符');
    }
    _validateUri(audio.uri);
    _audio = audio;
    _refreshed = false;
  }

  int get downloadedBytes =>
      _blocks.keys.fold(0, (sum, index) => sum + _blockLength(index)) +
      _partialBytes;
  bool get complete =>
      _validated &&
      _length != null &&
      _blocks.length == (_length! - 1) ~/ blockSize + 1;
  File _block(int index) => File(p.join(directory, '$index.block'));
  File _part(int index) => File(p.join(directory, '$index.part'));
  int _blockLength(int index) => _length == null
      ? blockSize
      : min(blockSize, _length! - index * blockSize);

  Uri _validateUri(Uri uri) => XmlyClient.mediaUri(uri.toString());

  Future<void> _load() async {
    Map<String, dynamic>? latest;
    for (var slot = 0; slot < 2; slot++) {
      final file = File(p.join(directory, 'index.$slot.json'));
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 8 * 1024 * 1024) continue;
        final value = jsonDecode(await file.readAsString());
        if (value is! Map<String, dynamic> ||
            value['version'] != 1 ||
            value['revision'] is! int)
          continue;
        if (latest == null ||
            (value['revision'] as int) > (latest['revision'] as int))
          latest = value;
      } on FormatException {
        continue;
      }
    }
    if (latest == null) return;
    if (latest['account'] != _audio.accountIdentity ||
        latest['track'] != _audio.track.id ||
        latest['directory'] != directory) {
      throw const XmlyException('cache_identity', '缓存不属于当前账号或任务');
    }
    _revision = latest['revision'] as int;
    final size = latest['length'];
    if (size != null && (size is! int || size <= 0)) return;
    _length = size as int?;
    _etag = latest['etag'] is String ? latest['etag'] as String : null;
    _modified = latest['modified'] is String
        ? latest['modified'] as String
        : null;
    _ranges = latest['ranges'] == true;
    _format = latest['format'] is String ? latest['format'] as String : '';
    if (!_ranges || _length == null || latest['blocks'] is! Map) return;
    for (final entry in (latest['blocks'] as Map).entries) {
      final index = int.tryParse(entry.key.toString());
      if (index == null ||
          index < 0 ||
          index * blockSize >= _length! ||
          entry.value is! String)
        continue;
      final file = _block(index);
      if (await file.exists() &&
          await file.length() == _blockLength(index) &&
          (await sha256.bind(file.openRead()).single).toString() ==
              entry.value) {
        _blocks[index] = entry.value as String;
      }
    }
    // A resumed cache is not readable until a new upstream response verifies it.
  }

  Future<void> _save({int? index, String? digest}) async {
    final revision = _revision + 1;
    final target = File(p.join(directory, 'index.${revision % 2}.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'revision': revision,
        'account': _audio.accountIdentity,
        'track': _audio.track.id,
        'directory': directory,
        'length': _length,
        'etag': _etag,
        'modified': _modified,
        'ranges': _ranges,
        'format': _format,
        'blocks': {
          for (final entry in _blocks.entries) '${entry.key}': entry.value,
          if (index != null) '$index': digest,
        },
      }),
      flush: true,
    );
    // Two generations preserve the last committed index even on Windows, where
    // rename cannot replace a file. An interrupted inactive-slot write is ignored.
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    _revision = revision;
  }

  void _signal() {
    final old = _changed;
    _changed = Completer<void>();
    old.complete();
  }

  void _checkState() {
    if (_closed) throw const XmlyException('cache_closed', '缓存已关闭');
    if (_paused) throw const XmlyException('cache_paused', '下载已暂停');
    if (_failure != null) Error.throwWithStackTrace(_failure!, _failureStack!);
  }

  void _checkProducer(int epoch) {
    _checkState();
    if (epoch != _producerEpoch)
      throw const XmlyException('cache_source_changed', '音频来源已变化');
  }

  Future<T> _whileActive<T>(int epoch, Future<T> Function() operation) async {
    _checkProducer(epoch);
    final interrupted = Completer<void>();
    _interruptedWait = interrupted;
    try {
      // A per-wait completer releases its listener after this wait. Future.any
      // also observes late operation errors after pause has won the race.
      final result = await Future.any<T>([
        Future<T>.sync(operation),
        interrupted.future.then<T>((_) {
          _checkProducer(epoch);
          throw const XmlyException('cache_source_changed', '音频来源已变化');
        }),
      ]);
      _checkProducer(epoch);
      return result;
    } finally {
      if (identical(_interruptedWait, interrupted)) _interruptedWait = null;
    }
  }

  void _resume() {
    if (_closed) throw const XmlyException('cache_closed', '缓存已关闭');
    if (_running == null) {
      if (!_ranges && !complete) _validated = false;
      _paused = false;
      _failure = null;
      _failureStack = null;
    }
  }

  Future<void> _need(int index) {
    if (_validated && _blocks.containsKey(index)) return Future<void>.value();
    final waiter = _waiting.putIfAbsent(index, () => Completer<void>());
    _priority.add(index);
    _kick();
    return waiter.future;
  }

  void _kick() {
    if (_running != null || _closed || _paused || _failure != null || complete)
      return;
    _running = _produce(++_producerEpoch);
  }

  Future<void> _produce(int epoch) async {
    try {
      while (!_closed && !_paused) {
        if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
        int? next;
        if (!_validated) {
          next = 0;
        } else {
          _priority.removeWhere(
            (index) =>
                _blocks.containsKey(index) ||
                (_length != null && index * blockSize >= _length!),
          );
          if (_priority.isNotEmpty) next = _priority.first;
          if (next == null && _background && !complete) {
            next = 0;
            while (_blocks.containsKey(next)) {
              next = next! + 1;
            }
          }
        }
        if (next == null) break;
        await _fetchWithRetry(next, epoch);
        for (final index in _waiting.keys.toList()) {
          if (_validated &&
              (_blocks.containsKey(index) ||
                  (_length != null && index * blockSize >= _length!))) {
            _waiting.remove(index)!.complete();
          }
        }
        _signal();
      }
    } catch (error, stack) {
      _client?.close(force: true);
      _client = null;
      _failure = _closed
          ? const XmlyException('cache_closed', '缓存已关闭')
          : _paused
          ? const XmlyException('cache_paused', '下载已暂停')
          : error;
      _failureStack = stack;
      for (final waiter in _waiting.values) {
        waiter.completeError(_failure!, stack);
      }
      _waiting.clear();
      _priority.clear();
    } finally {
      _running = null;
      _signal();
    }
  }

  Future<T> _transport<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on SocketException catch (error, stack) {
      throw _AudioTransportFailure(error, stack);
    } on TimeoutException catch (error, stack) {
      throw _AudioTransportFailure(error, stack);
    } on HttpException catch (error, stack) {
      final message = error.message.toLowerCase();
      if (!message.startsWith('connection closed') &&
          !message.contains('connection reset by peer'))
        rethrow;
      throw _AudioTransportFailure(error, stack);
    }
  }

  Future<void> _fetchWithRetry(int index, int epoch) async {
    for (var attempt = 0; ; attempt++) {
      _diagnostic = null;
      try {
        await _fetch(index, epoch, resumeSequential: attempt > 0);
        return;
      } catch (error, stack) {
        if (!_paused && !_closed) {
          await _diagnostic?.fail(
            error is _AudioTransportFailure ? error.error : error,
          );
        }
        final rateLimited =
            error is XmlyException && error.code == 'rate_limited';
        if (error is! _AudioTransportFailure && !rateLimited) rethrow;
        _client?.close(force: true);
        _client = null;
        _checkProducer(epoch);
        if (attempt >= 4) {
          if (error is _AudioTransportFailure)
            Error.throwWithStackTrace(error.error, error.stack);
          Error.throwWithStackTrace(error, stack);
        }
        final backoff = Duration(seconds: 1 << attempt);
        final retryAfter = rateLimited ? error.retryAfter : null;
        final ready = Completer<void>();
        final timer = Timer(
          retryAfter != null && retryAfter > backoff ? retryAfter : backoff,
          ready.complete,
        );
        try {
          await _whileActive(epoch, () => ready.future);
        } finally {
          // Losing the active-wait race must also release its timer; otherwise
          // a long Retry-After keeps the isolate alive after pause or close.
          timer.cancel();
        }
      }
    }
  }

  Stream<List<int>> _responseBytes(
    HttpClientResponse response,
    int epoch,
  ) async* {
    final iterator = StreamIterator(
      response.timeout(const Duration(seconds: 25)),
    );
    try {
      while (await _whileActive(epoch, () => _transport(iterator.moveNext))) {
        yield iterator.current;
      }
      _diagnostic?.completeness = '完整（已接收音频响应体）';
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _discard(HttpClientResponse response) =>
      response.listen(null).cancel();

  Future<void> _captureFailureResponse(
    HttpClientResponse response,
    Object error,
  ) async {
    final diagnostic = _diagnostic!;
    const limit = 2 * 1024 * 1024;
    var received = 0;
    diagnostic.responseByteCount = () => received;
    diagnostic.completeness = '响应体未接收完整（接收中或传输中断）';
    try {
      await for (final chunk in _responseBytes(response, _producerEpoch)) {
        received += chunk.length;
        if (received > limit) {
          diagnostic.completeness = '错误响应体已截断：诊断上限 $limit 字节';
          break;
        }
      }
      if (!diagnostic.completeness.contains('截断')) {
        diagnostic.completeness =
            response.contentLength >= 0 && response.contentLength != received
            ? '响应体不完整：声明 ${response.contentLength} 字节，收到 $received 字节'
            : '完整（HTTP 响应体）';
      }
    } catch (transportError) {
      diagnostic.transportError = '$transportError';
    }
    if (!_paused && !_closed) await diagnostic.fail(error);
  }

  Future<({HttpClientResponse response, Uri finalUri})> _request(
    int start,
    int end,
    int epoch,
  ) async {
    var uri = _audio.uri;
    for (var redirects = 0; ; redirects++) {
      try {
        uri = _validateUri(uri);
      } on XmlyException {
        _audio.invalidateCachedUri();
        rethrow;
      }
      _checkProducer(epoch);
      _client ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..autoUncompress = false;
      final diagnostic = RequestDiagnostic(
        account: _audio.accountIdentity,
        method: 'GET',
        url: uri.toString(),
      );
      diagnostic.requestHeaders = {
        HttpHeaders.userAgentHeader: 'XMPlus/1.0',
        HttpHeaders.acceptHeader: 'audio/*, application/octet-stream',
        HttpHeaders.acceptEncodingHeader: 'identity',
        HttpHeaders.rangeHeader: 'bytes=$start-$end',
        if (_validated &&
            _blocks.isNotEmpty &&
            (_etag != null || _modified != null))
          HttpHeaders.ifRangeHeader: _etag != null && !_etag!.startsWith('W/')
              ? _etag
              : _modified,
      };
      _diagnostic = diagnostic;
      final request = await _whileActive(
        epoch,
        () => _transport(
          () => _client!.getUrl(uri).timeout(const Duration(seconds: 25)),
        ),
      );
      request.followRedirects = false;
      // Deliberately ignore ResolvedAudio.headers. API cookies, x-tk and all other
      // identity headers must never reach either a CDN or its redirect target.
      request.headers.set(HttpHeaders.userAgentHeader, 'XMPlus/1.0');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'audio/*, application/octet-stream',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      if (_validated && _blocks.isNotEmpty) {
        final validator = _etag != null && !_etag!.startsWith('W/')
            ? _etag
            : _modified;
        if (validator != null)
          request.headers.set(HttpHeaders.ifRangeHeader, validator);
      }
      request.headers.forEach((name, values) {
        diagnostic.requestHeaders[name] = List<String>.of(values);
      });
      final response = await _whileActive(
        epoch,
        () => _transport(
          () => request.close().timeout(const Duration(seconds: 25)),
        ),
      );
      diagnostic.status = response.statusCode;
      response.headers.forEach((name, values) {
        diagnostic.responseHeaders[name] = List<String>.of(values);
      });
      diagnostic.completeness = '响应体未接收完整（接收中或传输中断）';
      if (![200, 206, 301, 302, 303, 307, 308].contains(response.statusCode)) {
        await _captureFailureResponse(
          response,
          HttpException('HTTP ${response.statusCode}', uri: uri),
        );
      }
      if (response.statusCode >= 500 && response.statusCode <= 599) {
        throw _AudioTransportFailure(
          HttpException('HTTP ${response.statusCode}', uri: uri),
          StackTrace.current,
        );
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && location.isNotEmpty && redirects < 5) {
          try {
            final target = _validateUri(uri.resolve(location));
            await _discard(response);
            uri = target;
            continue;
          } catch (error) {
            await _captureFailureResponse(response, error);
            _audio.invalidateCachedUri();
            rethrow;
          }
        }
        await _captureFailureResponse(
          response,
          const XmlyException('invalid_media', '音频重定向过多或无效'),
        );
        _audio.invalidateCachedUri();
        throw const XmlyException('invalid_media', '音频重定向过多或无效');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        _audio.invalidateCachedUri();
        if (_refreshed || _refresh == null)
          throw const XmlyException('media_http', '音频授权已失效，请重新获取');
        _refreshed = true;
        final generation = _generation;
        bool isActive() =>
            !_closed &&
            !_paused &&
            epoch == _producerEpoch &&
            generation == _generation;
        late ResolvedAudio audio;
        try {
          audio = await _whileActive(epoch, () => _refresh(isActive));
        } catch (_) {
          if (!isActive()) _refreshed = false;
          rethrow;
        }
        if (!isActive())
          throw const XmlyException('cache_source_changed', '音频来源已变化');
        if (audio.accountIdentity != _audio.accountIdentity ||
            audio.track.id != _audio.track.id) {
          throw const XmlyException('cache_identity', '重新授权的账号或声音不一致');
        }
        _validateUri(audio.uri);
        _audio = audio;
        uri = audio.uri;
        redirects = -1;
        continue;
      }
      if (response.statusCode == 429) {
        final header = response.headers.value(HttpHeaders.retryAfterHeader);
        var wait = const Duration(minutes: 5);
        final seconds = int.tryParse(header ?? '');
        if (seconds != null && seconds >= 0) {
          wait = Duration(seconds: seconds);
        } else if (header != null) {
          try {
            final duration = HttpDate.parse(header)
                .difference(DateTime.now().toUtc());
            if (!duration.isNegative) wait = duration;
          } on FormatException {
            /* Use the documented five-minute cooldown. */
          }
        }
        throw XmlyException('rate_limited', '音频请求过于频繁，请稍后重试', retryAfter: wait);
      }
      return (response: response, finalUri: uri);
    }
  }

  bool _acceptableType(HttpClientResponse response) {
    final type = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    return type.startsWith('audio/') ||
        type.startsWith('video/') ||
        type == 'application/octet-stream' ||
        type == 'binary/octet-stream' ||
        type == 'application/ogg' ||
        type.isEmpty;
  }

  static String _sniff(List<int> bytes) {
    bool text(int offset, String value) =>
        bytes.length >= offset + value.length &&
        List.generate(
          value.length,
          (i) => bytes[offset + i] == value.codeUnitAt(i),
        ).every((v) => v);
    if (text(0, 'ID3')) return 'mp3';
    if (text(0, 'fLaC')) return 'flac';
    if (text(0, 'OggS')) return 'ogg';
    if (text(0, 'RIFF') && text(8, 'WAVE')) return 'wav';
    if (text(4, 'ftyp')) return 'm4a';
    if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        (bytes[1] & 0xe0) == 0xe0 &&
        (bytes[1] & 0x06) != 0 &&
        (bytes[2] & 0xf0) != 0xf0 &&
        (bytes[2] & 0xf0) != 0 &&
        (bytes[2] & 0x0c) != 0x0c)
      return 'mp3';
    if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        (bytes[1] & 0xf6) == 0xf0 &&
        (bytes[2] & 0x3c) != 0x3c)
      return 'aac';
    throw const XmlyException('invalid_media', '响应不是可识别的音频，未保存错误页面');
  }

  Future<void> _reset() => _disk.synchronized(() async {
    // Commit the empty index before removing old blocks. Orphans are never read.
    _generation++;
    _blocks.clear();
    _partialBlock = null;
    _partialBytes = 0;
    _validated = false;
    await _save();
    await for (final entry in Directory(directory).list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'^[0-9]+\.(?:block|part)$')
              .hasMatch(p.basename(entry.path))) {
        await entry.delete();
      }
    }
    _signal();
  });

  Future<bool> _metadata(
    HttpClientResponse response,
    int? size,
    bool ranges, {
    bool resumeSequential = false,
  }) async {
    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    final hadBytes = _blocks.isNotEmpty || _partialBytes > 0;
    final changed =
        hadBytes &&
        (_length != size ||
            _etag != etag ||
            _modified != modified ||
            _ranges != ranges ||
            (!ranges && !resumeSequential) ||
            (!_validated && etag == null && modified == null));
    if (changed) await _reset();
    _length = size;
    _etag = etag;
    _modified = modified;
    _ranges = ranges;
    return changed;
  }

  Future<void> _fetch(
    int index,
    int epoch, {
    bool resumeSequential = false,
  }) async {
    final start = index * blockSize;
    final requestedEnd = !_validated || _length == null
        ? start + blockSize - 1
        : min(start + blockSize, _length!) - 1;
    final result = await _request(start, requestedEnd, epoch);
    final response = result.response;
    if (response.statusCode == 416) {
      final match = RegExp(r'^bytes \*/([0-9]+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (complete && match != null && int.tryParse(match[1]!) == _length)
        return;
      _audio.invalidateCachedUri();
      final size = match == null ? null : int.tryParse(match[1]!);
      if (size != null && size > 0 && size != _length) {
        await _reset();
        _length = size;
        await _save();
      }
      throw const XmlyException('cache_range', '服务器拒绝音频范围，缓存尚未完整');
    }
    if (![200, 206].contains(response.statusCode) ||
        !_acceptableType(response) ||
        (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                'identity') !=
            'identity') {
      _audio.invalidateCachedUri();
      if ([200, 206].contains(response.statusCode)) {
        await _captureFailureResponse(
          response,
          const XmlyException('invalid_media', '服务器未返回有效音频'),
        );
      }
      throw const XmlyException('invalid_media', '服务器未返回有效音频');
    }
    if (response.statusCode == 200) {
      final changed = await _metadata(
        response,
        response.contentLength < 0 ? null : response.contentLength,
        false,
        resumeSequential: resumeSequential,
      );
      final resumeBytes = resumeSequential && !changed ? downloadedBytes : 0;
      if (resumeBytes == 0 && (_blocks.isNotEmpty || _partialBytes > 0)) {
        await _reset();
      }
      await _sequential(response, result.finalUri, epoch, resumeBytes);
      return;
    }
    final match = RegExp(
      r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
    ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    final first = match == null ? null : int.tryParse(match[1]!);
    final last = match == null ? null : int.tryParse(match[2]!);
    final total = match == null ? null : int.tryParse(match[3]!);
    if (first != start ||
        last == null ||
        total == null ||
        total <= 0 ||
        last < start ||
        last != min(requestedEnd, total - 1) ||
        (response.contentLength >= 0 &&
            response.contentLength != last - start + 1)) {
      _audio.invalidateCachedUri();
      await _captureFailureResponse(
        response,
        const XmlyException('cache_range', '服务器返回的音频范围不一致'),
      );
      throw const XmlyException('cache_range', '服务器返回的音频范围不一致');
    }
    final changed = await _metadata(response, total, true);
    if (changed &&
        (index != 0 || last != min(start + blockSize - 1, total - 1))) {
      await _discard(response);
      return;
    }
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    _diagnostic?.responseByteCount = () => received;
    try {
      await for (final chunk in _responseBytes(response, epoch)) {
        received += chunk.length;
        _checkState();
        if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
        if (bytes.length + chunk.length > last - start + 1)
          throw const XmlyException('cache_range', '音频块长度不一致');
        bytes.add(chunk);
      }
      if (bytes.length != last - start + 1) {
        _diagnostic?.completeness =
            '响应体不完整：范围声明 ${last - start + 1} 字节，收到 ${bytes.length} 字节';
        throw const XmlyException('cache_range', '音频块未接收完整');
      }
      final data = bytes.takeBytes();
      if (index == 0) {
        _format = _sniff(data);
        final oldHash = _blocks[0];
        if (oldHash != null && oldHash != sha256.convert(data).toString())
          await _reset();
        _validated = true;
      }
      _checkProducer(epoch);
      _audio.rememberFinalUri(result.finalUri);
      await _commitBlock(index, data);
    } on XmlyException catch (error) {
      if (error.code == 'invalid_media' || error.code == 'cache_range')
        _audio.invalidateCachedUri();
      rethrow;
    } finally {
      _signal();
    }
  }

  Future<void> _commitBlock(int index, List<int> bytes) =>
      _disk.synchronized(() async {
        final temporary = _part(index);
        await temporary.writeAsBytes(bytes, flush: true);
        final target = _block(index);
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
        final digest = sha256.convert(bytes).toString();
        await _save(index: index, digest: digest);
        _blocks[index] = digest;
        _progress(bytes.length);
        _signal();
      });

  Future<void> _sequential(
    HttpClientResponse response,
    Uri finalUri,
    int epoch,
    int resumeBytes,
  ) async {
    var offset = 0;
    RandomAccessFile? writer;
    final prefix = BytesBuilder(copy: false);
    var sniffed = false;
    Future<void> writeChunk(List<int> bytes) async {
      var position = 0;
      while (position < bytes.length) {
        _checkProducer(epoch);
        final index = offset ~/ blockSize;
        if (offset < resumeBytes) {
          // A non-range server must replay its prefix. Compare every cached
          // byte before appending, even when it supplies no version validator.
          final count = min(
            bytes.length - position,
            min(resumeBytes - offset, blockSize - offset % blockSize),
          );
          final file = _blocks.containsKey(index)
              ? _block(index)
              : _part(index);
          final handle = await file.open();
          late List<int> cached;
          try {
            await handle.setPosition(offset % blockSize);
            cached = await handle.read(count);
          } finally {
            await handle.close();
          }
          var matches = cached.length == count;
          for (var i = 0; matches && i < count; i++) {
            matches = cached[i] == bytes[position + i];
          }
          _checkProducer(epoch);
          if (!matches) {
            await _reset();
            throw const XmlyException('cache_source_changed', '音频来源已变化');
          }
          offset += count;
          position += count;
          continue;
        }
        writer ??= await _part(index).open(
          mode: offset % blockSize == 0 ? FileMode.write : FileMode.append,
        );
        final count = min(
          bytes.length - position,
          blockSize - offset % blockSize,
        );
        await writer!.writeFrom(bytes, position, position + count);
        await writer!.flush();
        offset += count;
        position += count;
        _partialBlock = index;
        _partialBytes = offset % blockSize == 0
            ? blockSize
            : offset % blockSize;
        if (_partialBytes == blockSize) {
          await writer!.close();
          writer = null;
          await _finishSequentialBlock(index);
        }
        _progress(count);
        _signal();
      }
    }

    // long: 失败诊断只统计网络接收量，不同步回读整个长音频，避免失败时阻塞界面。
    var received = 0;
    _diagnostic?.responseByteCount = () => received;
    try {
      await for (final chunk in _responseBytes(response, epoch)) {
        received += chunk.length;
        _checkState();
        if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
        if (_length != null &&
            offset + prefix.length + chunk.length > _length!) {
          throw const XmlyException('cache_range', '音频流超过声明长度');
        }
        if (!sniffed) {
          prefix.add(chunk);
          if (prefix.length < 12) continue;
          final initial = prefix.takeBytes();
          _format = _sniff(initial);
          _validated = true;
          sniffed = true;
          _checkProducer(epoch);
          _audio.rememberFinalUri(finalUri);
          await writeChunk(initial);
        } else {
          await writeChunk(chunk);
        }
      }
      if (!sniffed) {
        final initial = prefix.takeBytes();
        _format = _sniff(initial);
        _validated = true;
        _checkProducer(epoch);
        _audio.rememberFinalUri(finalUri);
        await writeChunk(initial);
      }
      if (_length != null && offset != _length)
        throw const XmlyException('cache_range', '音频流未接收完整');
      if (offset <= 0) throw const XmlyException('invalid_media', '音频为空');
      _length = offset;
      if (writer != null) {
        await writer!.close();
        writer = null;
        await _finishSequentialBlock((offset - 1) ~/ blockSize);
      }
      await _save();
    } on XmlyException catch (error) {
      if (error.code == 'invalid_media' || error.code == 'cache_range')
        _audio.invalidateCachedUri();
      rethrow;
    } finally {
      await writer?.close();
      _signal();
    }
  }

  Future<void> _finishSequentialBlock(int index) =>
      _disk.synchronized(() async {
        final temporary = _part(index);
        final digest = (await sha256.bind(temporary.openRead()).single)
            .toString();
        final target = _block(index);
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
        await _save(index: index, digest: digest);
        _blocks[index] = digest;
        _partialBlock = null;
        _partialBytes = 0;
      });

  void _progress(int count) {
    _speedBytes += count;
    final seconds = _speedClock.elapsedMicroseconds / 1000000;
    _onProgress?.call(
      downloadedBytes,
      _length,
      seconds > 0 ? _speedBytes / seconds : 0,
    );
  }

  Future<void> ensureComplete() async {
    _resume();
    _background = true;
    _kick();
    while (!complete) {
      final changed = _changed.future;
      _checkState();
      await changed;
    }
    await _running;
    _checkState();
  }

  Future<List<int>> read(int start, int endExclusive) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream(start, endExclusive)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Stream<List<int>> stream(int start, [int? endExclusive]) {
    final output = StreamController<List<int>>();
    final cancelled = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    output.onListen = () {
      subscription = _readStream(
        start,
        endExclusive,
        cancelled,
      ).listen(output.add, onError: output.addError, onDone: output.close);
    };
    output.onPause = () => subscription?.pause();
    output.onResume = () => subscription?.resume();
    output.onCancel = () async {
      if (!cancelled.isCompleted) cancelled.complete();
      await subscription?.cancel();
    };
    return output.stream;
  }

  Stream<List<int>> _readStream(
    int start,
    int? endExclusive,
    Completer<void> cancelled,
  ) async* {
    if (start < 0 || (endExclusive != null && endExclusive < start))
      throw RangeError('Invalid audio range');
    _resume();
    var initialGeneration = _generation;
    var offset = start;
    while (!cancelled.isCompleted &&
        (endExclusive == null || offset < endExclusive)) {
      final changed = _changed.future;
      _checkState();
      if (_generation != initialGeneration) {
        if (offset != start)
          throw const XmlyException('cache_source_changed', '音频来源已变化，请重新打开');
        initialGeneration = _generation;
      }
      if (_validated && _length != null && offset >= _length!) {
        if (endExclusive != null && endExclusive > _length!)
          throw RangeError('Audio range exceeds length');
        break;
      }
      final index = offset ~/ blockSize;
      if (!_validated || !_blocks.containsKey(index)) _need(index).ignore();
      int available = 0;
      File? file;
      if (_validated && _blocks.containsKey(index)) {
        available = _blockLength(index);
        file = _block(index);
      } else if (_validated && _partialBlock == index) {
        available = _partialBytes;
        file = _part(index);
      }
      final within = offset % blockSize;
      if (file == null || available <= within) {
        await Future.any([changed, cancelled.future]);
        continue;
      }
      final count = min(
        available - within,
        min(
          64 * 1024,
          endExclusive == null ? 64 * 1024 : endExclusive - offset,
        ),
      );
      final data = await _disk.synchronized(() async {
        // Windows cannot rename a partial block while a reader holds its handle.
        RandomAccessFile handle;
        try {
          handle = await file!.open();
        } on FileSystemException {
          if (_blocks.containsKey(index) || _partialBlock == index) {
            handle = await _block(index).open();
          } else {
            rethrow;
          }
        }
        try {
          await handle.setPosition(within);
          return await handle.read(count);
        } finally {
          await handle.close();
        }
      });
      if (_generation != initialGeneration) {
        if (offset == start) continue;
        throw const XmlyException('cache_source_changed', '音频来源已变化，请重新打开');
      }
      if (data.length != count)
        throw const XmlyException('cache_range', '缓存块不完整');
      offset += data.length;
      yield data;
    }
  }

  Future<String> assemble(String outputPath) async {
    await ensureComplete();
    final generation = _generation;
    final output = File(outputPath);
    await output.create(exclusive: true);
    final handle = await output.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in stream(0, _length)) {
        if (_generation != generation)
          throw const XmlyException('cache_source_changed', '音频来源已变化');
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
    return output.path;
  }

  Future<void> pause() async {
    _paused = true;
    _background = false;
    _producerEpoch++;
    final interrupted = _interruptedWait;
    if (interrupted != null && !interrupted.isCompleted) interrupted.complete();
    _client?.close(force: true);
    _client = null;
    _signal();
    await _running;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await pause();
    _openDirectories.remove(
      Platform.isWindows ? directory.toLowerCase() : directory,
    );
  }

  Future<void> deleteRegenerable() async {
    await close();
    await Directory(directory).delete(recursive: true);
  }
}

class _AudioTransportFailure {
  final Object error;
  final StackTrace stack;
  const _AudioTransportFailure(this.error, this.stack);
}

/// Loopback-only, capability-token HTTP facade. No URL ever exposes a disk path.
class AudioProxy {
  final HttpServer _server;
  final String _token;
  final _mounts = <String, AudioCache>{};
  final _keys = <AudioCache, String>{};
  final _random = Random.secure();
  AudioProxy._(this._server, this._token);

  static Future<AudioProxy> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final proxy = AudioProxy._(server, token);
    server.listen((request) {
      unawaited(proxy._serve(request));
    });
    return proxy;
  }

  Uri mount(AudioCache cache) {
    final key = _keys.putIfAbsent(
      cache,
      () =>
          base64UrlEncode(List<int>.generate(24, (_) => _random.nextInt(256)))
              .replaceAll('=', ''),
    );
    _mounts[key] = cache;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      path: '/$_token/$key',
    );
  }

  Future<void> unmount(AudioCache cache) async {
    final key = _keys.remove(cache);
    if (key != null) _mounts.remove(key);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      final cache =
          segments.length == 2 && segments[0] == _token && !request.uri.hasQuery
          ? _mounts[segments[1]]
          : null;
      if (cache == null || request.headers.value('origin') != null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'HEAD, GET');
        await response.close();
        return;
      }
      // First bytes both validate audio and establish any upstream range metadata.
      final firstByte = StreamIterator(cache.stream(0, 1));
      try {
        final available = await Future.any<bool>([
          firstByte.moveNext(),
          response.done.then((_) => false),
        ]);
        if (!available) return;
      } finally {
        await firstByte.cancel();
      }
      final size = cache.length;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      int? end = size;
      if (range != null) {
        final match = RegExp(r'^bytes=([0-9]*)-([0-9]*)$').firstMatch(range);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          await _rangeError(response, size);
          return;
        }
        final first = match[1]!.isEmpty ? null : int.tryParse(match[1]!);
        final last = match[2]!.isEmpty ? null : int.tryParse(match[2]!);
        if ((match[1]!.isNotEmpty && first == null) ||
            (match[2]!.isNotEmpty && last == null) ||
            (first != null && last != null && last < first) ||
            (first == null && (last == null || last <= 0)) ||
            (size != null && first != null && first >= size)) {
          await _rangeError(response, size);
          return;
        }
        if (size == null) {
          // Unknown-length audio ignores valid Range and sends the complete
          // representation as chunked 200, rather than inventing a range end.
          start = 0;
          end = null;
        } else {
          start = first ?? max(0, size - last!);
          end = first == null || last == null ? size : min(last, size - 1) + 1;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${end - 1}/$size',
          );
        }
      }
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        switch (cache.sourceFormat) {
          'mp3' => 'audio/mpeg',
          'm4a' => 'audio/mp4',
          'flac' => 'audio/flac',
          'ogg' => 'audio/ogg',
          'wav' => 'audio/wav',
          'aac' => 'audio/aac',
          _ => 'application/octet-stream',
        },
      );
      response.headers.set(
        HttpHeaders.acceptRangesHeader,
        size != null ? 'bytes' : 'none',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      if (end != null) response.contentLength = end - start;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      response.bufferOutput = false;
      await _pipe(response, cache.stream(start, end));
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        try {
          (await response.detachSocket(writeHeaders: false)).destroy();
        } catch (_) {
          /* Client already disconnected. */
        }
      }
    }
  }

  Future<void> _pipe(HttpResponse response, Stream<List<int>> bytes) async {
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    void finish([Object? error, StackTrace? stack]) {
      if (done.isCompleted) return;
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error, stack);
      }
    }

    subscription = bytes.listen(
      (chunk) {
        subscription.pause();
        try {
          response.add(chunk);
          response.flush().then(
            (_) {
              if (!done.isCompleted) subscription.resume();
            },
            onError: (Object error, StackTrace stack) {
              finish(error, stack);
            },
          );
        } catch (error, stack) {
          finish(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        finish(error, stack);
      },
      onDone: finish,
    );
    // Socket teardown stops this reader even while it is waiting for a missing
    // block; no cancellation reaches the cache's separately-owned producer.
    response.done.then(
      (_) {
        finish();
      },
      onError: (Object error, StackTrace stack) {
        finish(error, stack);
      },
    );
    try {
      await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _rangeError(HttpResponse response, int? size) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes */${size ?? '*'}',
    );
    await response.close();
  }

  Future<void> close() async {
    _mounts.clear();
    _keys.clear();
    await _server.close(force: true);
  }
}
