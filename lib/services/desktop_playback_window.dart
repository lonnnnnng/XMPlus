import 'dart:async';
import 'dart:ui';

import 'package:synchronized/synchronized.dart';
import 'package:window_manager/window_manager.dart';

/// Changes only the presentation of the existing window, never the player.
class DesktopPlaybackWindow {
  final _changes = Lock();
  _WindowPlacement? _main;

  bool get isMini => _main != null;

  Future<void> _normalWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    if (await windowManager.isMaximized()) await windowManager.unmaximize();
    for (var attempt = 0; attempt < 50; attempt++) {
      if (!await windowManager.isMinimized() &&
          !await windowManager.isMaximized() &&
          !await windowManager.isFullScreen()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('窗口未能恢复普通大小');
  }

  Future<void> enterMini() => _changes.synchronized(() async {
    if (_main != null) return;
    final saved = _WindowPlacement(
      bounds: await windowManager.getBounds(),
      maximized: await windowManager.isMaximized(),
      fullScreen: await windowManager.isFullScreen(),
      alwaysOnTop: await windowManager.isAlwaysOnTop(),
    );
    _main = saved;
    try {
      await _normalWindow();
      saved.bounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(320, 180));
      await windowManager.setSize(const Size(420, 220));
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
    } catch (_) {
      await _restore(saved);
      _main = null;
      rethrow;
    }
  });

  Future<void> restore() => _changes.synchronized(() async {
    final saved = _main;
    if (saved == null) return;
    await _restore(saved);
    _main = null;
  });

  Future<void> _restore(_WindowPlacement saved) async {
    await _normalWindow();
    await windowManager.setMinimumSize(const Size(320, 320));
    await windowManager.setBounds(saved.bounds);
    await windowManager.setAlwaysOnTop(saved.alwaysOnTop);
    if (saved.maximized) await windowManager.maximize();
    if (saved.fullScreen) await windowManager.setFullScreen(true);
    await windowManager.show();
    await windowManager.focus();
  }
}

class _WindowPlacement {
  _WindowPlacement({
    required this.bounds,
    required this.maximized,
    required this.fullScreen,
    required this.alwaysOnTop,
  });

  Rect bounds;
  final bool maximized, fullScreen, alwaysOnTop;
}
