import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_runtime.dart';

/// Keeps existing routes mounted while a failed early save can still recover.
class AppShutdownOverlay extends StatelessWidget {
  const AppShutdownOverlay({
    required this.runtime,
    required this.onRetry,
    required this.child,
    this.windowError,
    super.key,
  });

  final AppRuntime runtime;
  final VoidCallback onRetry;
  final Widget child;
  final String? windowError;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runtime,
    child: child,
    builder: (context, child) {
      final blocked = runtime.closing;
      final error = windowError ?? runtime.lifecycleError;
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: blocked,
            child: ExcludeSemantics(
              excluding: blocked,
              child: AbsorbPointer(absorbing: blocked, child: child),
            ),
          ),
          if (blocked)
            Focus(
              autofocus: true,
              onKeyEvent: (_, event) =>
                  event.logicalKey == LogicalKeyboardKey.escape
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              error == null ? '正在退出…' : '退出尚未完成',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            if (error == null)
                              const CircularProgressIndicator()
                            else ...[
                              Text(error, textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: onRetry,
                                child: const Text('重试退出'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
