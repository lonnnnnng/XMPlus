import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../models/xmly_models.dart';
import '../services/account_service.dart';
import '../storage/app_storage.dart';
import '../storage/config_archive.dart';
import '../storage/credential_store.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({
    required this.storage,
    required this.accounts,
    required this.secrets,
    this.onChanged,
    super.key,
  });
  final AppStorage storage;
  final AccountService accounts;
  final CredentialStore secrets;
  final Future<void> Function()? onChanged;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final ConfigArchive _archive = ConfigArchive(
    storage: widget.storage,
    accounts: widget.accounts,
    secrets: widget.secrets,
  );
  bool _includeAccount = false;
  bool _busy = false;
  String? _message;

  Future<bool> _confirm(String title, Widget content, String action) =>
      showConfirmationDialog(
        context,
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SingleChildScrollView(child: content),
        confirmLabel: action,
      );

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _message = switch (error) {
          ConfigArchiveException e => e.message,
          AccountException e => e.message,
          StorageException e => e.message,
          XmlyException e => e.message,
          _ => '操作失败，原资料已保留，请检查文件和保存位置',
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    final includeAccount = _includeAccount;
    if (includeAccount &&
        !await _confirm(
          '导出登录信息？',
          const Text('此备份未加密，包含登录凭据。拿到文件的人可能使用你的账号，请妥善保存，不要发送给他人。'),
          '仍要导出',
        ))
      return;
    if (!mounted) return;
    final bytes = await _archive.export(includeAccount: includeAccount);
    if (!mounted) return;
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'XMPlus-$date${includeAccount ? '-含账号' : ''}.zip',
      bytes: Uint8List.fromList(bytes),
      mimeType: 'application/zip',
      dialogTitle: '保存备份',
    );
    if (saved != null && mounted) setState(() => _message = '备份已保存');
  });

  Future<void> _import() => _run(() async {
    final file = await FilePicker.pickFile(
      dialogTitle: '选择 XMPlus 备份',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (file == null || !mounted) return;
    final length = await file.length();
    if (length != null && length > ConfigArchive.maxBytes) {
      throw const ConfigArchiveException('备份超过 64 MiB');
    }
    // A bounded stream also handles providers which do not report file length.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > ConfigArchive.maxBytes) {
        throw const ConfigArchiveException('备份超过 64 MiB');
      }
      bytes.add(chunk);
    }
    final draft = await _archive.inspect(bytes.takeBytes());
    if (!mounted) return;
    final replacements = <String, String>{};
    for (final oldRoot in draft.missingDirectories) {
      if (!await _confirm(
        '下载目录已失效',
        Text('原目录：$oldRoot\n请选择新的下载目录；旧音频和缓存不会自动复制。'),
        '选择目录',
      ))
        return;
      if (!mounted) return;
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: '选择新的下载目录',
      );
      if (selected == null || !mounted) return;
      replacements[oldRoot] = selected;
    }
    final accepted = await _confirm(
      '恢复备份',
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in draft.summary)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• $line'),
            ),
          for (final replacement in replacements.entries)
            Text('${replacement.key}\n→ ${replacement.value}\n'),
          const Text('取消不会修改现有资料。恢复后不会自动播放或开始下载。'),
        ],
      ),
      '确认恢复',
    );
    if (!accepted || !mounted) return;
    await _archive.restore(draft, relocatedRoots: replacements);
    try {
      await widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _message = '备份已保存，但任务加载未完成；请保留资料目录后重试');
      return;
    }
    if (mounted) setState(() => _message = '备份已恢复，未完成任务保持暂停');
  });

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
        ),
        children: [
          AdaptiveText('备份与恢复', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('包含登录信息'),
                  subtitle: const Text('默认备份设置、书签和任务记录，不包含音频或云端收藏、历史'),
                  value: _includeAccount,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _includeAccount = value),
                ),
                if (_includeAccount)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text('未加密，包含登录凭据。请勿分享此备份。'),
                  ),
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const AdaptiveText('导出备份'),
                  enabled: !_busy,
                  onTap: _busy ? null : _export,
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const AdaptiveText('恢复备份'),
                  subtitle: const Text('先查看恢复内容，再确认'),
                  enabled: !_busy,
                  onTap: _busy ? null : _import,
                ),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(liveRegion: true, child: Text(_message!)),
            ),
        ],
      ),
    ),
  );
}
