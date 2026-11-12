import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../models/xmly_models.dart';
import '../services/app_runtime.dart';
import '../services/usage_ledger.dart';

class UsagePage extends StatefulWidget {
  const UsagePage({required this.runtime, required this.ledger, super.key});
  final AppRuntime runtime;
  final UsageLedger ledger;
  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  String? _error;
  bool _busy = false;
  Map? _accounts;

  @override
  void initState() {
    super.initState();
    _accounts = widget.runtime.storage.state['accounts'] as Map;
    widget.runtime.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant UsagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_changed);
      _accounts = widget.runtime.storage.state['accounts'] as Map;
      widget.runtime.addListener(_changed);
    }
  }

  void _changed() {
    final accounts = widget.runtime.storage.state['accounts'] as Map;
    if (!mounted || identical(accounts, _accounts)) return;
    setState(() => _accounts = accounts);
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_changed);
    super.dispose();
  }

  Future<void> _reconcile(
    String identity,
    String operationId,
    int seconds,
    Object? before,
    Object? after,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Quota? quota;
      try {
        quota = await widget.ledger.queryQuota(identity);
      } catch (_) {
        /* Official App remains the authority for human reconciliation. */
      }
      if (!mounted) return;
      final debited = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            '核对扣时',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '请求 $seconds 秒\n扣前：${before ?? "未知"}\n扣后：${after ?? "未知"}\n当前余额：${quota?.remainingSeconds == null ? "无法查询，请在官方 App 核对" : "${quota!.remainingSeconds} 秒"}',
                ),
                const SizedBox(height: 12),
                const Text('请先在官方 App 核对。其他设备也可能改变余额，不能只凭余额差判断。'),
                const SizedBox(height: 12),
                const Text('确认已扣后可继续原任务；确认未扣只允许下次明确操作重新提交，不会立即重发。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('确认未扣'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认已扣'),
            ),
          ],
        ),
      );
      if (debited == null) return;
      await widget.runtime.accounts.runWithAccount(
        identity,
        (_) =>
            widget.ledger.reconcile(identity, operationId, wasDebited: debited),
      );
      widget.runtime.changed();
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error is XmlyException ? error.message : '核对未完成，原记录已保留';
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = widget.runtime.storage.state['accounts'] as Map;
    return Scaffold(
      appBar: AppBar(title: const AdaptiveText('听时记录')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
            ),
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              for (final entry in accounts.entries) ...[
                AdaptiveText(
                  '账号 ${(entry.value as Map)['uid'] ?? ''}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final receipt
                    in widget.ledger.receipts(entry.key as String).reversed)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: AdaptiveText(
                                  '${receipt.trackId} · ${receipt.seconds} 秒',
                                ),
                              ),
                              if (receipt.state == DebitState.uncertain ||
                                  receipt.state == DebitState.submitting)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _reconcile(
                                          receipt.accountIdentity,
                                          receipt.operationId,
                                          receipt.seconds,
                                          receipt.balanceBefore,
                                          receipt.balanceAfter,
                                        ),
                                  child: const Text('核对'),
                                ),
                            ],
                          ),
                          Text(
                            '${_state(receipt.state)}${receipt.historical ? " · 历史记录" : ""}\n${receipt.createdAt.toLocal()}\n余额 ${receipt.balanceBefore} → ${receipt.balanceAfter ?? "未知"}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                if ((entry.value as Map)['ledger'] case final Map ledger)
                  if (ledger['usage_pending'] case final Map pending)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AdaptiveText(
                              '在线收听 · ${pending['seconds'] ?? pending['duration'] ?? 0} 秒',
                            ),
                            const Text('扣时结果待核对'),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _reconcile(
                                        entry.key as String,
                                        pending['operationId'] as String,
                                        (pending['seconds'] ??
                                                pending['duration'] ??
                                                0)
                                            as int,
                                        pending['balanceBefore'],
                                        pending['balanceAfter'],
                                      ),
                                child: const Text('核对'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
              ],
              if (accounts.isEmpty) const Center(child: Text('暂无听时记录')),
            ],
          ),
        ),
      ),
    );
  }
}

String _state(DebitState state) => switch (state) {
  DebitState.prepared => '未提交',
  DebitState.submitting => '结果待核对',
  DebitState.confirmed => '已确认',
  DebitState.uncertain => '结果未知',
  DebitState.rejected => '未扣时',
};
