// Protocol constants ported from xmly/client.py (AGPL-3.0-or-later).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as aes;

import '../models/xmly_models.dart';

class XmlyCrypto {
  static final List<int> playKey = List.unmodifiable(
    _hex('bf56792c145e706d1dd26c04feba6a8c'),
  );
  static final List<int> durationKey = List.unmodifiable(
    ascii.encode('jkq1hsksjxg4mf2y'),
  );
  static final _ticketMaterial = _hex(
    'b0b1a8ac34e66efa95c7f4157cf8b6ba33dfc2075e41fb964f2e12dcaa',
  );
  static const _activityMaterial = 'q35435432sadks2i3546p2ndkcaqiwurhqfebt4kn';
  static List<int> _hex(String value) => [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];
  static aes.Encrypter _cipher(List<int> key) => aes.Encrypter(
    aes.AES(
      aes.Key(Uint8List.fromList(key)),
      mode: aes.AESMode.ecb,
      padding: 'PKCS7',
    ),
  );
  static String encrypt(Map<String, dynamic> value, List<int> key) {
    final raw = utf8.encode(jsonEncode(value));
    if (raw.length > 2 * 1024 * 1024)
      throw const XmlyException('invalid_encoding', '协议数据过大');
    final encoded = base64Url.encode(_cipher(key).encryptBytes(raw).bytes);
    return '${[for (var i = 0; i < encoded.length; i += 76) encoded.substring(i, min(i + 76, encoded.length))].join('\n')}\n';
  }

  static String decrypt(String value, List<int> key) {
    try {
      if (value.length > 4 * 1024 * 1024) throw const FormatException();
      final text = value.replaceAll('\r', '').replaceAll('\n', '');
      if (!RegExp(r'^[A-Za-z0-9+/_\-]*={0,2}$').hasMatch(text))
        throw const FormatException();
      final bytes = base64.decode(base64.normalize(text));
      if (bytes.isEmpty || bytes.length % 16 != 0)
        throw const FormatException();
      return utf8.decode(
        _cipher(key).decryptBytes(aes.Encrypted(bytes)),
        allowMalformed: false,
      );
    } catch (_) {
      throw const XmlyException('invalid_encoding', '喜马拉雅播放协议解码失败，可能需要更新客户端协议');
    }
  }

  // Lite EncryptUtil.decryptByKey2 / decryptRc4ByPublicKeyN. Unlike the
  // web protocol, mobile fileId is AES encrypted and seed is not used.
  static final _paidFileKey = List<int>.unmodifiable(
    _hex('6130516e6a54614139596963526a3748'),
  );
  static final _paidEpKey = List<int>.unmodifiable(
    ascii.encode('MZe3GV3txvMOKb1p'),
  );

  /// Reconstruct the official mobile paid-media URL; uid is the listening
  /// account, not the uploader uid in the paid metadata response.
  static String paidMediaUrl(
    Map<String, dynamic> metadata, {
    required String uid,
  }) {
    try {
      final fileId = metadata['fileId'], ep = metadata['ep'];
      final domain = metadata['domain'], version = metadata['apiVersion'];
      final duration = metadata['duration'];
      if (fileId is! String ||
          ep is! String ||
          domain is! String ||
          version is! String ||
          fileId.length > 16384 ||
          ep.length > 16384 ||
          domain.length > 1024 ||
          !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version) ||
          duration is! num ||
          !duration.isFinite ||
          duration <= 0 ||
          duration > 2147483647 ||
          duration != duration.toInt()) {
        throw const FormatException();
      }
      final origin = Uri.parse(domain);
      if (!['http', 'https'].contains(origin.scheme) ||
          origin.host.isEmpty ||
          origin.userInfo.isNotEmpty ||
          origin.hasQuery ||
          origin.hasFragment ||
          (origin.path.isNotEmpty && origin.path != '/') ||
          (origin.port != 80 && origin.port != 443)) {
        throw const FormatException();
      }
      final filename = decrypt(fileId, _paidFileKey).trim();
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9/_.-]*\.(?:m4a|mp3)$')
              .hasMatch(filename) ||
          filename
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..')) {
        throw const FormatException();
      }
      if (!RegExp(r'^[A-Za-z0-9+/_\-]*={0,2}$').hasMatch(ep))
        throw const FormatException();
      final bytes = base64.decode(base64.normalize(ep));
      if (bytes.isEmpty) throw const FormatException();
      final state = Uint8List(256);
      for (var i = 0; i < 256; i++) state[i] = i;
      var j = 0;
      for (var i = 0; i < 256; i++) {
        j = (j + state[i] + _paidEpKey[i % _paidEpKey.length]) & 255;
        final swap = state[i];
        state[i] = state[j];
        state[j] = swap;
      }
      var i = 0;
      j = 0;
      for (var n = 0; n < bytes.length; n++) {
        i = (i + 1) & 255;
        j = (j + state[i]) & 255;
        final swap = state[i];
        state[i] = state[j];
        state[j] = swap;
        bytes[n] ^= state[(state[i] + state[j]) & 255];
      }
      final parts = utf8.decode(bytes, allowMalformed: false).trim().split('-');
      if (parts.length != 4 ||
          parts.any((part) => part.isEmpty) ||
          !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(parts[1]) ||
          !RegExp(r'^[0-9]{10,20}$').hasMatch(parts[3])) {
        throw const FormatException();
      }
      return origin
          .replace(
            path: '/download/$version/$filename',
            queryParameters: {
              'buy_key': parts[0],
              'duration': '${duration.toInt()}',
              'sign': parts[1],
              'timestamp': parts[3],
              'token': parts[2],
              'uid': xmlyIdentifier(uid),
              'is_charge': 'true',
            },
          )
          .toString();
    } catch (_) {
      throw const XmlyException('invalid_paid_media', '付费音频协议无效，可能需要更新客户端协议');
    }
  }

  static String activitySignature(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final canonical =
        '${keys.map((key) => '$key=${params[key]}&').join()}$_activityMaterial';
    return md5
        .convert(
          utf8
              .encode(canonical)
              .map((byte) => byte >= 65 && byte <= 90 ? byte + 32 : byte)
              .toList(),
        )
        .toString();
  }

  static String freshTicket(Credentials credentials, {String? attributes}) {
    final identity = md5
        .convert(utf8.encode('${credentials.uid}|${credentials.deviceId}'))
        .bytes;
    final random = Random.secure();
    final uuid = List<int>.generate(16, (_) => random.nextInt(256));
    uuid[6] = (uuid[6] & 15) | 64;
    uuid[8] = (uuid[8] & 63) | 128;
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <int>[
      (seconds >> 24) & 255,
      (seconds >> 16) & 255,
      (seconds >> 8) & 255,
      seconds & 255,
      ...identity,
      for (var i = 0; i < 16; i++) uuid[i] ^ identity[i],
    ];
    final suffix = utf8.encode(
      'com.ximalaya.ting.lite!1.3.24!3.4.10.3!${attributes ?? 'b=lite&s=lite_track_play_url&&u=${credentials.uid}'}',
    );
    final digest = sha256.convert([
      ...payload,
      ...ascii.encode('TAC'),
      ..._ticketMaterial,
      ...suffix,
    ]).bytes;
    return 'TAC${base64Url.encode([...payload, ...digest, ...suffix]).replaceAll('=', '')}';
  }
}
