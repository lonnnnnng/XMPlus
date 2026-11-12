import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Official publisher/AI manuscript HTML, including image-only manuscripts.
class ManuscriptReader extends StatefulWidget {
  const ManuscriptReader({required this.manuscript, super.key});
  final String manuscript;

  @override
  State<ManuscriptReader> createState() => _ManuscriptReaderState();
}

class _ManuscriptReaderState extends State<ManuscriptReader> {
  final _scroll = ScrollController();
  final _nonce = base64UrlEncode(
    (() {
      final random = Random.secure();
      return List<int>.generate(24, (_) => random.nextInt(256));
    })(),
  );
  WebViewEnvironment? _environment;
  Directory? _profile;
  bool _ready = false;
  String? _error;
  int _attempt = 0;
  bool get _html =>
      widget.manuscript.contains('<') || widget.manuscript.contains('&');
  String get _documentUrl => Platform.isAndroid
      ? 'https://appassets.androidplatform.net/xmplus-manuscript/$_nonce/index.html'
      : 'about:blank';

  @override
  void initState() {
    super.initState();
    if (_html) unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
      if (Platform.isWindows) {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (version == null || version.isEmpty) {
          throw StateError('WebView2 unavailable');
        }
        final profile = _profile ??= await Directory.systemTemp.createTemp(
          'xmplus-manuscript-',
        );
        final environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: profile.path,
            allowSingleSignOnUsingOSPrimaryAccount: false,
            language: 'zh-CN',
          ),
        );
        if (!mounted) {
          await environment.dispose();
          await _deleteProfile(profile);
          return;
        }
        _environment = environment;
      } else if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
        throw UnsupportedError('Native manuscript reader unavailable');
      }
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      _fail();
    }
  }

  static Future<void> _deleteProfile(Directory profile) async {
    try {
      if (await profile.exists()) await profile.delete(recursive: true);
    } on FileSystemException {
      // WebView2 can retain its temporary isolated profile until shutdown.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    final environment = _environment, profile = _profile;
    unawaited(() async {
      try {
        await environment?.dispose();
      } catch (_) {
        // The native view may already have disposed the environment.
      }
      if (profile != null) await _deleteProfile(profile);
    }());
    super.dispose();
  }

  void _fail() {
    if (mounted) setState(() => _error = '文稿显示失败，请重试；HTML 文稿需要系统 WebView 运行时');
  }

  bool _image(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      const [
        'xmcdn.com',
        'ximalaya.com',
      ].any((host) => uri.host == host || uri.host.endsWith('.$host'));

  String _document() {
    final colors = Theme.of(context).colorScheme;
    String color(Color value) =>
        '#${value.toARGB32().toRadixString(16).substring(2)}';
    final fontSize = MediaQuery.textScalerOf(context).scale(17);
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'nonce-$_nonce'; img-src https://xmcdn.com https://*.xmcdn.com https://ximalaya.com https://*.ximalaya.com; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri https://www.ximalaya.com; form-action 'none'; sandbox">
<base href="https://www.ximalaya.com/">
<meta name="referrer" content="no-referrer">
<style nonce="$_nonce">html{color:${color(colors.onSurface)};background:${color(colors.surface)};font:${fontSize}px/1.8 sans-serif;overflow-wrap:anywhere}body{margin:0;padding:12px}img{max-width:100%;height:auto}pre{white-space:pre-wrap}a{color:inherit;pointer-events:none}table{max-width:100%;display:block;overflow:auto}</style>
</head><body>${widget.manuscript.replaceAll('\n', '<br>')}</body></html>''';
  }

  Future<void> _created(InAppWebViewController controller) async {
    try {
      if (Platform.isWindows) {
        final installed = await MethodChannel(
          'com.pichillilorenzo/flutter_inappwebview_${controller.getViewId()}',
        ).invokeMethod<bool>('xmplusDenyDownloads', const <String, dynamic>{});
        if (installed != true)
          throw StateError('Native download guard unavailable');
      }
      if (!mounted || _error != null) return;
      if (Platform.isAndroid) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_documentUrl)),
        );
      } else {
        await controller.loadData(
          data: _document(),
          baseUrl: WebUri(_documentUrl),
        );
      }
    } catch (_) {
      _fail();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text('文稿', style: Theme.of(context).textTheme.titleMedium),
      ),
      Expanded(
        child: !_html
            ? Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const ValueKey('manuscriptTextScroll'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    widget.manuscript,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(height: 1.8),
                  ),
                ),
              )
            : _error != null
            ? Center(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      Text(
                        _error!,
                        key: const ValueKey('manuscriptRenderError'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _error = null;
                            _attempt++;
                          });
                          if (!_ready) unawaited(_prepare());
                        },
                        child: const Text('重试显示文稿'),
                      ),
                    ],
                  ),
                ),
              )
            : !_ready
            ? const Center(child: CircularProgressIndicator())
            : InAppWebView(
                key: ValueKey(_attempt),
                webViewEnvironment: _environment,
                initialSettings: InAppWebViewSettings(
                  incognito: true,
                  cacheEnabled: false,
                  javaScriptEnabled: false,
                  isInspectable: false,
                  disableContextMenu: true,
                  useShouldOverrideUrlLoading: true,
                  useShouldInterceptRequest: true,
                  supportMultipleWindows: false,
                  javaScriptCanOpenWindowsAutomatically: false,
                  allowFileAccess: false,
                  allowContentAccess: false,
                  allowFileAccessFromFileURLs: false,
                  allowUniversalAccessFromFileURLs: false,
                  thirdPartyCookiesEnabled: false,
                  geolocationEnabled: false,
                  saveFormData: false,
                  databaseEnabled: false,
                  domStorageEnabled: false,
                  mediaPlaybackRequiresUserGesture: true,
                  useOnDownloadStart: true,
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                ),
                onWebViewCreated: _created,
                shouldOverrideUrlLoading: (_, action) async =>
                    action.request.url?.toString() == _documentUrl &&
                        action.navigationType != NavigationType.LINK_ACTIVATED
                    ? NavigationActionPolicy.ALLOW
                    : NavigationActionPolicy.CANCEL,
                shouldInterceptRequest: (_, request) async {
                  if (Platform.isAndroid &&
                      request.isForMainFrame == true &&
                      request.url.toString() == _documentUrl &&
                      mounted) {
                    return WebResourceResponse(
                      statusCode: 200,
                      reasonPhrase: 'OK',
                      contentType: 'text/html',
                      contentEncoding: 'utf-8',
                      headers: const {'Cache-Control': 'no-store'},
                      data: Uint8List.fromList(utf8.encode(_document())),
                    );
                  }
                  if ((Platform.isWindows || request.isForMainFrame != true) &&
                      _image(request.url.uriValue))
                    return null;
                  return WebResourceResponse(
                    statusCode: 403,
                    reasonPhrase: 'Forbidden',
                    contentType: 'text/plain',
                    headers: const {},
                    data: Uint8List(0),
                  );
                },
                onCreateWindow: (_, __) async => false,
                onPermissionRequest: (_, request) async => PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.DENY,
                ),
                onDownloadStartRequest: (controller, _) {
                  unawaited(controller.stopLoading());
                  _fail();
                },
                onReceivedError: (_, request, __) {
                  if (request.isForMainFrame == true) _fail();
                },
                onReceivedHttpError: (_, request, __) {
                  if (request.isForMainFrame == true) _fail();
                },
              ),
      ),
    ],
  );
}
