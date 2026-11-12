import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Local-only, unredacted HTTP diagnostics. Never upload these files.
class RequestDiagnostics {
  RequestDiagnostics._();
  static final instance = RequestDiagnostics._();
  final _changes = StreamController<void>.broadcast();
  final _entries = <RequestFailure>[];
  final _unsaved = <RequestFailure, String>{};
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
      url: diagnostic.url,
      account: diagnostic.account,
      path: '${diagnostic.timestamp.microsecondsSinceEpoch}-${_sequence++}.log',
    );
    _entries.add(failure);
    _unsaved[failure] = text;
    _notify();
    _work = _work.then((_) async {
      try {
        final root = directory;
        if (root == null) throw const FileSystemException('本地诊断目录尚未初始化');
        if (await FileSystemEntity.type(root, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const FileSystemException('诊断目录不可用或为链接');
        }
        failure.path = p.join(root, p.basename(failure.path));
        final file = File(failure.path);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('诊断文件已存在，未覆盖');
        }
        await file.writeAsString(
          '${jsonEncode({'timestamp': failure.timestamp.toIso8601String(), 'method': failure.method, 'url': failure.url, 'account': failure.account})}\n\n$text',
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
  List<int> Function()? responseBytes;
  String completeness = '未接收到响应体';
  bool _failed = false;

  Future<void> fail(Object error) {
    if (_failed) return Future<void>.value();
    _failed = true;
    return RequestDiagnostics.instance.record(this, error);
  }

  String describe(Object error) {
    List<int> bytes;
    try {
      bytes = responseBytes?.call() ?? Uint8List(0);
    } catch (captureError) {
      bytes = Uint8List(0);
      completeness = '$completeness；无法读取已接收的本地缓存：$captureError';
    }
    String body;
    try {
      body = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      body = '(非 UTF-8；以下 base64 保留全部已捕获字节)\n${base64Encode(bytes)}';
    }
    return '时间 (UTC): ${timestamp.toIso8601String()}\n账号: $account\n'
        '请求: $method $url\n请求头:\n${const JsonEncoder.withIndent('  ').convert(requestHeaders)}\n'
        '请求头完整性: $requestHeaderAvailability\n'
        '请求体:\n$requestBody\n\n'
        '响应: ${status == null ? '无响应 (no response)' : 'HTTP $status'}\n'
        '响应头:\n${const JsonEncoder.withIndent('  ').convert(responseHeaders)}\n'
        '响应完整性: $completeness\n已捕获响应字节: ${bytes.length}\n响应体:\n$body\n\n'
        '传输异常: ${transportError ?? '(无独立传输异常)'}\n异常 / 失败原因: $error\n';
  }
}
