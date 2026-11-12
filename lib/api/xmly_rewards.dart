// SPDX-License-Identifier: AGPL-3.0-or-later
// Port of xmly/rewards.py. No advertisement completion fields are fabricated.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import 'xmly_client.dart';
import 'xmly_crypto.dart';

class XmlyRewards {
  XmlyRewards(this.client, {this.automaticEnabled = false,
      DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final XmlyClient client;
  final DateTime Function() _clock;
  final _lock = Lock();
  bool automaticEnabled;
  String lastError = '';
  static const _salt = '0ab3443b71834b33be675af744d76ef0aaa74cd2b60c4b67';
  static const _path = '/lite-earn/ting/welfare/';

  String _uid() {
    final credentials = client.credentials;
    if (!client.accountAvailable || credentials == null) {
      throw XmlyException('login_expired', '领取或查询听时需要有效的登录态');
    }
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(credentials.uid)) {
      throw XmlyException('auth_required', '登录态缺少有效账号标识');
    }
    return credentials.uid;
  }

  static Map<String, dynamic> _result(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! Map<String, dynamic> || data['success'] is! bool) {
      throw XmlyException('invalid_response', '福利响应缺少明确结果');
    }
    if (data['success'] != true) {
      throw XmlyException('reward_rejected', '福利请求未成功，请在官方 App 检查',
          definitive: true);
    }
    return data;
  }

  Future<Map<String, dynamic>> tasks() async {
    _uid();
    final response = await client.request('GET', XmlyClient.welfare,
        '${_path}queryVipDurationTask/ts-${_clock().millisecondsSinceEpoch}');
    return {'data': _result(response)};
  }

  Map<String, dynamic> _payload(Map<String, dynamic> value) {
    final fields = <String, dynamic>{};
    for (final key in ['adId', 'adResponseId', 'isUnisdk', 'ecpm', 'verifyStr',
        'isSecondPhaseCompleted', 'sourceName']) {
      if (value.containsKey(key) && (key == 'sourceName' || value[key] != null) &&
          (key != 'verifyStr' || (value[key] != null && value[key] != '' && value[key] != false))) {
        final item = value[key];
        if (item != null && item is! String && item is! num && item is! bool) {
          throw ArgumentError('福利请求字段格式无效');
        }
        if (item is String && item.length > 8192) throw ArgumentError('福利请求字段过长');
        if (item is num && !item.isFinite) throw ArgumentError('福利请求字段格式无效');
        fields[key] = item;
      }
    }
    final uid = _uid();
    final request = const Uuid().v4();
    final timestamp = _clock().millisecondsSinceEpoch;
    final parts = [request, uid, '$timestamp'];
    if (fields['isSecondPhaseCompleted'] != null) {
      parts.add('${fields['isSecondPhaseCompleted']}');
    }
    final signature = md5.convert(utf8.encode('${parts.join('&')}&$_salt')).toString();
    return {
      ...fields, 'requestId': request, 'uid': int.parse(uid), 'ts': timestamp,
      'signature': signature,
      'ticket': XmlyCrypto.freshTicket(client.credentials!,
          attributes: 'b=lite&s=lite_time_reward&u=$uid'),
    };
  }

  Future<Map<String, dynamic>> claim(Map<String, dynamic> value) =>
      _lock.synchronized(() => client.withBalanceChange(() => _claim(value)));

  Future<Map<String, dynamic>> _claim(Map<String, dynamic> value) async {
    final payload = _payload(value);
    client.invalidateQuota();
    // Empty business fields are accepted by the original official protocol;
    // generated identity/signature/ticket are still mandatory. Never replay POST.
    final response = await client.request('POST', XmlyClient.welfare,
        '${_path}rewardDuration/ts-${payload['ts']}', data: payload);
    return {'data': _result(response)};
  }

  /// Automatic issuance is opt-in. Read-only quota/login/resolve never invoke it.
  /// An error returns the last verified balance, and never retries that claim.
  Future<Quota> refresh({bool Function()? shouldContinue}) => _lock.synchronized(() async {
    bool allowed() => automaticEnabled && (shouldContinue?.call() ?? true);
    var quota = await client.queryQuota();
    lastError = '';
    if (!allowed() || quota.remainingSeconds >= 7200) return quota;
    final identity = client.cacheIdentity;
    // ponytail: cap each explicit refresh at 64 successful claims; require a
    // later refresh rather than letting a pathological 1-second reward loop run.
    for (var count = 0; count < 64 && allowed() &&
        quota.remainingSeconds < 14400; count++) {
      if (identity != client.cacheIdentity || !client.accountAvailable) break;
      final previous = quota.remainingSeconds;
      try {
        final claimed = await client.withBalanceChange(() async {
          // Consent may be revoked while a debit holds the balance lock.
          if (!allowed() || identity != client.cacheIdentity ||
              !client.accountAvailable) return false;
          await _claim({});
          return true;
        });
        if (!claimed) break;
        if (identity != client.cacheIdentity || !client.accountAvailable) break;
        quota = await client.queryQuota();
      } on Exception {
        lastError = '领取听时未完成，已停止自动领取';
        break;
      }
      if (quota.remainingSeconds <= previous) break;
    }
    return quota;
  });
}
