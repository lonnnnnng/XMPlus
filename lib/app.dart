// Adapted from PiliPlus lib/main.dart::MyApp, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import 'common/theme.dart';
import 'common/widgets/scroll_behavior.dart';
import 'pages/shell_page.dart';
import 'pages/download_page.dart';
import 'pages/player_panel.dart';
import 'services/app_runtime.dart';
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
  final _playerRoutes = _PlayerRouteObserver();
  bool _closeRequested = false;
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
    widget.runtime.requestExit = () async {
      if (Platform.isAndroid) {
        await onCloseRequested();
      } else {
        await windowManager.close();
      }
    };
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void onWindowClose() async {
    await onCloseRequested();
  }

  Future<void> onCloseRequested() async {
    if (_closeRequested || !mounted) return;
    _closeRequested = true;
    try {
      final context = _navigator.currentContext;
      if (!widget.runtime.scheduledExit &&
          widget.runtime.downloads.tasks.any((task) => task.active)) {
        final confirmed = context == null
            ? false
            : await showDialog<bool>(
                context: context,
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
              );
        if (confirmed != true) return;
      }
      if (await widget.runtime.close()) {
        if (Platform.isAndroid) {
          await SystemNavigator.pop();
        } else {
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }
      }
    } finally {
      _closeRequested = false;
      widget.runtime.scheduledExit = false;
    }
  }

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
            child: Overlay.wrap(
              child: ListenableBuilder(
                listenable: _playerRoutes,
                child: child,
                builder: (context, child) => Column(
                  children: [
                    ListenableBuilder(
                      listenable: widget.runtime,
                      builder: (context, _) => StreamBuilder<void>(
                        stream: RequestDiagnostics.instance.changes,
                        builder: (context, _) {
                          final diagnostics = RequestDiagnostics.instance;
                          final settings =
                              widget.runtime.storage.state['settings'] as Map;
                          if (settings['showRequestFailureBanner'] != true ||
                              (diagnostics.entries.isEmpty &&
                                  diagnostics.persistenceError == null)) {
                            return const SizedBox.shrink();
                          }
                          return Material(
                            color: Theme.of(context).colorScheme.errorContainer,
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
                    if (_playerRoutes.current?.settings.name !=
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
        home: PopScope(
          canPop: !Platform.isAndroid,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && Platform.isAndroid) unawaited(onCloseRequested());
          },
          child: ShellPage(appearance: _appearance, runtime: widget.runtime),
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
        final selected = entries.contains(_selected)
            ? _selected
            : (entries.isEmpty ? null : entries.last);
        return AlertDialog(
          title: Text('请求失败详情（${entries.length} 条）'),
          content: SizedBox(
            width: 900,
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('仅在本机保留最近 100 条传输摘要，不保存登录凭据、请求或响应正文。'),
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
                              : snapshot.data ?? '正在读取诊断摘要…',
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
                    ? '已复制摘要'
                    : _copiedPath?.startsWith('复制失败：') == true
                    ? _copiedPath!
                    : '复制诊断摘要',
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
