// Update dialog, startup preference and ABI selection adapted from PiliPlus
// lib/utils/update.dart and lib/pages/main/controller.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a (GNU GPL v3).
// Source: https://github.com/bggRGjQaUbCoE/PiliPlus
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:url_launcher/url_launcher.dart';

import '../storage/app_storage.dart';
import 'request_diagnostics.dart';
import 'network_retry.dart';

/// Only stable, versioned releases from the public XMPlus repository are used.
class UpdateRelease {
  UpdateRelease._(this.tag, this.version, this.notes, this._assets);

  final String tag;
  final Version version;
  final String notes;
  final List<(String, Uri)> _assets;

  static Version parseVersion(String value) {
    final text = value.startsWith('v') ? value.substring(1) : value;
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
    ).hasMatch(text)) {
      throw const FormatException('版本号格式无效');
    }
    return Version.parse(text);
  }

  factory UpdateRelease.fromJson(Map<String, dynamic> data) {
    final tag = data['tag_name'];
    if (tag is! String ||
        data['draft'] != false ||
        data['prerelease'] != false ||
        data['body'] != null && data['body'] is! String ||
        data['assets'] is! List) {
      throw const FormatException('GitHub 发布数据无效');
    }
    final version = parseVersion(tag);
    if (version.isPreRelease) throw const FormatException('不是稳定版本');
    final assets = <(String, Uri)>[];
    for (final asset in data['assets'] as List) {
      if (asset is! Map ||
          asset['name'] is! String ||
          asset['browser_download_url'] is! String)
        continue;
      final name = asset['name'] as String;
      final uri = Uri.tryParse(asset['browser_download_url'] as String);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment)
        continue;
      final path = uri.pathSegments;
      if (path.length == 6 &&
          path[0] == 'lonnnnnng' &&
          path[1].toLowerCase() == 'xmplus' &&
          path[2] == 'releases' &&
          path[3] == 'download' &&
          path[4] == tag &&
          path[5] == name) {
        assets.add((name, uri));
      }
    }
    return UpdateRelease._(tag, version, data['body'] as String? ?? '', assets);
  }

  Uri get page =>
      Uri.https('github.com', '/lonnnnnng/XMPlus/releases/tag/$tag');

  bool isNewerThan(String currentVersion) {
    final current = parseVersion(currentVersion);
    // SemVer build metadata is not an upgrade, even though pub_semver orders it.
    Version precedence(Version value) => Version(
      value.major,
      value.minor,
      value.patch,
      pre: value.preRelease.isEmpty ? null : value.preRelease.join('.'),
    );
    return precedence(version).compareTo(precedence(current)) > 0;
  }

  /// Exact filenames prevent selecting another architecture or a source archive.
  Uri downloadUri({
    required String platform,
    List<String> androidAbis = const [],
  }) {
    final suffixes = switch (platform) {
      'android' => [
        for (final abi in androidAbis)
          if (const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi))
            'android-$abi.apk',
      ],
      'windows-x64' => ['windows-x64.zip'],
      // long: 优先提供与处理器匹配的 Mac 安装包，通用包作为兼容回退。
      'macos-arm64' => [
        'macos-arm64.dmg',
        'macos-arm64.zip',
        'macos-universal.dmg',
        'macos-universal.zip',
      ],
      'macos-x64' => [
        'macos-x64.dmg',
        'macos-x64.zip',
        'macos-universal.dmg',
        'macos-universal.zip',
      ],
      _ => <String>[],
    };
    for (final suffix in suffixes) {
      final name = 'XMPlus-$version-$suffix';
      for (final asset in _assets) {
        if (asset.$1 == name) return asset.$2;
      }
    }
    return page;
  }
}

enum _UpdateAction { ignore, download, page }

class UpdateService extends ChangeNotifier {
  UpdateService(this.storage, {HttpClientAdapter? adapter}) {
    if (adapter != null) _http.httpClientAdapter = adapter;
  }

