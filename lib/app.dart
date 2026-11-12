// Adapted from PiliPlus lib/main.dart::MyApp, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:synchronized/synchronized.dart';
import 'package:window_manager/window_manager.dart';

import 'common/theme.dart';
import 'common/widgets/scroll_behavior.dart';
import 'common/widgets/app_shutdown_overlay.dart';
import 'pages/shell_page.dart';
import 'pages/download_page.dart';
import 'pages/player_panel.dart';
import 'pages/mini_player_page.dart';
import 'pages/window_close_preferences.dart';
import 'services/app_runtime.dart';
import 'services/desktop_playback_window.dart';
import 'services/request_diagnostics.dart';

class MyApp extends StatefulWidget {
  const MyApp({required this.runtime, super.key});

  final AppRuntime runtime;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  late final _appearance = AppAppearance(widget.runtime.storage);
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _playerRoutes = _PlayerRouteObserver();
  final _windowActions = Lock();
  final _playbackWindow = DesktopPlaybackWindow();
  Route<void>? _miniRoute;
  Route<dynamic>? _closeDialog;
  Future<void>? _closeWork;
  bool _exitPending = false, _choosingCloseAction = false;
  String? _windowCloseError;
  bool _diagnosticsOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      RequestDiagnostics.instance.configure(widget.runtime.storage.directory),
    );
    widget.runtime.confirmDownload = (batch) async {
      final context = _navigator.currentContext;
      return context == null ? false : confirmDownloadBatch(context, batch);
    };
    widget.runtime.requestExit = () => onCloseRequested(explicitExit: true);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void onWindowClose() async {
    await onCloseRequested();
  }

  Future<void> onCloseRequested({bool explicitExit = false}) {
    if (!mounted) return Future.value();
    if (explicitExit ||
        widget.runtime.scheduledExit ||
        widget.runtime.exitOnly) {
      _exitPending = true;
      // A timer can fire while a close dialog is waiting for user input.
      // Dismiss only our dialog; an explicit exit still confirms downloads.
      final dialog = _closeDialog;
      if (dialog != null &&
          dialog.isActive &&
          (_choosingCloseAction || widget.runtime.scheduledExit)) {
        _navigator.currentState?.removeRoute(dialog);
      }
    }
    return _closeWork ??= _windowActions
        .synchronized(_handleClose)
        .whenComplete(() {
          _closeWork = null;
          _exitPending = false;
          widget.runtime.scheduledExit = false;
        });
  }

  Future<T?> _askClose<T>(Widget dialog) async {
    final context = _navigator.currentContext;
    if (context == null) return null;
    final route = DialogRoute<T>(context: context, builder: (_) => dialog);
    _closeDialog = route;
    try {
      return await _navigator.currentState!.push(route);
    } finally {
      if (identical(_closeDialog, route)) _closeDialog = null;
    }
  }

  Future<void> _handleClose() async {
    if (!mounted) return;
    if (_windowCloseError != null) setState(() => _windowCloseError = null);
    try {
      if (Platform.isWindows && !_exitPending) {
        if (_miniRoute != null) {
          await windowManager.minimize();
          if (!_exitPending) return;
        } else {
          var action = WindowCloseAction.read(widget.runtime);
          if (action == WindowCloseAction.ask) {
            _choosingCloseAction = true;
            final choice = await _askClose<(WindowCloseAction, bool)>(
              const WindowCloseChoiceDialog(),
            );
            _choosingCloseAction = false;
            if (!_exitPending) {
              if (choice == null) return;
              action = choice.$1;
              if (choice.$2) {
                try {
                  await action.save(widget.runtime);
                } catch (_) {
                  _showWindowError('未能记住选择，本次仍按所选方式关闭');
                }
              }
            }
          }
          if (!_exitPending && action == WindowCloseAction.mini) {
            await _enterMini();
            if (!_exitPending) return;
          }
        }
      }
      if (!widget.runtime.exitOnly &&
          !widget.runtime.scheduledExit &&
          widget.runtime.downloads.tasks.any((task) => task.active)) {
        final confirmed = await _askClose<bool>(
          Builder(
            builder: (context) => AlertDialog(
              title: const Text('暂停下载并退出？'),
              content: const Text('下次打开后可手动继续。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('暂停并退出'),
                ),
              ],
            ),
          ),
        );
        if (confirmed != true && !widget.runtime.scheduledExit) return;
      }
      if (await widget.runtime.close()) {
        if (Platform.isAndroid) {
          await SystemNavigator.pop();
        } else {
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }
      } else {
        await _revealWindow();
        _showWindowError(widget.runtime.lifecycleError ?? '退出未完成，请重试');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _windowCloseError = '窗口未能关闭，请重试退出');
      }
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        try {
          await windowManager.setPreventClose(true);
        } catch (_) {
          // Keep the retry UI even if the native window call also failed.
        }
      }
      await _revealWindow();
      _showWindowError('窗口操作未完成，请重试');
    } finally {
      _choosingCloseAction = false;
    }
  }

  Future<void> _revealWindow() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    }
  }

  void _showWindowError(String message) {
    _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _enterMini() async {
    if (_miniRoute != null || !mounted) return;
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: MiniPlayerPage.routeName),
      builder: (_) => MiniPlayerPage(
        runtime: widget.runtime,
        onRestore: () => unawaited(_switchWindow(restore: true)),
        onExit: () => unawaited(onCloseRequested(explicitExit: true)),
      ),
    );
    setState(() => _miniRoute = route);
    unawaited(_navigator.currentState!.push(route));
    try {
      await _playbackWindow.enterMini();
    } catch (_) {
      if (!_playbackWindow.isMini) {
        _navigator.currentState?.removeRoute(route);
        if (mounted) setState(() => _miniRoute = null);
      }
      rethrow;
    }
  }

  Future<void> _switchWindow({bool restore = false}) =>
      _windowActions.synchronized(() async {
        if (!mounted || widget.runtime.closing) return;
        try {
          if (restore) {
            await _playbackWindow.restore();
            final route = _miniRoute;
            if (route != null) {
              _navigator.currentState?.removeRoute(route);
              if (mounted) setState(() => _miniRoute = null);
            }
          } else {
            await _enterMini();
          }
        } catch (_) {
          await _revealWindow();
          _showWindowError('窗口切换失败，可重试或选择彻底退出');
        }
      });

  Future<void> _showRequestFailures() async {
    if (_diagnosticsOpen || !mounted) return;
    final context = _navigator.currentContext;
    if (context == null) return;
    _diagnosticsOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => const _RequestFailureDialog(),
      );
    } finally {
      _diagnosticsOpen = false;
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    widget.runtime.confirmDownload = null;
    widget.runtime.requestExit = null;
    _appearance.dispose();
    _playerRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => GetMaterialApp(
        title: 'XMPlus',
        navigatorKey: _navigator,
        scaffoldMessengerKey: _messenger,
        navigatorObservers: [_playerRoutes],
        debugShowCheckedModeBanner: false,
        theme: getThemeData(
          seedColor: _appearance.seedColor,
          brightness: Brightness.light,
          oledBlack: _appearance.oledBlack,
        ),
        darkTheme: getThemeData(
          seedColor: _appearance.seedColor,
          brightness: Brightness.dark,
          oledBlack: _appearance.oledBlack,
        ),
        themeMode: _appearance.themeMode,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        locale: const Locale('zh', 'CN'),
        fallbackLocale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        scrollBehavior: const CustomScrollBehavior(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: AppTextScaler(
              MediaQuery.textScalerOf(context),
              _appearance.textScale,
            ),
          ),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: AppShutdownOverlay(
              runtime: widget.runtime,
              windowError: _windowCloseError,
              onRetry: () => unawaited(onCloseRequested(explicitExit: true)),
              child: Overlay.wrap(
                child: ListenableBuilder(
                  listenable: _playerRoutes,
                  child: child,
                  builder: (context, child) => Column(
                    children: [
                      if (_miniRoute == null)
                        ListenableBuilder(
                          listenable: widget.runtime,
                          builder: (context, _) => StreamBuilder<void>(
                            stream: RequestDiagnostics.instance.changes,
                            builder: (context, _) {
                              final diagnostics = RequestDiagnostics.instance;
                              final settings =
                                  widget.runtime.storage.state['settings']
                                      as Map;
                              if (settings['showRequestFailureBanner'] !=
                                      true ||
                                  (diagnostics.entries.isEmpty &&
                                      diagnostics.persistenceError == null)) {
                                return const SizedBox.shrink();
                              }
                              return Material(
                                color: Theme.of(context)
                                    .colorScheme
                                    .errorContainer,
                                child: SafeArea(
                                  bottom: false,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.error_outline),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '请求失败记录：${diagnostics.entries.length} 条'
                                            '${diagnostics.persistenceError == null ? '' : '；本地日志保存失败，请复制保留'}',
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _showRequestFailures,
                                          child: const Text('详情 / 复制'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      Expanded(child: child!),
                      if (_miniRoute == null &&
                          _playerRoutes.current?.settings.name !=
                              PlayerPanel.routeName)
                        SafeArea(
                          top: false,
                          child: ExcludeFocus(
                            excluding: _playerRoutes.current is PopupRoute,
                            child: ExcludeSemantics(
                              excluding: _playerRoutes.current is PopupRoute,
                              child: AbsorbPointer(
                                absorbing: _playerRoutes.current is PopupRoute,
                                child: PlayerPanel(
                                  runtime: widget.runtime,
                                  navigatorKey: _navigator,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        home: PopScope(
          canPop: !Platform.isAndroid,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && Platform.isAndroid) unawaited(onCloseRequested());
          },
          child: ShellPage(
            appearance: _appearance,
            runtime: widget.runtime,
            onMiniPlayer: Platform.isWindows
                ? () => unawaited(_switchWindow())
                : null,
          ),
        ),
      ),
    );
  }
}

class _PlayerRouteObserver extends NavigatorObserver with ChangeNotifier {
  Route<dynamic>? current;
  bool _disposed = false;

  void _changed(Route<dynamic>? route) {
    current = route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(current, oldRoute)) _changed(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(current, route)) _changed(previousRoute);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _RequestFailureDialog extends StatefulWidget {
  const _RequestFailureDialog();
  @override
  State<_RequestFailureDialog> createState() => _RequestFailureDialogState();
}

class _RequestFailureDialogState extends State<_RequestFailureDialog> {
  RequestFailure? _selected;
  String? _copiedPath;

  @override
  Widget build(BuildContext context) {
    final diagnostics = RequestDiagnostics.instance;
    return StreamBuilder<void>(
      stream: diagnostics.changes,
      builder: (context, _) {
        final entries = diagnostics.entries;
        final selected = _selected ?? (entries.isEmpty ? null : entries.last);
        return AlertDialog(
          title: Text('请求失败详情（${entries.length} 条）'),
          content: SizedBox(
            width: 900,
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('仅保存在本机。完整日志可能包含 Cookie、令牌、账号和签名等敏感信息；复制或分享前请自行核对。'),
                const SizedBox(height: 8),
                SelectableText('日志目录：${diagnostics.directory ?? '尚未初始化'}'),
                if (diagnostics.persistenceError != null)
                  SelectableText(
                    '保存失败：${diagnostics.persistenceError}（当前会话内容仍可复制）',
                  ),
                if (selected != null) ...[
                  DropdownButton<RequestFailure>(
                    isExpanded: true,
                    value: selected,
                    items: entries.reversed
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry,
                            child: Text(
                              '${entry.timestamp.toLocal()} · ${entry.account} · ${entry.method} ${entry.url}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() {
                      _selected = value;
                    }),
                  ),
                  Expanded(
                    child: FutureBuilder<String>(
                      future: diagnostics.read(selected),
                      builder: (context, snapshot) => SingleChildScrollView(
                        child: SelectableText(
                          snapshot.hasError
                              ? '无法读取日志：${snapshot.error}\n文件：${selected.path}'
                              : snapshot.data ?? '正在读取完整内容…',
                        ),
                      ),
                    ),
                  ),
                  SelectableText('文件：${selected.path}'),
                ] else
                  const Expanded(child: Text('暂无失败请求。')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: selected == null
                  ? null
                  : () async {
                      try {
                        final text = await diagnostics.read(selected);
                        await Clipboard.setData(ClipboardData(text: text));
                        if (mounted)
                          setState(() {
                            _copiedPath = selected.path;
                          });
                      } catch (error) {
                        if (mounted)
                          setState(() {
                            _copiedPath = '复制失败：$error';
                          });
                      }
                    },
              child: Text(
                _copiedPath == selected?.path
                    ? '已复制完整内容'
                    : _copiedPath?.startsWith('复制失败：') == true
                    ? _copiedPath!
                    : '复制完整内容',
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
