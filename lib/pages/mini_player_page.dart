import 'package:flutter/material.dart';

import '../services/app_runtime.dart';
import 'player_panel.dart';

class MiniPlayerPage extends StatelessWidget {
  const MiniPlayerPage({
    required this.runtime,
    required this.onRestore,
    required this.onExit,
    super.key,
  });

  static const routeName = '/mini-player';
  final AppRuntime runtime;
  final VoidCallback onRestore, onExit;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onRestore();
    },
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 40,
        title: const Text('小窗播放', style: TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            tooltip: '恢复主窗口',
            onPressed: onRestore,
            icon: const Icon(Icons.open_in_full),
          ),
          IconButton(
            tooltip: '彻底退出',
            onPressed: onExit,
            icon: const Icon(Icons.power_settings_new),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlayerPanel(
              runtime: runtime,
              miniWindow: true,
              onExpand: onRestore,
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '关闭小窗会最小化到任务栏',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
