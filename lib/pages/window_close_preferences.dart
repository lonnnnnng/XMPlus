import 'package:flutter/material.dart';

import '../services/app_runtime.dart';

enum WindowCloseAction {
  ask('每次询问'),
  mini('收起到小窗'),
  exit('彻底退出');

  const WindowCloseAction(this.label);
  final String label;

  static WindowCloseAction read(AppRuntime runtime) {
    final value =
        (runtime.storage.state['settings'] as Map)['windowCloseAction'];
    return values.firstWhere(
      (action) => action.name == value,
      orElse: () => ask,
    );
  }

  Future<void> save(AppRuntime runtime) async {
    await runtime.storage.transaction((state) {
      (state['settings'] as Map)['windowCloseAction'] = name;
    });
    runtime.changed();
  }
}

class WindowCloseChoiceDialog extends StatefulWidget {
  const WindowCloseChoiceDialog({super.key});

  @override
  State<WindowCloseChoiceDialog> createState() =>
      _WindowCloseChoiceDialogState();
}

class _WindowCloseChoiceDialogState extends State<WindowCloseChoiceDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('关闭主窗口'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('收起到小窗后仍可继续收听和控制播放。'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('记住我的选择'),
            subtitle: const Text('可在设置的外观页更改'),
            value: _remember,
            onChanged: (value) => setState(() => _remember = value == true),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () =>
            Navigator.pop(context, (WindowCloseAction.exit, _remember)),
        child: const Text('彻底退出'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (WindowCloseAction.mini, _remember)),
        child: const Text('收起到小窗'),
      ),
    ],
  );
}

class WindowClosePreference extends StatefulWidget {
  const WindowClosePreference({required this.runtime, super.key});
  final AppRuntime runtime;

  @override
  State<WindowClosePreference> createState() => _WindowClosePreferenceState();
}

class _WindowClosePreferenceState extends State<WindowClosePreference> {
  bool _saving = false;
  String? _error;

  Future<void> _save(WindowCloseAction? action) async {
    if (action == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action.save(widget.runtime);
    } catch (_) {
      if (mounted) setState(() => _error = '设置保存失败，原设置已保留');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runtime,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('关闭主窗口时'),
        DropdownButton<WindowCloseAction>(
          isExpanded: true,
          value: WindowCloseAction.read(widget.runtime),
          items: WindowCloseAction.values
              .map(
                (action) =>
                    DropdownMenuItem(value: action, child: Text(action.label)),
              )
              .toList(),
          onChanged: _saving ? null : _save,
        ),
        const Text('小窗关闭后最小化到任务栏，播放继续。'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
