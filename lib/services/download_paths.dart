import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart' as win;

import '../models/xmly_models.dart';
import 'android_platform.dart';
import 'file_paths.dart';

/// Filesystem policy shared by downloads and the media processor. No audio or
/// account operation belongs here; callers validate media before [commit].
class DownloadPaths {
  static const _mib = 1024 * 1024;
  static const _maxPath = 259; // Excludes the terminating Windows NUL.
  static const mediaTemporaryPrefix = '.xmplus-media-';
  static const mediaManifestSuffix = '.xmplus-media.json';
  static const _mediaProbeName = 'output.abcdefghij';
  static const _temporarySuffixReserve = '0000000000000000';
  static int get _maxTargetPath =>
      Platform.isWindows ? _maxPath - mediaManifestSuffix.length : _maxPath;
  static const _defaultPattern = '{index} - {title} [{trackId}]';
  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]');
  static final _reserved = RegExp(
    r'^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
    caseSensitive: false,
  );

  Future<void> checkRoot(
    String root, {
    int reserveBytes = 0,
    int minimumFreeMiB = 512,
  }) async {
    final base = _absoluteRoot(root);
    if (Platform.isWindows &&
        p
                .join(
                  base,
                  '$mediaTemporaryPrefix$_temporarySuffixReserve',
                  _mediaProbeName,
                )
                .length >
            _maxPath) {
      throw const XmlyException('path_too_long', '下载目录过长，请选择较短的根目录');
    }
    final minimumMiB = math.max(512, minimumFreeMiB);
    if (reserveBytes < 0 ||
        minimumFreeMiB < 0 ||
        minimumMiB > 0x7fffffffffffffff ~/ _mib ||
        reserveBytes > 0x7fffffffffffffff - minimumMiB * _mib) {
      throw const XmlyException('invalid_space', '可用空间设置无效');
    }
    if (!await Directory(base).exists()) {
      throw const XmlyException('download_directory', '下载目录不存在，请重新选择');
    }
    // A real write, flush and deletion tests this account's access, not mode bits.
    Directory? probeDirectory;
    try {
      probeDirectory = await Directory(base).createTemp(
        Platform.isWindows ? mediaTemporaryPrefix : '.xmplus-write-',
      );
      final probe = File(
        p.join(
          probeDirectory.path,
          Platform.isWindows ? _mediaProbeName : 'probe',
        ),
      );
      if (Platform.isWindows && probe.path.length > _maxPath) {
        throw const XmlyException('path_too_long', '下载目录过长，请选择较短的根目录');
      }
      final handle = await probe.open(mode: FileMode.writeOnly);
      try {
        await handle.writeByte(0);
        await handle.flush();
      } finally {
        await handle.close();
      }
      await probe.delete();
    } on FileSystemException {
      throw const XmlyException('download_not_writable', '下载目录不可写，请重新选择');
    } finally {
      if (probeDirectory != null) {
        try {
          await probeDirectory.delete(recursive: true);
        } on FileSystemException {
          // A failed write remains a failed check, even if cleanup also fails.
        }
      }
    }
    final available = await _availableBytes(
      await Directory(base).resolveSymbolicLinks(),
    );
    if (available < 0) {
      throw const XmlyException('disk_space_unavailable', '无法查询下载目录的可用空间');
    }
    if (available < minimumMiB * _mib + reserveBytes) {
      throw const XmlyException('disk_space', '下载空间不足，请释放空间或更换目录');
    }
  }

  /// Appends a stable ID, even when the title is empty or must be shortened.
  /// Limits both UTF-16 units (Windows) and UTF-8 bytes (portable filesystems).
  static String safeComponent(
    String text, {
    required String id,
    int maxLength = 120,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const XmlyException('invalid_path_id', '文件标识无效');
    }
    final suffix = ' [$id]';
    if (maxLength < suffix.length + 1 || utf8.encode(suffix).length + 1 > 240) {
      throw const XmlyException('path_too_long', '目录过长，无法保留文件标识');
    }
    var title = text
        .replaceAll(_illegal, '_')
        .trim()
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (title.endsWith(suffix))
      title = title.substring(0, title.length - suffix.length);
    title = title.trim().replaceFirst(RegExp(r'[. ]+$'), '');
    if (title.isEmpty || title == '.' || title == '..') title = '未命名';
    if (_reserved.hasMatch(title)) title = '_$title';
    title = _shorten(
      title,
      maxLength - suffix.length,
      240 - utf8.encode(suffix).length,
    ).replaceFirst(RegExp(r'[. ]+$'), '');
    if (title.isEmpty) title = '_';
    return '$title$suffix';
  }

  String targetPath({
    required String root,
    required Track track,
    required String extension,
    required Map<String, dynamic> settings,
    int? totalTracks,
  }) {
    final base = _absoluteRoot(root);
    if (!RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(extension)) {
      throw const XmlyException('invalid_extension', '音频扩展名无效');
    }
    if (totalTracks != null && totalTracks <= 0) {
      throw const XmlyException('invalid_order', '专辑集数无效');
    }
    final options = settings['download'];
    if (options != null && options is! Map) {
      throw const XmlyException('invalid_download_settings', '下载设置无效');
    }
    final download = options is Map ? options : const {};
    final pattern = download['filenamePattern'] ?? _defaultPattern;
    final albumFolders = download['albumFolders'] ?? true;
    if (pattern is! String || pattern.isEmpty || albumFolders is! bool) {
      throw const XmlyException('invalid_filename_pattern', '文件命名格式无效');
    }
    final variables = RegExp(r'\{([^{}]+)\}');
    const allowed = {'index', 'title', 'trackId', 'album', 'albumId'};
    final keys = variables
        .allMatches(pattern)
        .map((match) => match[1]!)
        .toSet();
    final remainder = pattern.replaceAll(variables, '');
    if (!allowed.containsAll(keys) ||
        remainder.contains('{') ||
        remainder.contains('}')) {
      throw const XmlyException(
        'invalid_filename_pattern',
        '文件命名只支持集号、标题、声音及专辑标识',
      );
    }
    // Even on POSIX, do not permit a Windows path separator in a template.
    if (pattern.contains('/') ||
        pattern.contains(r'\') ||
        pattern == '.' ||
        pattern == '..') {
      throw const XmlyException('invalid_filename_pattern', '文件命名不能包含目录路径');
    }
    final order = (track.orderNo != null && track.orderNo! > 0)
        ? track.orderNo
        : track.officialPosition;
    final standaloneDefault =
        track.albumId.isEmpty && order == null && pattern == _defaultPattern;
    if (keys.contains('index') && order == null && !standaloneDefault) {
      throw const XmlyException(
        'missing_official_order',
        '缺少官方集号，请完整加载专辑或修改命名格式',
      );
    }
    final width = math.max(3, (totalTracks ?? order ?? 0).toString().length);
    final values = {
      'index': order?.toString().padLeft(width, '0') ?? '',
      'title': track.title,
      'trackId': track.number,
      'album': track.album,
      'albumId': track.albumId,
    };
    final rendered = standaloneDefault
        ? '${track.title} [${track.number}]'
        : pattern.replaceAllMapped(variables, (match) => values[match[1]]!);
    final folderId = track.albumId.isEmpty ? track.number : track.albumId;
    final folderTitle = track.albumId.isEmpty ? '未分类' : track.album;
    var folderLimit = 120, fileLimit = 120;
    String makePath() => p.joinAll([
      base,
      if (albumFolders)
        safeComponent(folderTitle, id: folderId, maxLength: folderLimit),
      '${safeComponent(rendered, id: track.number, maxLength: fileLimit)}.${extension.toLowerCase()}',
    ]);
    var result = makePath();
    if (result.length > _maxTargetPath && albumFolders) {
      final minimum = folderId.length + 4;
      folderLimit = math.max(
        minimum,
        p.basename(p.dirname(result)).length - (result.length - _maxTargetPath),
      );
      result = makePath();
    }
    if (result.length > _maxTargetPath) {
      final minimum = track.number.length + 4;
      fileLimit = math.max(
        minimum,
        p.basenameWithoutExtension(result).length -
            (result.length - _maxTargetPath),
      );
      result = makePath();
    }
    if (result.length > _maxTargetPath || !p.isWithin(base, result)) {
      throw const XmlyException('path_too_long', '下载目录过长，请选择较短的根目录');
    }
    return result;
  }

  /// 'skip' only selects the name. The processor must probe/hash an existing
  /// file before treating it as a completed task. No file is deleted here.
  Future<String> chooseDestination(
    String target, {
    String conflict = 'skip',
  }) async {
    if (!const {'skip', 'overwrite', 'number'}.contains(conflict)) {
      throw const XmlyException('invalid_conflict', '同名文件处理方式无效');
    }
    if (conflict != 'number' ||
        await FileSystemEntity.type(target, followLinks: false) ==
            FileSystemEntityType.notFound) {
      return target;
    }
    final extension = p.extension(target);
    final stem = p.basenameWithoutExtension(target);
    final directory = p.dirname(target);
    for (var number = 1; ; number++) {
      final suffix = ' ($number)$extension';
      final limit = math.min(
        240 - utf8.encode(suffix).length,
        _maxTargetPath - directory.length - 1 - suffix.length,
      );
      var name = stem;
      if (name.length > limit ||
          utf8.encode(name).length > 240 - utf8.encode(suffix).length) {
        final id = RegExp(r' \[([A-Za-z0-9_-]+)\]$').firstMatch(stem);
        if (id == null) {
          throw const XmlyException('path_too_long', '文件名过长，无法安全添加编号');
        }
        name = safeComponent(stem, id: id[1]!, maxLength: limit);
        var units = limit;
        while (utf8.encode('$name$suffix').length > 255) {
          name = safeComponent(stem, id: id[1]!, maxLength: --units);
        }
      }
      final candidate = p.join(directory, '$name$suffix');
      if (await FileSystemEntity.type(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
  }

  /// Only same-volume operations; no copy/delete fallback or pre-deletion.
  /// [temporary] must already contain the fully validated media output.
  Future<void> commit(
    String temporary,
    String destination, {
    bool overwrite = false,
  }) async {
    final source = absoluteFilePath(temporary);
    final target = absoluteFilePath(destination);
    final sourceCanonical = await File(source).resolveSymbolicLinks();
    final targetParent = await Directory(p.dirname(target))
        .resolveSymbolicLinks();
    final targetCanonical = p.join(targetParent, p.basename(target));
    if (p.equals(sourceCanonical, targetCanonical) ||
        (Platform.isWindows &&
            sourceCanonical.toLowerCase() == targetCanonical.toLowerCase())) {
      throw const XmlyException('invalid_commit', '临时文件不能与成品相同');
    }
    if (await FileSystemEntity.type(source, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const XmlyException('invalid_commit', '临时音频必须是普通文件');
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        (!overwrite || type != FileSystemEntityType.file)) {
      throw const XmlyException('destination_exists', '目标已存在，请重新选择同名文件处理方式');
    }
    final handle = await File(source).open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (Platform.isWindows) {
      _WindowsFiles.commit(source, target, overwrite: overwrite);
    } else if (Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS) {
      _PosixFiles.commit(source, target, overwrite: overwrite);
    } else {
      throw const XmlyException('atomic_commit_unsupported', '当前平台不支持安全提交文件');
    }
  }

  static String _absoluteRoot(String root) {
    if (root.isEmpty || root.contains('\x00') || !p.isAbsolute(root)) {
      throw const XmlyException('download_directory', '请选择绝对路径的下载目录');
    }
    return absoluteFilePath(root);
  }

  static String _shorten(String text, int units, int bytes) {
    final result = StringBuffer();
    var usedUnits = 0, usedBytes = 0;
    for (final rune in text.runes) {
      final value = String.fromCharCode(rune);
      final size = utf8.encode(value).length;
      if (usedUnits + value.length > units || usedBytes + size > bytes) break;
      result.write(value);
      usedUnits += value.length;
      usedBytes += size;
    }
    return result.toString();
  }

  static Future<int> _availableBytes(String root) async {
    if (Platform.isAndroid) {
      try {
        return await AndroidPlatform.availableBytes(root);
      } catch (_) {
        throw const XmlyException('disk_space_unavailable', '无法查询下载目录的可用空间');
      }
    }
    if (Platform.isWindows) {
      return using((arena) {
        final path = root.toNativeUtf16(allocator: arena);
        final free = arena<Uint64>();
        final result = win.GetDiskFreeSpaceEx(
          win.PCWSTR(path),
          free,
          nullptr,
          nullptr,
        );
        if (!result.value) {
          throw const XmlyException('disk_space_unavailable', '无法查询下载目录的可用空间');
        }
        return free.value;
      });
    }
    if (!(Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS)) {
      throw const XmlyException('disk_space_unsupported', '当前平台不支持查询可用空间');
    }
    try {
      final result = await Process.run(
        'df',
        ['-Pk', root],
        runInShell: false,
        environment: {'LC_ALL': 'C'},
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode == 0) {
        final rows = const LineSplitter().convert(result.stdout.toString());
        final values = rows
            .skip(1)
            .map(
              (line) =>
                  RegExp(r'^\S+\s+\d+\s+\d+\s+(\d+)\s+\d+%\s').firstMatch(line),
            )
            .whereType<RegExpMatch>()
            .toList();
        if (values.length == 1) {
          final blocks = int.tryParse(values.single[1]!);
          if (blocks != null &&
              blocks >= 0 &&
              blocks <= 0x7fffffffffffffff ~/ 1024)
            return blocks * 1024;
        }
      }
    } on ProcessException {
      throw const XmlyException('disk_space_unsupported', '当前平台缺少可用空间查询工具');
    }
    throw const XmlyException('disk_space_unavailable', '无法查询下载目录的可用空间');
  }
}

class _PosixFiles {
  static final _library = DynamicLibrary.process();
  static final _rename = _library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('rename');
  static final _link = _library
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('link');
  // Lazy bindings used only by Android's no-overwrite branch. The public
  // renameat2 symbol requires API 30, but syscall is available at minSdk 24.
  static final _androidSyscall = _library
      .lookupFunction<
        Long Function(
          Long,
          VarArgs<(Int, Pointer<Utf8>, Int, Pointer<Utf8>, UnsignedInt)>,
        ),
        int Function(int, int, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('syscall');
  static final _androidErrno = _library
      .lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>(
        '__errno',
      );

  static void _androidRenameNoReplace(Pointer<Utf8> from, Pointer<Utf8> to) {
    final number = switch (Abi.current()) {
      Abi.androidArm => 382,
      Abi.androidArm64 => 276,
      Abi.androidX64 => 316,
      _ => throw const XmlyException(
        'atomic_commit_unsupported',
        '当前 Android 架构不支持安全提交文件，请更换设备',
      ),
    };
    // Resolve both bindings before the call so lookup cannot disturb errno.
    final syscall = _androidSyscall;
    final errno = _androidErrno;
    // Android external-storage FUSE has no hardlink support. RENAME_NOREPLACE
    // atomically refuses an existing target; never fall back to check + rename.
    if (syscall(number, -100, from, -100, to, 1) == 0) return;
    final error = errno().value;
    final code = switch (error) {
      17 => 'destination_exists', // EEXIST
      18 => 'atomic_commit_cross_device', // EXDEV
      38 || 22 || 95 => 'atomic_commit_unsupported', // ENOSYS/EINVAL/EOPNOTSUPP
      1 || 13 => 'download_not_writable', // EPERM/EACCES
      28 => 'disk_space', // ENOSPC
      _ => 'atomic_commit',
    };
    throw XmlyException(code, '文件安全提交失败，源缓存已保留（errno=$error）');
  }

  static void commit(String source, String target, {required bool overwrite}) {
    using((arena) {
      final from = source.toNativeUtf8(allocator: arena);
      final to = target.toNativeUtf8(allocator: arena);
      if (Platform.isAndroid && !overwrite) {
        _androidRenameNoReplace(from, to);
      } else {
        // Other POSIX platforms retain link's atomic no-clobber behavior.
        // Both operations refuse cross-volume moves without a copy fallback.
        if ((overwrite ? _rename(from, to) : _link(from, to)) != 0) {
          throw FileSystemException('无法原子提交音频，原文件与缓存已保留', target);
        }
      }
    });
    if (!overwrite && !Platform.isAndroid) {
      try {
        File(source).deleteSync();
      } on FileSystemException {
        // Destination is already committed; an extra temporary link is safe.
      }
    }
  }
}

class _WindowsFiles {
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

  static String _longPath(String path) => path.startsWith(r'\\?\')
      ? path
      : path.startsWith(r'\\')
      ? '${r'\\?\UNC\'}${path.substring(2)}'
      : '${r'\\?\'}$path';

  static void commit(String source, String target, {required bool overwrite}) {
    using((arena) {
      final from = _longPath(source).toNativeUtf16(allocator: arena);
      final to = _longPath(target).toNativeUtf16(allocator: arena);
      if (!overwrite || !File(target).existsSync()) {
        if (!win.MoveFileEx(
          win.PCWSTR(from),
          win.PCWSTR(to),
          win.MOVEFILE_WRITE_THROUGH,
        ).value) {
          throw FileSystemException('无法原子提交音频，原文件与缓存已保留', target);
        }
        return;
      }
      final backupPath = '$target.${const Uuid().v4()}.backup';
      final backup = _longPath(backupPath).toNativeUtf16(allocator: arena);
      if (_replace(to, from, backup, 0, nullptr, nullptr) == 0) {
        // ReplaceFile may have moved the original aside before an I/O failure.
        if (!File(target).existsSync() && File(backupPath).existsSync()) {
          if (!win.MoveFileEx(
            win.PCWSTR(backup),
            win.PCWSTR(to),
            win.MOVEFILE_WRITE_THROUGH,
          ).value) {
            throw FileSystemException('音频提交失败，请保留原文件备份', backupPath);
          }
        }
        throw FileSystemException('无法替换音频，原文件与缓存已保留', target);
      }
      try {
        File(backupPath).deleteSync();
      } on FileSystemException {
        // New validated destination is authoritative; do not turn cleanup into
        // a processing failure after the atomic replacement succeeded.
      }
    });
  }
}
