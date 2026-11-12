// SPDX-License-Identifier: AGPL-3.0-or-later
// Port of xmly/login.py; adapted from sld272/Ximalaya-Downloader-Next
// commit 765bae5cc07aaffa41797de2d3a9c963f1deb3e9 (native_py.py/client.py).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import '../services/network_retry.dart';
import '../services/request_diagnostics.dart';

class XmlyLoginError extends XmlyException {
  XmlyLoginError(
    super.code,
    super.message, {
    super.retryAfter,
    this.upstreamCode,
    super.definitive,
  });
  final int? upstreamCode;
}

class _Pending {
  _Pending(this.id, this.encryptedMobile, this.deviceId, this.expires);
  final String id, encryptedMobile, deviceId;
  final Duration expires;
  int attempts = 0;
}

/// One memory-only SMS challenge. Returned credentials still require Lite
/// queryQuota validation through AccountService.commit before becoming active.
class XmlyLogin {
  XmlyLogin({
    Dio? dio,
    DateTime Function()? clock,
    Duration Function()? monotonic,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    _monotonic = monotonic ?? (() => watch.elapsed);
  }

  static const captchaId = '3723312ce42a04b5c0b40e605a882037';
  static const _fields = [
    'captcha_id',
    'lot_number',
    'pass_token',
    'gen_time',
    'captcha_output',
  ];
  static const _salt =
      'MOBILE-V1-PRODUCT-7D74899B338B4F348E2383970CC09991E8E8D8F2BC744EF0BEE94D76D718C089';
  static const _modulus =
      '9585a4773abeecb949701d49762f2dfab9599ba19dfe1e1a2fa200e32e0444f426da528912'
      'd9ea8669515f6f1014c454e1343b97abf7c10fe49d520a6999c66b230e0730c3f8'
      '02d136a892501ff2b13d699b5c7ecbbfef428ac36d3d83a5bd627f18746a7fdc77'
      '4c12a38de2760a3b95c653c10d7eb7f84722976251f649556b';
  final Dio _dio;
  final DateTime Function() _clock;
  late final Duration Function() _monotonic;
  final _lock = Lock();
  final _deviceId = const Uuid().v4();
  final Map<String, Duration> _lastSms = {}, _usedLots = {};
  _Pending? _pending;
  int _generation = 0;
  bool _closed = false;
  Completer<void> _cleared = Completer<void>();

  Map<String, dynamic> config() => {
    'captcha_id': captchaId,
    'biz': 1,
    'captcha_fields': [..._fields]..sort(),
  };

  static String signature(Map<String, String> values) {
    final keys = values.keys.toList()..sort();
    final canonical = keys
        .map((key) => '$key=${values[key]}&')
        .join()
        .toUpperCase();
    return sha1.convert(utf8.encode(canonical + _salt)).toString();
  }

  static bool _sameChallenge(String left, String right) {
    var difference = left.length ^ right.length;
    for (var index = 0; index < max(left.length, right.length); index++) {
      difference |=
          (index < left.length ? left.codeUnitAt(index) : 0) ^
          (index < right.length ? right.codeUnitAt(index) : 0);
    }
    return difference == 0;
  }

  // RSA/ECB/PKCS1Padding using the original 1024-bit public modulus. Nonzero
  // padding is generated afresh; no phone number or challenge is persisted.
  static String _encryptMobile(String mobile) {
    final message = utf8.encode(mobile);
    final random = Random.secure();
    final block = <int>[0, 2];
    while (block.length < 127 - message.length) {
      block.add(random.nextInt(255) + 1);
    }
    block.addAll([0, ...message]);
    var value = BigInt.zero;
    for (final byte in block) {
      value = (value << 8) | BigInt.from(byte);
    }
    final result = value.modPow(
      BigInt.from(65537),
      BigInt.parse(_modulus, radix: 16),
    );
    final hex = result.toRadixString(16).padLeft(256, '0');
    return base64Encode(
      List<int>.generate(
        128,
        (index) =>
            int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
      ),
    );
  }

  void clear() {
    _generation++;
    _pending = null;
    _cleared.complete();
    _cleared = Completer<void>();
  }

  void close() {
    clear();
    _closed = true;
    _dio.close(force: true);
  }

  static void _check(Map<String, dynamic> result, String operation) {
    final raw = result['ret'];
    if ((raw is! int && raw is! String) ||
        !RegExp(r'^-?[0-9]{1,9}$').hasMatch('$raw')) {
      throw XmlyLoginError('invalid_response', '登录响应状态无效');
    }
    final ret = int.parse('$raw');
    if (ret != 0) {
      throw XmlyLoginError(
        '${operation}_rejected',
        '登录请求未成功（错误码 $ret），请重新验证',
        upstreamCode: ret,
        definitive: true,
      );
    }
  }

  Future<T> _request<T>(
    String method,
    String path,
    String deviceId,
    T Function(Map<String, dynamic>) decode, [
    Map<String, String>? values,
  ]) async {
    final generation = _generation;
    final cleared = _cleared.future;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_closed) throw XmlyLoginError('closed', '登录窗口已关闭');
      if (generation != _generation) {
        throw XmlyLoginError('challenge_invalid', '短信验证已取消');
      }
      final cancel = CancelToken();
      var timedOut = false;
      final timer = Timer(const Duration(seconds: 25), () {
        timedOut = true;
        cancel.cancel();
      });
      final diagnostic = RequestDiagnostic(
        account: '短信登录',
        method: method,
        url: 'https://passport.ximalaya.com/$path',
      );
      final bytes = <int>[];
      diagnostic.responseBytes = () => bytes;
      final headers = <String, dynamic>{
        'User-Agent': 'ting_9.5.1(M2102J2SC,Android31)',
        'Cookie':
            '1&_device=android&$deviceId&9.5.1;channel=and-d10;'
            'impl=com.ximalaya.ting.android;qimei36=;osversion=31;'
            'device_model=M2102J2SC;XIM=;net-mode=WIFI;manufacturer=Xiaomi;',
        'Accept': 'application/json, text/plain, */*',
        'Cookie2': r'$version=1',
        'Content-Type': 'application/json',
      };
      diagnostic.requestHeaders = {..._dio.options.headers, ...headers};
      diagnostic.requestBody = values == null ? '(无请求体)' : jsonEncode(values);
      var retryable = false;
      String? retryHeader;
      try {
        final response = await _dio.request<ResponseBody>(
          diagnostic.url,
          data: values,
          cancelToken: cancel,
          options: Options(
            method: method,
            responseType: ResponseType.stream,
            followRedirects: false,
            maxRedirects: 0,
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 25),
            validateStatus: (_) => true,
            headers: headers,
          ),
        );
        diagnostic.url = response.requestOptions.uri.toString();
        diagnostic.requestHeaders = Map.of(response.requestOptions.headers);
        diagnostic.status = response.statusCode;
        diagnostic.responseHeaders = Map.of(response.headers.map);
        retryHeader = response.headers.value('retry-after');
        retryable =
            response.statusCode == 429 ||
            (method == 'GET' && retryableStatus(response.statusCode));
        final body = response.data;
        if (body == null) throw const FormatException();
        final size = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (size != null && size > 512 * 1024) {
          diagnostic.completeness = '响应超过 512 KiB 安全限制，未读取响应体';
          cancel.cancel();
          throw XmlyLoginError('response_too_large', '登录响应超出大小限制');
        }
        diagnostic.completeness = '响应体接收中；若传输中断，仅保留已接收字节';
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > 512 * 1024) {
            bytes.addAll(chunk.take(512 * 1024 - bytes.length));
            diagnostic.completeness = '响应超过 512 KiB 安全限制，响应体已截断';
            cancel.cancel();
            throw XmlyLoginError('response_too_large', '登录响应超出大小限制');
          }
          bytes.addAll(chunk);
        }
        diagnostic.completeness = '完整响应体';
        if (response.statusCode != 200) {
          throw XmlyLoginError(
            'http_error',
            '登录服务请求失败（HTTP ${response.statusCode}）',
            retryAfter: retryHeader == null
                ? null
                : retryDelay(attempt, retryHeader),
          );
        }
        final result = jsonDecode(utf8.decode(bytes));
        if (result is! Map<String, dynamic>) throw const FormatException();
        return decode(result);
      } catch (error) {
        if (error is DioException) {
          diagnostic.url = error.requestOptions.uri.toString();
          diagnostic.requestHeaders = Map.of(error.requestOptions.headers);
          diagnostic.status ??= error.response?.statusCode;
          if (error.response != null) {
            diagnostic.responseHeaders = Map.of(error.response!.headers.map);
          }
        }
        final transportFailure = retryableTransport(error) || timedOut;
        if (error is! XmlyException && error is! FormatException) {
          diagnostic.transportError = '$error';
        }
        final failure = error is XmlyException
            ? error
            : diagnostic.status != null && diagnostic.status != 200
            ? XmlyLoginError(
                'http_error',
                '登录服务请求失败（HTTP ${diagnostic.status}）',
                retryAfter: retryHeader == null
                    ? null
                    : retryDelay(attempt, retryHeader),
              )
            : error is FormatException
            ? XmlyLoginError('invalid_response', '登录服务返回无效数据')
            : XmlyLoginError('network_error', '登录连接失败或超时，请勿自动重发短信');
        await diagnostic.fail(error);
        // A rejected 429 is safe to replay. An unknown POST outcome is not:
        // it may already have sent an SMS or consumed the captcha/code/key.
        retryable =
            ((retryable || diagnostic.status == 429) &&
                failure.code == 'http_error') ||
            (failure is XmlyLoginError &&
                failure.definitive &&
                failure.upstreamCode == 429) ||
            (method == 'GET' && transportFailure);
        if (!retryable || attempt == 4) throw failure;
      } finally {
        timer.cancel();
      }
      try {
        await waitToRetry(retryDelay(attempt, retryHeader), closed: cleared);
      } on StateError {
        if (_closed) throw XmlyLoginError('closed', '登录窗口已关闭');
        throw XmlyLoginError('challenge_invalid', '短信验证已取消');
      }
    }
    throw XmlyLoginError('network_error', '登录连接失败或超时，请勿自动重发短信');
  }

  Future<String> _nonce(String deviceId) => _request(
    'GET',
    'mobile/nonce/${_clock().millisecondsSinceEpoch}',
    deviceId,
    (result) {
      if (result.containsKey('ret')) _check(result, 'nonce');
      final nonce = result['nonce'];
      if (nonce is! String || nonce.isEmpty || nonce.length > 1024) {
        throw XmlyLoginError('invalid_response', '登录响应缺少有效 nonce');
      }
      return nonce;
    },
  );

  Future<T> _post<T>(
    String path,
    String device,
    Map<String, String> values,
    String operation,
    T Function(Map<String, dynamic>) decode,
  ) => _request('POST', path, device, (result) {
    _check(result, operation);
    return decode(result);
  }, {...values, 'signature': signature(values)});

  void _active(_Pending pending) {
    if (!identical(_pending, pending)) {
      throw XmlyLoginError('challenge_invalid', '短信验证已取消或被替换');
    }
    if (_monotonic() >= pending.expires) {
      _pending = null;
      throw XmlyLoginError('challenge_expired', '短信验证已过期，请重新发送');
    }
  }

  void _prune(Duration now) {
    for (final pair in [(_lastSms, 180), (_usedLots, 600)]) {
      pair.$1.removeWhere(
        (_, stamp) => now - stamp >= Duration(seconds: pair.$2),
      );
      while (pair.$1.length >= 128) {
        pair.$1.remove(pair.$1.keys.first);
      }
    }
    if (_pending != null && now >= _pending!.expires) _pending = null;
  }

  Future<Map<String, dynamic>> sendSms(
    String mobile,
    Map<String, dynamic> geetest, {
    String deviceId = '',
  }) {
    if (!RegExp(r'^\+?[0-9]{6,18}$').hasMatch(mobile)) {
      throw XmlyLoginError('invalid_mobile', '手机号格式无效');
    }
    if (_fields.any(
          (key) =>
              geetest[key] is! String ||
              !RegExp(r'^[\x21-\x7e]{1,8192}$')
                  .hasMatch(geetest[key] as String),
        ) ||
        (geetest['captcha_id'] as String).toLowerCase() != captchaId) {
      throw XmlyLoginError('invalid_captcha', '安全验证字段无效');
    }
    if (deviceId.length > 128 ||
        deviceId.codeUnits.any(
          (c) => c <= 32 || c >= 127 || ';&,"\\'.codeUnits.contains(c),
        )) {
      throw XmlyLoginError('invalid_device', '登录设备标识无效');
    }
    final captcha = {for (final key in _fields) key: geetest[key] as String};
    final lot = sha256.convert(utf8.encode(captcha['lot_number']!)).toString();
    final phone = sha256
        .convert(utf8.encode(mobile.replaceFirst(RegExp(r'^\+'), '')))
        .toString();
    final generation = _generation;
    return _lock.synchronized(() async {
      if (generation != _generation) {
        throw XmlyLoginError('challenge_invalid', '短信验证已取消');
      }
      final now = _monotonic();
      if (_usedLots.containsKey(lot) &&
          now - _usedLots[lot]! < const Duration(seconds: 600)) {
        throw XmlyLoginError('captcha_reused', '本次安全验证已使用，请重新验证');
      }
      final last = _lastSms[phone];
      if (last != null && now - last < const Duration(seconds: 180)) {
        final seconds = ((180000000 - (now - last).inMicroseconds) / 1000000)
            .ceil();
        throw XmlyLoginError(
          'sms_cooldown',
          '请在 $seconds 秒后重新发送短信',
          retryAfter: Duration(seconds: seconds),
        );
      }
      _prune(now);
      _usedLots[lot] = now;
      _lastSms[phone] = now;
      _pending = null;
      final device = deviceId.isEmpty ? _deviceId : deviceId;
      final encrypted = _encryptMobile(mobile);
      final nonce = await _nonce(device);
      if (generation != _generation) {
        throw XmlyLoginError('challenge_invalid', '短信验证已取消');
      }
      await _post<void>(
        'mobile/sms/v3/send',
        device,
        {
          'mobile': encrypted,
          'sendType': '1',
          'biz': '1',
          'nonce': nonce,
          'fdsOtp': jsonEncode(captcha),
        },
        'sms_send',
        (_) {},
      );
      if (generation != _generation) {
        throw XmlyLoginError('challenge_invalid', '短信验证已取消');
      }
      final random = Random.secure();
      final id = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      _pending = _Pending(
        id,
        encrypted,
        device,
        _monotonic() + const Duration(seconds: 600),
      );
      return {
        'challenge_id': id,
        'retry_after_seconds': 180,
        'expires_in_seconds': 600,
      };
    });
  }

  Future<Credentials> verifySms(String challengeId, String code) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(challengeId)) {
      throw XmlyLoginError('challenge_invalid', '需要有效的短信验证请求');
    }
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(code)) {
      throw XmlyLoginError('invalid_code', '短信验证码必须为 4 至 8 位数字');
    }
    return _lock.synchronized(() async {
      final pending = _pending;
      if (pending == null || !_sameChallenge(pending.id, challengeId)) {
        throw XmlyLoginError('challenge_invalid', '短信验证不存在或已完成');
      }
      _active(pending);
      pending.attempts++;
      try {
        var nonce = await _nonce(pending.deviceId);
        _active(pending);
        final key = await _post<String>(
          'mobile/sms/v2/verify',
          pending.deviceId,
          {'mobile': pending.encryptedMobile, 'code': code, 'nonce': nonce},
          'sms_verify',
          (verified) {
            final primaryKey = verified['bizKey'];
            final key =
                primaryKey == null ||
                    primaryKey == '' ||
                    primaryKey == false ||
                    primaryKey == 0
                ? verified['smsKey']
                : primaryKey;
            if (key is! String || key.isEmpty || key.length > 8192) {
              throw XmlyLoginError('invalid_response', '登录响应缺少有效短信密钥');
            }
            return key;
          },
        );
        _active(pending);
        nonce = await _nonce(pending.deviceId);
        _active(pending);
        final credentials = await _post<Credentials>(
          'mobile/login/quick/v2',
          pending.deviceId,
          {'mobile': pending.encryptedMobile, 'smsKey': key, 'nonce': nonce},
          'quick_login',
          (login) {
            final nested = login['data'] is Map
                ? login['data'] as Map
                : const {};
            final rawUid = login['uid'], rawToken = login['token'];
            final uid =
                rawUid == null || rawUid == '' || rawUid == false || rawUid == 0
                ? nested['uid']
                : rawUid;
            final token =
                rawToken == null ||
                    rawToken == '' ||
                    rawToken == false ||
                    rawToken == 0
                ? nested['token']
                : rawToken;
            if ((uid is! String && uid is! int) ||
                !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch('$uid') ||
                token is! String ||
                !RegExp(r'^[A-Za-z0-9._~+/=\-]{1,8192}$').hasMatch(token)) {
              throw XmlyLoginError('invalid_response', '登录响应缺少有效账号凭据');
            }
            return Credentials(
              token: '$uid&$token',
              deviceId: pending.deviceId,
            );
          },
        );
        _active(pending);
        _pending = null;
        return credentials;
      } finally {
        if (pending.attempts >= 5 && identical(_pending, pending))
          _pending = null;
      }
    });
  }
}
