import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_login.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../api/xmly_rewards.dart';
import '../models/xmly_models.dart';
import '../services/account_service.dart';
import '../storage/app_storage.dart';
import 'geetest_dialog.dart';

// Errors at this surface are deliberately mapped by code, never interpolated
// from raw inputs, transport exceptions, or upstream response messages.
String _accountError(Object error) {
  final code = error is XmlyException
      ? error.code
      : error is AccountException
      ? error.code
      : '';
  if (code == 'rate_limited' || code == 'sms_cooldown') {
    final retry = error is XmlyException ? error.retryAfter : null;
    return retry != null && retry.inSeconds > 0
        ? '请求过于频繁，请在 ${retry.inSeconds} 秒后重试。'
        : '请求过于频繁，请稍后重试。';
  }
  return switch (code) {
    'invalid_credentials' => '登录信息格式不正确，请检查令牌和原设备 ID。',
    'login_expired' ||
    'login_required' ||
    'auth_required' => '登录信息无效或已过期，请重新登录。',
    'invalid_mobile' => '请输入有效手机号（6–18 位数字，可含国际区号 +）。',
    'invalid_code' => '短信验证码须为 4–8 位数字。',
    'sms_verify_rejected' => '验证码未通过，请检查后重试；最多尝试 5 次。',
    'sms_send_rejected' => '短信发送未成功，请在官方 App 检查后再试。',
    'quick_login_rejected' => '登录未成功，请重新进行短信验证。',
    'invalid_captcha' || 'captcha_reused' => '安全验证无效或已使用，请重新验证。',
    'challenge_expired' || 'challenge_invalid' => '短信验证已过期或失效，请重新发送。',
    'network' || 'network_error' || 'http_error' => '连接失败或超时，请检查网络。短信不会自动重发。',
    'uncertain' => '请求结果未知，请先在官方 App 核对，不要重复领取。',
    'reward_rejected' => '领取未成功，请在官方 App 检查。',
    'reward_paused' => '领取已暂停，请先在官方 App 核对，再选择恢复领取。',
    'unsettled' || 'usage_uncertain' => '还有未结算或结果未知的扣时，请先核对原账号。',
    'integration_required' => '暂时无法安全切换账号，原账号已保留。',
    'credential_write_failed' => '安全凭据保存失败，原账号已保留。',
    'credential_mismatch' => '请导入该账号的 Cookie，并保留原设备 ID；其他账号不能恢复此记录。',
    'credential_read_failed' ||
    'credential_missing' ||
    'credential_invalid' => '无法读取登录信息，请重新导入原账号。',
    'paused' => '账号正在切换，请稍后重试。',
    _ => '操作未完成，原资料已保留。请检查网络或稍后重试。',
  };
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
}) => showConfirmationDialog(
  context,
  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
  content: SingleChildScrollView(child: Text(message)),
  confirmLabel: action,
);

class AccountPage extends StatefulWidget {
  const AccountPage({
    required this.storage,
    required this.accounts,
    this.onChanged,
    this.updates,
    super.key,
  });

  final AppStorage storage;
  final AccountService accounts;
  final VoidCallback? onChanged;
  final Listenable? updates;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _login = XmlyLogin();
  bool _busy = false;
  String? _error;
  late String _viewKey;

  bool get _autoClaim =>
      (widget.storage.state['settings'] as Map)['autoClaim'] == true;

  String _accountViewKey() {
    final records = widget.storage.state['accounts'] as Map;
    return jsonEncode([
      widget.accounts.primaryAccountId,
      widget.accounts.activeClient?.identity,
      widget.accounts.accountIds,
      _autoClaim,
      for (final identity in widget.accounts.accountIds)
        [
          identity,
          if (records[identity] case final Map record)
            for (final field in ['uid', 'deviceHint', 'rewardPaused', 'quota'])
              record[field],
        ],
    ]);
  }

