import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart' as win;

class StorageException implements Exception {
  const StorageException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// A single writer owns the OS lock for the complete lifetime of this object.
class AppStorage {
  AppStorage._(this.directory, this._lockFile, this._state);

  static const maxStateBytes = 64 * 1024 * 1024;
  static final Set<String> _openDirectories = {};
  final String directory;
  final RandomAccessFile _lockFile;
  final Lock _writes = Lock();
  Map<String, dynamic> _state;
  bool _closed = false;
  bool _lockClosed = false, _lockUnlocked = false;

  Map<String, dynamic> get state => _state;

  static Future<AppStorage> open(String absoluteDirectory) async {
    if (!p.isAbsolute(absoluteDirectory)) {
      throw const StorageException('directory', '请选择绝对路径的资料目录');
    }
    final folder = await Directory(absoluteDirectory).create(recursive: true);
    var canonical = p.normalize(await folder.resolveSymbolicLinks());
    if (Platform.isWindows) canonical = canonical.toLowerCase();
    if (!_openDirectories.add(canonical)) {
      throw const StorageException('locked', '数据目录已被另一实例使用');
    }
    RandomAccessFile? lock;
    try {
      lock = await File(p.join(canonical, 'state.lock'))
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive, 0, 1);
      } on FileSystemException {
        throw const StorageException('locked', '数据目录已被另一实例使用');
      }
      final file = File(p.join(canonical, 'state.json'));
      Map<String, dynamic> state;
      if (await file.exists()) {
        try {
          if (await file.length() > maxStateBytes)
            throw const FormatException();
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map<String, dynamic>) throw const FormatException();
          _validate(decoded);
          state = decoded;
        } catch (_) {
          throw const StorageException('corrupt', '资料文件损坏，请恢复备份或选择其他资料目录');
        }
      } else {
        if (await File(p.join(canonical, 'state.backup')).exists()) {
          throw const StorageException(
            'recovery_required',
            '资料提交未完成，请保留资料目录并恢复备份',
          );
        }
        state = {
          'schemaVersion': 1,
          'activeAccountId': null,
          'primaryAccountId': null,
          'settings': <String, dynamic>{},
          'accounts': <String, dynamic>{},
          'downloads': <dynamic>[],
          'library': <String, dynamic>{},
          'officialProgress': <String, dynamic>{},
          'queue': <String, dynamic>{},
        };
      }
      // Only sweep session data while holding the instance lock, before services start.
      for (final name in const ['captcha', 'playback-cache']) {
        final temporary = Directory(p.join(canonical, name));
        try {
          if (await temporary.exists()) await temporary.delete(recursive: true);
        } on FileSystemException {
          // A leftover file may still be in use; do not block opening the app.
        }
      }
      return AppStorage._(canonical, lock, _freezeMap(state));
    } catch (_) {
      await lock?.close();
      _openDirectories.remove(canonical);
      rethrow;
    }
  }

  Future<void> transaction(void Function(Map<String, dynamic>) update) =>
      _writes.synchronized(() async {
        if (_closed) throw const StorageException('closed', '资料目录已关闭');
        final next = jsonDecode(jsonEncode(_state)) as Map<String, dynamic>;
        update(next);
        _validate(next);
        final bytes = utf8.encode(jsonEncode(next));
        if (bytes.length > maxStateBytes) {
          throw const StorageException('too_large', '资料超过大小限制，未保存更改');
        }
        final temporary = File(
          p.join(directory, 'state.${const Uuid().v4()}.tmp'),
        );
        try {
          final output = await temporary.open(mode: FileMode.writeOnly);
          try {
            await output.writeFrom(bytes);
            await output.flush();
          } finally {
            await output.close();
          }
          await _replaceFile(temporary.path, p.join(directory, 'state.json'));
          _state = _freezeMap(next);
        } on StorageException {
          rethrow;
        } catch (_) {
          throw const StorageException('write_failed', '资料保存失败，原有资料未被替换');
        } finally {
          // A failed recovery leaves the backup intact, never delete that file.
          try {
            if (await temporary.exists()) await temporary.delete();
          } on FileSystemException {
            // An uncommitted nonsecret temporary file may be removed manually.
          }
        }
      });

  Future<void> close() => _writes.synchronized(() async {
    if (_lockClosed) return;
    _closed = true;
    try {
      if (!_lockUnlocked) {
        await _lockFile.unlock(0, 1);
        _lockUnlocked = true;
      }
    } finally {
      await _lockFile.close();
      _lockClosed = true;
      _openDirectories.remove(directory);
    }
  });

  static void _validate(Map<String, dynamic> value) {
    if (value['schemaVersion'] != 1 ||
        value['settings'] is! Map ||
        value['accounts'] is! Map ||
        value['downloads'] is! List ||
        value['library'] is! Map ||
        (value.containsKey('history') && value['history'] is! Map) ||
        (value.containsKey('officialProgress') &&
            value['officialProgress'] is! Map) ||
        value['queue'] is! Map ||
        (value['activeAccountId'] != null &&
            value['activeAccountId'] is! String) ||
        (value['primaryAccountId'] != null &&
            value['primaryAccountId'] is! String)) {
      throw const StorageException('corrupt', '资料格式无效，未保存更改');
    }
    final cleanup = value['credentialCleanup'];
    if (cleanup != null &&
        (cleanup is! List || cleanup.any((key) => key is! String))) {
      throw const StorageException('corrupt', '凭据清理记录格式无效');
    }
    void inspect(Object? node) {
      if (node is Map) {
        for (final entry in node.entries) {
          if (entry.key is! String ||
              const {
                'token',
                'device_id',
                'deviceId',
                'cookie',
                'cookie2',
                'x-tk',
                'headers',
                'password',
                'verificationCode',
              }.contains(entry.key)) {
            throw const StorageException('secret_in_state', '登录秘密不能写入资料文件');
          }
          inspect(entry.value);
        }
      } else if (node is List) {
        for (final item in node) {
          inspect(item);
        }
      } else if (node is num && !node.isFinite) {
        throw const StorageException('corrupt', '资料包含无效数字');
      }
    }

    inspect(value);
    // Accept legacy libraries, but never retain their local favorites.
    for (final library in (value['library'] as Map).values) {
      if (library is Map) library.remove('favorites');
    }
    // Keep the cloud-report outbox, not the legacy local history/read model.
    final progress =
        value.putIfAbsent('officialProgress', () => <String, dynamic>{}) as Map;
    final history = value.remove('history') as Map?;
    for (final entry in history?.entries ?? const <MapEntry>[]) {
      final pending = entry.value is Map ? entry.value['pending'] : null;
      if (pending is! Map) continue;
      final current =
          progress.putIfAbsent(entry.key, () => <String, dynamic>{}) as Map;
      for (final report in pending.entries) {
        current.putIfAbsent(report.key, () => report.value);
      }
    }
  }

  static Map<String, dynamic> _freezeMap(Map<String, dynamic> value) =>
      Map.unmodifiable(value.map((key, item) => MapEntry(key, _freeze(item))));

  static Object? _freeze(Object? value) => value is Map<String, dynamic>
      ? _freezeMap(value)
      : value is List
      ? List.unmodifiable(value.map(_freeze))
      : value;

  static Future<void> _replaceFile(String temporary, String destination) async {
    if (!Platform.isWindows) {
      await File(temporary).rename(destination);
      return;
    }
    _WindowsAtomic.replace(temporary, destination);
  }
}

