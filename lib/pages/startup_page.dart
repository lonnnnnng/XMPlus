import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../common/theme.dart';
import '../storage/app_storage.dart';
import '../storage/flutter_credential_store.dart';
import '../services/app_runtime.dart';
import '../services/account_service.dart';

class StartupPage extends StatefulWidget {
  const StartupPage({required this.arguments, super.key});
  final List<String> arguments;

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  AppRuntime? _runtime;
  String? _directory;
  String? _error;
  bool _opening = false;
  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = const Color(AppAppearance.defaultSeedColor);
  double _textScale = 1;
  bool _oledBlack = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open([String? selected]) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    AppStorage? candidate;
    try {
      if (selected != null) _directory = selected;
      if (_directory == null) {
        final args = widget.arguments;
        final index = args.indexOf('--data-dir');
        if (index >= 0) {
          if (index + 1 >= args.length || !p.isAbsolute(args[index + 1])) {
            throw const FormatException('资料目录必须是绝对路径');
          }
          _directory = args[index + 1];
        } else {
          _directory = (await getApplicationSupportDirectory()).path;
        }
      }
      candidate = await AppStorage.open(_directory!);
      // Validate persisted presentation values before leaving recovery UI.
      final appearance = AppAppearance(candidate);
      if (mounted) {
        setState(() {
          _themeMode = appearance.themeMode;
          _seedColor = appearance.seedColor;
          _textScale = appearance.textScale;
          _oledBlack = appearance.oledBlack;
        });
      }
      appearance.dispose();
      final runtime = AppRuntime(
        storage: candidate,
        secrets: FlutterCredentialStore(),
      );
      await runtime.load();
      if (!mounted) {
        await candidate.close();
        return;
      }
      setState(() {
        _runtime = runtime;
      });
    } catch (error) {
      await candidate?.close();
      if (mounted)
        setState(() {
          _error =
              error is StorageException ||
                  error is FormatException ||
                  error is AccountException
              ? error.toString()
              : '无法打开资料目录，请检查目录权限后重试';
        });
    } finally {
      if (mounted)
        setState(() {
          _opening = false;
        });
    }
  }

  Future<void> _choose() async {
    try {
      final value = await FilePicker.getDirectoryPath(dialogTitle: '选择资料目录');
      if (value != null && mounted) await _open(value);
    } catch (_) {
      if (mounted) setState(() => _error = '无法选择资料目录，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_runtime case final runtime?) return MyApp(runtime: runtime);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'XMPlus',
      theme: getThemeData(
        seedColor: _seedColor,
        brightness: Brightness.light,
        oledBlack: _oledBlack,
      ),
      darkTheme: getThemeData(
        seedColor: _seedColor,
        brightness: Brightness.dark,
        oledBlack: _oledBlack,
      ),
      themeMode: _themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: AppTextScaler(
            MediaQuery.textScalerOf(context),
            _textScale,
          ),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_opening) const CircularProgressIndicator(),
                    if (_error != null) ...[
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      if (_directory != null) SelectableText(_directory!),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          FilledButton(
                            onPressed: _opening ? null : () => _open(),
                            child: const Text('重试'),
                          ),
                          OutlinedButton(
                            onPressed: _opening ? null : _choose,
                            child: const Text('选择其他资料目录'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