  @override
  void initState() {
    super.initState();
    _viewKey = _accountViewKey();
    widget.updates?.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant AccountPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates?.removeListener(_changed);
      widget.updates?.addListener(_changed);
    }
    _viewKey = _accountViewKey();
  }

  void _changed() {
    if (!mounted) return;
    final key = _accountViewKey();
    if (key != _viewKey) setState(() => _viewKey = key);
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_changed);
    _login.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) setState(() => _error = _accountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openImport({String? recoveryIdentity}) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CredentialDialog(
        accounts: widget.accounts,
        recoveryIdentity: recoveryIdentity,
      ),
    );
    if (!mounted || changed != true) return;
    widget.onChanged?.call();
    setState(() => _error = null);
  }

  Future<void> _openSms() async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SmsLoginDialog(
        accounts: widget.accounts,
        dataDirectory: widget.storage.directory,
        login: _login,
      ),
    );
    if (!mounted || changed != true) return;
    widget.onChanged?.call();
    setState(() => _error = null);
  }

  Future<void> _storeQuota(String identity, Quota quota) =>
      widget.storage.transaction((state) {
        final record = (state['accounts'] as Map)[identity];
        if (record is Map && record['credentialRef'] is String)
          record['quota'] = quota.toJson();
      });

  Future<void> _quota(String identity) => _run(() async {
    final quota = await widget.accounts.runWithAccount(
      identity,
      (client) => client.queryQuota(),
    );
    await _storeQuota(identity, quota);
  });

  Future<void> _claim(String identity, String uid) async {
    if (!await _confirm(
          context,
          '领取听时',
          '为账号 $uid 发送一次领取请求？领取结果以官方 App 为准。',
          action: '领取一次',
        ) ||
        !mounted)
      return;
    await _run(() async {
      try {
        final quota = await widget.accounts.runWithAccount(identity, (
          client,
        ) async {
          final record = (widget.storage.state['accounts'] as Map)[identity];
          if (record is Map && record['rewardPaused'] == true) {
            throw const AccountException('reward_paused', '领取已暂停');
          }
          // Manual issuance is a single request, not the automatic refill loop.
          await XmlyRewards(client).claim({});
          return client.queryQuota();
        });
        await _storeQuota(identity, quota);
      } catch (_) {
        await widget.storage.transaction((state) {
          final record = (state['accounts'] as Map)[identity];
          if (record is Map) record['rewardPaused'] = true;
        });
        rethrow;
      }
    });
  }

  Future<void> _resumeRewards(String identity, String uid) async {
    if (!await _confirm(
          context,
          '恢复领取',
          '请先在官方 App 核对账号 $uid 上一次领取的结果。确认已核对，并允许之后重新领取？',
          action: '已核对，恢复',
        ) ||
        !mounted)
      return;
    await _run(
      () => widget.storage.transaction((state) {
        final record = (state['accounts'] as Map)[identity];
        if (record is Map) record['rewardPaused'] = false;
      }),
    );
  }

  Future<void> _toggleAuto(bool value) async {
    if (value &&
        (!await _confirm(
              context,
              '开启自动领取',
              '对所有已登录账号生效：可用听时不足 2 小时时尝试领取至 4 小时。请求失败会暂停该账号的自动领取，需人工核对后恢复。',
              action: '开启',
            ) ||
            !mounted))
      return;
    await _run(
      () => widget.storage.transaction((state) {
        (state['settings'] as Map)['autoClaim'] = value;
      }),
    );
  }

  Future<void> _remove(String identity, String uid) async {
    if (!await _confirm(
          context,
          '移除此账号',
          '移除账号 $uid 的登录信息？已有扣时记录会保留。移除主账号时会自动选取剩余账号作为主账号。',
          action: '移除',
        ) ||
        !mounted)
      return;
    await _run(() => widget.accounts.remove(identity));
  }

  Widget _account(String identity, Map record) {
    final uid =
        record['uid'] is String &&
            RegExp(r'^[0-9]{1,20}$').hasMatch(record['uid'])
        ? record['uid'] as String
        : '未知';
    final rawHint = record['deviceHint'];
    final hint =
        rawHint is String &&
            RegExp(r'^(?:\*{4}|…[A-Za-z0-9_.:\-]{4})$').hasMatch(rawHint)
        ? rawHint
        : '****';
    final primary = widget.accounts.primaryAccountId == identity;
    final missing = widget.accounts.missingCredentialAccountIds.contains(
      identity,
    );
    final active = widget.accounts.activeClient?.identity == identity;
    final paused = record['rewardPaused'] == true;
    final quota = record['quota'];
    Quota? verified;
    try {
      if (quota is Map)
        verified = Quota.fromJson(Map<String, dynamic>.from(quota));
    } catch (_) {
      /* Show not checked. */
    }
    final remaining = verified?.remainingSeconds;
    final checked = verified?.checkedAt.toLocal();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: AdaptiveText(
                    '账号 $uid',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (primary)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Chip(label: Text('主账号')),
                  ),
                if (active && !primary)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Chip(label: Text('当前使用')),
                  ),
              ],
            ),
            AdaptiveText('设备 $hint'),
            const SizedBox(height: 8),
            if (missing) ...[
              const Text('安全凭据缺失，请重新导入原账号。已有资料、下载和扣时记录均已保留。'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _openImport(recoveryIdentity: identity),
                icon: const Icon(Icons.key),
                label: const Text('恢复此账号登录'),
              ),
            ] else ...[
              Text(
                remaining == null
                    ? '可用听时：未核验'
                    : '可用听时：${remaining ~/ 3600} 小时 ${(remaining % 3600) ~/ 60} 分 ${remaining % 60} 秒',
              ),
              if (checked != null)
                AdaptiveText(
                  '核验于 ${checked.toString().split('.').first}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (paused)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('领取已暂停，请先在官方 App 核对上一次结果。'),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _openImport(recoveryIdentity: identity),
                    icon: const Icon(Icons.key),
                    label: const Text('更新登录'),
                  ),
                  if (!primary || !active)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => widget.accounts.setPrimary(identity),
                            ),
                      child: Text(primary ? '切回主账号' : '设为主账号'),
                    ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _quota(identity),
                    child: const Text('查询听时'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || paused
                        ? null
                        : () => _claim(identity, uid),
                    child: const Text('领取一次'),
                  ),
                  if (paused)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _resumeRewards(identity, uid),
                      child: const Text('核对后恢复自动领取'),
                    ),
                  TextButton(
                    onPressed: _busy ? null : () => _remove(identity, uid),
                    child: const Text('移除'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _viewKey = _accountViewKey();
    final records = widget.storage.state['accounts'] as Map;
    final ids = [
      ...widget.accounts.accountIds,
      ...widget.accounts.missingCredentialAccountIds,
    ];
    return PopScope(
      canPop: !_busy,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
            ),
            children: [
              AdaptiveText('账号', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _openImport,
                    icon: const Icon(Icons.key),
                    label: const Text('Cookie 登录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openSms,
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('短信登录'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('主账号用于默认请求。'),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (ids.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有登录账号。'),
                  ),
                ),
              for (final id in ids)
                if (records[id] is Map) _account(id, records[id] as Map),
              const SizedBox(height: 16),
              Card(
                child: SwitchListTile(
                  title: const Text('自动领取听时'),
                  subtitle: const Text('不足 2 小时补充至 4 小时，对所有账号生效。'),
                  value: _autoClaim,
                  onChanged: _busy ? null : _toggleAuto,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({required this.accounts, this.recoveryIdentity});
  final AccountService accounts;
  final String? recoveryIdentity;
  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _cookie = TextEditingController();
  bool _primary = true, _busy = false;
  String? _error;

  @override
  void dispose() {
    _cookie.clear();
    _cookie.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final candidate = Credentials.parse(_cookie.text);
      await widget.accounts.commit(
        candidate,
        makePrimary: _primary,
        recoveryIdentity: widget.recoveryIdentity,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = _accountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.recoveryIdentity == null ? 'Cookie 登录' : '恢复原账号登录',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _cookie,
                enabled: !_busy,
                minLines: 4,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                enableIMEPersonalizedLearning: false,
                inputFormatters: [LengthLimitingTextInputFormatter(65536)],
                decoration: const InputDecoration(
                  labelText: 'Cookie',
                  hintText: '1&_token=UID&令牌; 1&_device=android&设备ID&3.4.10;',
                  helperText: '可粘贴多行 Cookie 或请求头，自动提取登录字段',
                  hintMaxLines: 2,
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.recoveryIdentity != null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('使用原账号和原设备 ID。恢复后保留主账号选择；结果未知的扣时仍需核对。'),
                )
              else
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('设为主账号'),
                  value: _primary,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _primary = value!),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('核验并保存'),
        ),
      ],
    ),
  );
}

class _SmsLoginDialog extends StatefulWidget {
  const _SmsLoginDialog({
    required this.accounts,
    required this.dataDirectory,
    required this.login,
  });
  final AccountService accounts;
  final String dataDirectory;
  final XmlyLogin login;
  @override
  State<_SmsLoginDialog> createState() => _SmsLoginDialogState();
}

class _SmsLoginDialogState extends State<_SmsLoginDialog> {
  XmlyLogin get _login => widget.login;
  final _phone = TextEditingController(), _code = TextEditingController();
  final _watch = Stopwatch()..start();
  Timer? _timer;
  Duration _resendAt = Duration.zero, _expiresAt = Duration.zero;
  String? _challenge, _error;
  Credentials? _candidate;
  bool _busy = false, _committing = false, _primary = true, _cancelled = false;

  int get _cooldown => ((_resendAt - _watch.elapsed).inMilliseconds / 1000)
      .ceil()
      .clamp(0, 180)
      .toInt();

  void _invalidate() {
    _cancelled = true;
    _login.clear();
    _challenge = null;
    _candidate = null;
    _phone.clear();
    _code.clear();
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _candidate != null) return;
      if (_challenge != null && _watch.elapsed >= _expiresAt && !_committing) {
        _login.clear();
        _challenge = null;
        _code.clear();
        _error = '短信验证已过期，请重新发送。';
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _login.clear();
    _watch.stop();
    _challenge = null;
    _candidate = null;
    _phone.clear();
    _code.clear();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _cancelled || _candidate != null || _cooldown > 0) return;
    final mobile = _phone.text.trim();
    if (!RegExp(r'^\+?[0-9]{6,18}$').hasMatch(mobile)) {
      setState(() => _error = '请输入有效手机号（6–18 位数字，可含国际区号 +）。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _login.clear();
      _challenge = null;
      _code.clear();
      final geetest = await GeetestDialog.show(
        context,
        captchaId: _login.config()['captcha_id'] as String,
        dataDirectory: widget.dataDirectory,
      );
      if (!mounted || _cancelled || geetest == null) return;
      if (!await _confirm(
            context,
            '发送短信',
            '向尾号 ${mobile.substring(mobile.length - 4)} 的手机号发送登录验证码？180 秒内不可重发。',
            action: '发送短信',
          ) ||
          !mounted ||
          _cancelled)
        return;
      // Start cooldown before a single-send request: a timeout may still deliver.
      _resendAt = _watch.elapsed + const Duration(seconds: 180);
      final response = await _login.sendSms(mobile, geetest);
      if (!mounted || _cancelled) return;
      _challenge = response['challenge_id'] as String;
      _expiresAt = _watch.elapsed + const Duration(seconds: 600);
    } catch (error) {
      if (mounted) setState(() => _error = _accountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    if (_busy || _cancelled || (_candidate == null && challenge == null))
      return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var candidate = _candidate;
      if (candidate == null) {
        candidate = await _login.verifySms(challenge!, _code.text.trim());
        if (!mounted || _cancelled) return;
        _candidate = candidate;
        _code.clear();
        _phone.clear();
        _challenge = null;
      }
      setState(() => _committing = true);
      await widget.accounts.commit(candidate, makePrimary: _primary);
      _candidate = null;
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted)
        setState(() {
          _error = _accountError(error);
          if (error is XmlyException &&
              ['challenge_invalid', 'challenge_expired'].contains(error.code)) {
            _challenge = null;
            _code.clear();
          }
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _committing = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_committing,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _invalidate();
    },
    child: AlertDialog(
      title: const Text('短信登录', maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('先完成安全验证，再由你确认发送短信。登录后仍需核验极速版可用听时；失败不替换原账号。'),
              const SizedBox(height: 16),
              if (_candidate != null)
                const Text('短信验证已完成，可直接重试登录，无需重新发送短信。')
              else ...[
                TextField(
                  controller: _phone,
                  enabled: !_busy && _challenge == null,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [LengthLimitingTextInputFormatter(19)],
                  decoration: const InputDecoration(
                    labelText: '手机号',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _busy || _cooldown > 0 ? null : _send,
                  child: Text(_cooldown > 0 ? '$_cooldown 秒后可重发' : '安全验证并发送短信'),
                ),
              ],
              if (_challenge != null) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  decoration: const InputDecoration(
                    labelText: '短信验证码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('验证码 10 分钟内有效，最多尝试 5 次。'),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('设为主账号'),
                value: _primary,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _primary = value!),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _committing
              ? null
              : () {
                  _invalidate();
                  Navigator.pop(context);
                },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || (_challenge == null && _candidate == null)
              ? null
              : _verify,
          child: const Text('验证并登录'),
        ),
      ],
    ),
  );
}