/// win32 6.4 MoveFileEx returns Win32Result<bool>; ReplaceFileW is not exported
/// by that package, so only that missing call has a local FFI declaration.
class _WindowsAtomic {
  static final _replace = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('ReplaceFileW');

  static String _longPath(String value) => value.startsWith(r'\\?\')
      ? value
      : value.startsWith(r'\\')
      ? '${r'\\?\UNC\'}${value.substring(2)}'
      : '${r'\\?\'}$value';

  static void replace(String temporary, String destination) {
    using((arena) {
      final source = _longPath(temporary).toNativeUtf16(allocator: arena);
      final target = _longPath(destination).toNativeUtf16(allocator: arena);
      if (!File(destination).existsSync()) {
        final moved = win.MoveFileEx(
          win.PCWSTR(source),
          win.PCWSTR(target),
          win.MOVEFILE_WRITE_THROUGH,
        );
        if (!moved.value) {
          throw const StorageException('write_failed', '资料保存失败，原有资料未被替换');
        }
        return;
      }
      final backupPath = p.join(p.dirname(destination), 'state.backup');
      // Keep an old backup until replacement succeeds. The API requires the
      // backup name to be available; it is never our only live state here.
      final backupFile = File(backupPath);
      if (backupFile.existsSync()) backupFile.deleteSync();
      final backup = _longPath(backupPath).toNativeUtf16(allocator: arena);
      win.GetLastError();
      final result = _replace(target, source, backup, 0, nullptr, nullptr);
      final error = win.GetLastError();
      if (result == 0) {
        // 1176/1177 may move the old file. Supplying a backup lets us restore it.
        if (!File(destination).existsSync() && backupFile.existsSync()) {
          final restored = win.MoveFileEx(
            win.PCWSTR(backup),
            win.PCWSTR(target),
            win.MOVEFILE_WRITE_THROUGH,
          );
          if (!restored.value) {
            throw const StorageException(
              'recovery_required',
              '资料恢复失败，请保留资料目录和备份',
            );
          }
        }
        throw StorageException(
          'write_failed',
          '资料保存失败（${error.toInt()}），原有资料未被替换',
        );
      }
      try {
        if (backupFile.existsSync()) backupFile.deleteSync();
      } on FileSystemException {
        // Committed state is authoritative; a leftover nonsecret backup is safe.
      }
    });
  }
}
