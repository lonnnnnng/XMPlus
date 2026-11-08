import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// long: 诊断只保存传输摘要，登录凭据和服务端正文不能进入日志或剪贴板。
class RequestDiagnostics {
  RequestDiagnostics._();
  static final instance = RequestDiagnostics._();
  final _changes = StreamController<void>.broadcast();
  final _entries = <RequestFailure>[];
  final _unsaved = <RequestFailure, String>{};
  final _retiredPaths = <String>{};
  static const maxEntries = 100;
  Future<void> _work = Future<void>.value();
  String? directory;
  String? persistenceError;
  int _sequence = 0;

  Stream<void> get changes => _changes.stream;
  List<RequestFailure> get entries => List.unmodifiable(_entries);

  Future<void> configure(String appSupportDirectory) {
    final target = p.join(appSupportDirectory, 'request-diagnostics');
    _work = _work.then((_) async {
      if (directory == target) return;
      directory = target;
      try {
        await Directory(target).create(recursive: true);
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const FileSystemException('诊断目录不能是链接');
        }
        await for (final file in Directory(target).list(followLinks: false)) {
          if (file is! File || !p.basename(file.path).endsWith('.log'))
            continue;
          await file.delete();
        }
        persistenceError = null;
      } catch (error) {
        persistenceError = '$error';
      }
      _notify();
    });
    return _work;
  }

  Future<void> record(RequestDiagnostic diagnostic, Object error) {
    final text = diagnostic.describe(error);
    final failure = RequestFailure(
      timestamp: diagnostic.timestamp,
      method: diagnostic.method,
      url: diagnostic.safeUrl,
      account: diagnostic.account == 'anonymous' ? '未登录请求' : '应用请求',
      path: '${diagnostic.timestamp.microsecondsSinceEpoch}-${_sequence++}.log',
    );
    _entries.add(failure);
    _unsaved[failure] = text;
    // long: 重试风暴和磁盘写入失败都只保留最近的记录，避免内存和磁盘持续增长。
    while (_entries.length > maxEntries) {
      final retired = _entries.removeAt(0);
      _unsaved.remove(retired);
      if (p.isAbsolute(retired.path)) _retiredPaths.add(retired.path);
    }
    _notify();
    _work = _work.then((_) async {
      try {
        final root = directory;
        if (root == null) throw const FileSystemException('本地诊断目录尚未初始化');
        if (await FileSystemEntity.type(root, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const FileSystemException('诊断目录不可用或为链接');
        }
        for (final path in _retiredPaths.toList()) {
          if (p.dirname(path) == root &&
              await FileSystemEntity.type(path, followLinks: false) ==
                  FileSystemEntityType.file) {
            await File(path).delete();
          }
          _retiredPaths.remove(path);
        }
        final summary = _unsaved[failure];
        if (summary == null) return;
        failure.path = p.join(root, p.basename(failure.path));
        final file = File(failure.path);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('诊断文件已存在，未覆盖');
        }
        await file.writeAsString(
          '${jsonEncode({'timestamp': failure.timestamp.toIso8601String(), 'method': failure.method, 'url': failure.url, 'account': failure.account})}\n\n$summary',
          flush: true,
        );
        _unsaved.remove(failure);
        persistenceError = null;
      } catch (writeError) {
        persistenceError = '$writeError';
      }
      _notify();
    });
    return _work;
  }

  Future<String> read(RequestFailure failure) async =>
      _unsaved[failure] ?? await File(failure.path).readAsString();
  Future<void> flush() => _work;
  Future<void> close() async {
    await flush();
    await _changes.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

class RequestFailure {
  RequestFailure({
    required this.timestamp,
    required this.method,
    required this.url,
    required this.account,
    required this.path,
  });
  final DateTime timestamp;
  final String method, url, account;
  String path;
}

/// One recorder per actual attempt, including attempts later retried successfully.
class RequestDiagnostic {
  RequestDiagnostic({
    required this.account,
    required this.method,
    required this.url,
  });
  final DateTime timestamp = DateTime.now().toUtc();
  final String account, method;
  String url;
  String requestHeaderAvailability =
      '完整的 HTTP 库请求头；底层连接自动生成的头（如 Host / Connection）可能不向调用方暴露';
  Map<String, dynamic> requestHeaders = {};
  String requestBody = '(无请求体)';
  int? status;
  String? transportError;
  Map<String, dynamic> responseHeaders = {};
  int Function()? responseByteCount;
  String completeness = '未接收到响应体';
  bool _failed = false;

  Future<void> fail(Object error) {
    if (_failed) return Future<void>.value();
    _failed = true;
    return RequestDiagnostics.instance.record(this, error);
  }

  // long: 音频地址可能把签名放在路径里，因此日志只保留来源站点，不保留路径及参数。
  String get safeUrl {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return '(地址已隐藏)';
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  static Map<String, String> _safeHeaders(Map<String, dynamic> headers) => {
    for (final entry in headers.entries)
      if (const {
        'content-type',
        'content-length',
        'retry-after',
        'accept-ranges',
      }.contains(entry.key.toLowerCase()))
        entry.key.toLowerCase(): entry.value
            .toString()
            .replaceAll(RegExp(r'[\r\n]'), ' ')
            .substring(
              0,
              entry.value
                  .toString()
                  .replaceAll(RegExp(r'[\r\n]'), ' ')
                  .length
                  .clamp(0, 128),
            ),
  };

  String describe(Object error) {
    var count = 0;
    try {
      count = responseByteCount?.call() ?? 0;
    } catch (_) {
      // long: 统计失败不再回读媒体缓存；错误日志不能拖慢播放和下载。
    }
    return '时间 (UTC): ${timestamp.toIso8601String()}\n'
        '请求: $method $safeUrl\n'
        '响应: ${status == null ? '无响应 (no response)' : 'HTTP $status'}\n'
        '响应元数据:\n${const JsonEncoder.withIndent('  ').convert(_safeHeaders(responseHeaders))}\n'
        '已接收响应字节: $count\n异常类型: ${error.runtimeType}\n'
        '为保护登录信息，账号、请求头、请求体、响应正文、地址路径与参数及原始异常均不保存。\n';
  }
}