  final AppStorage storage;
  // A separate client deliberately has no account interceptors, cookies or token.
  final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'XMPlus',
      },
      validateStatus: (_) => true,
    ),
  );
  PackageInfo? packageInfo;
  bool checking = false;
  String? message;
  String? error;
  bool _disposed = false;
  final _closed = Completer<void>();
  final _cancel = CancelToken();

  Map get _preferences {
    final value = (storage.state['settings'] as Map)['updates'];
    return value is Map ? value : const {};
  }

  bool get autoCheck => _preferences['autoCheck'] != false;
  String? get ignoredVersion => _preferences['ignoredVersion'] is String
      ? _preferences['ignoredVersion'] as String
      : null;
  String get versionLabel => packageInfo == null
      ? '正在读取版本…'
      : '${packageInfo!.version}${packageInfo!.buildNumber.isEmpty ? '' : '+${packageInfo!.buildNumber}'}';

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _save(Map<String, dynamic> changes) async {
    try {
      await storage.transaction((state) {
        final settings = state['settings'] as Map;
        final previous = settings['updates'];
        settings['updates'] = <String, dynamic>{
          if (previous is Map) ...Map<String, dynamic>.from(previous),
          ...changes,
        };
      });
      error = null;
      _changed();
      return true;
    } catch (_) {
      error = '更新设置保存失败，原设置已保留';
      _changed();
      return false;
    }
  }

  Future<void> setAutoCheck(bool value) async {
    await _save({'autoCheck': value});
  }

  Future<void> clearIgnoredVersion() async {
    await _save({'ignoredVersion': null});
  }

  Future<(int?, List<int>, RequestDiagnostic)> _latest() async {
    const url = 'https://api.github.com/repos/lonnnnnng/XMPlus/releases/latest';
    for (var attempt = 0; ; attempt++) {
      if (_disposed) throw StateError('Update service is closed');
      final bytes = <int>[];
      final diagnostic =
          RequestDiagnostic(account: '公共更新检查（无账号）', method: 'GET', url: url)
            ..requestHeaders = Map<String, dynamic>.from(_http.options.headers)
            ..responseByteCount = (() => bytes.length);
      Response<ResponseBody>? response;
      try {
        response = await _http.get<ResponseBody>(
          url,
          options: Options(responseType: ResponseType.stream),
          cancelToken: _cancel,
        );
        diagnostic
          ..requestHeaders = response.requestOptions.headers
          ..status = response.statusCode
          ..responseHeaders = response.headers.map
          ..completeness = '响应体接收中；失败时保留全部已接收字节';
        final iterator = StreamIterator(response.data!.stream);
        try {
          while (await Future.any<bool>([
            iterator.moveNext().timeout(const Duration(seconds: 20)),
            _closed.future.then<bool>(
              (_) => throw StateError('Update service closed'),
            ),
          ])) {
            // long: 更新接口只需要元数据；异常的大响应不能无限占用内存。
            if (bytes.length + iterator.current.length > 2 * 1024 * 1024) {
              throw const FormatException('GitHub 发布数据超过大小限制');
            }
            bytes.addAll(iterator.current);
          }
        } finally {
          await iterator.cancel();
        }
        diagnostic.completeness = '完整响应体';
        if (response.statusCode != 200 && response.statusCode != 404) {
          throw DioException.badResponse(
            statusCode: response.statusCode ?? 0,
            requestOptions: response.requestOptions,
            response: response,
          );
        }
        if (response.statusCode == 404) {
          await diagnostic.fail(const FormatException('GitHub 尚无稳定版本 (404)'));
        }
        return (response.statusCode, bytes, diagnostic);
      } catch (failure) {
        if (failure is DioException) {
          diagnostic.requestHeaders = failure.requestOptions.headers;
          diagnostic.transportError =
              '${failure.type}: ${failure.error ?? failure.message}';
        } else if (retryableTransport(failure)) {
          diagnostic.transportError = '$failure';
        }
        await diagnostic.fail(failure);
        if (_disposed ||
            attempt == 4 ||
            !(retryableStatus(response?.statusCode) ||
                retryableTransport(failure)))
          rethrow;
        await waitToRetry(
          retryDelay(attempt, response?.headers.value('retry-after')),
          closed: _closed.future,
        );
      }
    }
  }

  Future<void> check(BuildContext context, {bool manual = false}) async {
    if (checking || _disposed) return;
    var interactive = manual;
    checking = true;
    message = null;
    error = null;
    _changed();
    try {
      packageInfo ??= await PackageInfo.fromPlatform();
      _changed();
      if (!manual && !autoCheck) return;
      final (status, responseBytes, diagnostic) = await _latest();
      if (status == 404) {
        message = '暂无已发布的稳定版本';
        if (manual && context.mounted && !_disposed) _toast(context, message!);
        return;
      }
      late final UpdateRelease release;
      try {
        final data = jsonDecode(utf8.decode(responseBytes));
        if (data is! Map<String, dynamic>) {
          throw const FormatException('GitHub 未返回有效的发布数据');
        }
        release = UpdateRelease.fromJson(data);
      } catch (failure) {
        await diagnostic.fail(failure);
        rethrow;
      }
      if (!release.isNewerThan(packageInfo!.version)) {
        message = '已是最新版本';
        if (manual && context.mounted && !_disposed) _toast(context, message!);
        return;
      }
      message = '发现新版本 ${release.tag}';
      if (!context.mounted ||
          _disposed ||
          !manual &&
              (!autoCheck || ignoredVersion == release.version.toString()))
        return;
      final action = await showDialog<_UpdateAction>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发现新版本'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.tag,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('当前版本：$versionLabel'),
                  const SizedBox(height: 16),
                  SelectableText(
                    release.notes.isEmpty ? '此版本未提供更新说明。' : release.notes,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _UpdateAction.page),
                    child: const Text('查看官方发布页'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _UpdateAction.ignore),
              child: const Text('忽略此版本'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('稍后'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _UpdateAction.download),
              child: const Text('获取更新'),
            ),
          ],
        ),
      );
      if (_disposed) return;
      if (action != null) interactive = true;
      if (action == _UpdateAction.ignore) {
        final saved = await _save({
          'ignoredVersion': release.version.toString(),
        });
        if (!saved && context.mounted && !_disposed) _toast(context, error!);
      } else if (action == _UpdateAction.page ||
          action == _UpdateAction.download) {
        var target = release.page;
        if (action == _UpdateAction.download) {
          if (Platform.isAndroid) {
            try {
              final info = await DeviceInfoPlugin().androidInfo;
              target = release.downloadUri(
                platform: 'android',
                androidAbis: info.supportedAbis,
              );
            } catch (_) {
              // If device ABI discovery fails, the official page remains usable.
            }
          } else if (Platform.isWindows && Abi.current() == Abi.windowsX64) {
            target = release.downloadUri(platform: 'windows-x64');
          } else if (Platform.isMacOS) {
            target = release.downloadUri(
              platform: Abi.current() == Abi.macosArm64
                  ? 'macos-arm64'
                  : 'macos-x64',
            );
          }
        }
        if (_disposed) return;
        // The OS/browser handles downloading; XMPlus never executes the asset.
        if (!await launchUrl(target, mode: LaunchMode.externalApplication)) {
          throw const FormatException('无法打开浏览器，请在关于页复制官方发布链接');
        }
      }
    } catch (failure) {
      error = failure is FormatException
          ? failure.message.toString()
          : '检查更新失败，请检查网络后重试；也可前往官方发布页';
      if (interactive && context.mounted && !_disposed) _toast(context, error!);
    } finally {
      checking = false;
      _changed();
    }
  }

  static void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    _disposed = true;
    _closed.complete();
    _cancel.cancel('Update service disposed');
    _http.close(force: true);
    super.dispose();
  }
}
