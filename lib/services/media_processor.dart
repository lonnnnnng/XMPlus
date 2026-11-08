import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../models/download_task.dart';
import '../models/xmly_models.dart';
import 'download_paths.dart';
import 'android_platform.dart';

import 'request_diagnostics.dart';
import 'network_retry.dart';

class MediaResult {
  MediaResult({
    required this.path,
    required List<String> warnings,
    required this.probe,
  }) : warnings = List.unmodifiable(warnings);
  final String path;
  final List<String> warnings;
  final Map<String, dynamic> probe;
}

/// Local, silent processing only. The transfer layer retains ownership of source
/// files and cache blocks, including on cancellation or processing failure.
class MediaProcessor {
  MediaProcessor({
    String? ffmpegPath,
    String? ffprobePath,
    String? executableDirectory,
    DownloadPaths? paths,
  }) : ffmpegPath = Platform.isAndroid
           ? 'libxmplus_ffmpeg.so'
           : ffmpegPath ?? _tool(executableDirectory, 'ffmpeg'),
       ffprobePath = Platform.isAndroid
           ? 'libxmplus_ffprobe.so'
           : ffprobePath ?? _tool(executableDirectory, 'ffprobe'),
       _paths = paths ?? DownloadPaths();

  final String ffmpegPath, ffprobePath;
  final DownloadPaths _paths;
  // ponytail: serialize final-name selection and commits within this process;
  // the data-directory writer lock excludes a second application writer.
  static final Lock _outputs = Lock();
  static const _limit = 2 * 1024 * 1024;
  static const _protocols = ['-protocol_whitelist', 'file,pipe'];

  static String _tool(String? directory, String name) {
    final executableDirectory =
        directory ?? p.dirname(Platform.resolvedExecutable);
    // long: Mac 辅助程序放在签名认可的 Helpers 目录，移动 .app 后仍可直接使用。
    if (Platform.isMacOS)
      return p.normalize(p.join(executableDirectory, '..', 'Helpers', name));
    return p.join(
      executableDirectory,
      'tools',
      'ffmpeg',
      '$name${Platform.isWindows ? '.exe' : ''}',
    );
  }

  Future<void> checkTools({Future<void> Function()? checkpoint}) =>
      _checkTools(checkpoint);

  Future<void> _checkTools(Future<void> Function()? checkpoint) async {
    for (final entry in [(ffmpegPath, 'ffmpeg'), (ffprobePath, 'ffprobe')]) {
      final output = await _run(
        entry.$1,
        ['-version'],
        checkpoint: checkpoint,
        timeout: const Duration(seconds: 15),
      );
      if (!output.startsWith('${entry.$2} version ')) {
        throw const XmlyException('media_tool', '媒体工具无效，请检查工具路径');
      }
    }
  }

  Future<Map<String, dynamic>> probe(String path) => _probe(path, null);

  Future<Map<String, dynamic>> _probe(
    String path,
    Future<void> Function()? checkpoint,
  ) async {
    final local = await _localFile(path);
    final output = await _run(
      ffprobePath,
      [
        '-v',
        'error',
        ..._protocols,
        '-show_format',
        '-show_streams',
        '-of',
        'json',
        local,
      ],
      checkpoint: checkpoint,
      timeout: const Duration(seconds: 45),
    );
    try {
      final result = xmlyMap(jsonDecode(output));
      _audio(result);
      _duration(result);
      return result;
    } on FormatException {
      throw const XmlyException('media_probe', '无法识别有效音频');
    }
  }

  /// Hashes compressed audio packets, not decoded PCM, so original-mode
  /// remuxing must preserve both the codec and the encoded audio stream.
  Future<String> audioHash(String path) => _audioHash(path, null);

  Future<String> _audioHash(
    String path,
    Future<void> Function()? checkpoint, {
    Map<String, dynamic>? details,
  }) async {
    final local = await _localFile(path);
    final input = details ?? await _probe(local, checkpoint);
    final adts = '${xmlyMap(input['format'])['format_name']}'
        .split(',')
        .contains('aac');
    final output = await _run(ffmpegPath, [
      '-v',
      'error',
      '-nostdin',
      ..._protocols,
      '-i',
      local,
      '-map',
      '0:a:0',
      '-c:a',
      'copy',
      if (adts) ...['-bsf:a', 'aac_adtstoasc'],
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ], checkpoint: checkpoint);
    final match = RegExp(r'^SHA256=([a-fA-F0-9]{64})\s*$')
        .firstMatch(output.trim());
    if (match == null) throw const XmlyException('media_hash', '无法校验原始音频流');
    return match[1]!.toLowerCase();
  }

  Future<MediaResult> process({
    required String sourcePath,
    required DownloadTask task,
    Future<void> Function()? checkpoint,
  }) async {
    final media = xmlyMap(task.settings['media']);
    final configured = MediaProcessor(
      ffmpegPath: _override(media, 'ffmpegPath', ffmpegPath),
      ffprobePath: _override(media, 'ffprobePath', ffprobePath),
      paths: _paths,
    );
    Future<void> checked() async {
      try {
        await checkpoint?.call();
      } catch (error, stack) {
        throw _MediaCancelled(error, stack);
      }
    }

    try {
      return await configured._process(sourcePath, task, checked);
    } on _MediaCancelled catch (error) {
      Error.throwWithStackTrace(error.error, error.stack);
    }
  }

  static String _override(
    Map<String, dynamic> options,
    String key,
    String fallback,
  ) {
    if (Platform.isAndroid) return fallback;
    final value = options[key];
    if (value == null || value == '') return fallback;
    if (value is! String || !p.isAbsolute(value)) {
      throw const XmlyException('media_tool', '请选择媒体工具的完整路径');
    }
    return value;
  }

  Future<MediaResult> _process(
    String sourcePath,
    DownloadTask task,
    Future<void> Function()? checkpoint,
  ) async {
    await checkpoint?.call();
    final source = await _localFile(sourcePath);
    await _checkTools(checkpoint);
    final input = await _probe(source, checkpoint);
    await _decode(source, checkpoint);
    final sourceAudio = _audio(input);
    final media = xmlyMap(task.settings['media']);
    final tags = xmlyMap(task.settings['tags']);
    final format = media['format'] ?? 'original';
    if (!const {'original', 'mp3', 'm4a', 'm4b', 'flac'}.contains(format)) {
      throw const XmlyException('media_format', '请选择支持的输出格式');
    }
    final bitrate = media['bitrateKbps'] ?? 64;
    if (const {'mp3', 'm4a', 'm4b'}.contains(format) &&
        !const {32, 64, 96, 128, 192}.contains(bitrate)) {
      throw const XmlyException('media_bitrate', '音频码率无效');
    }
    final extension = format == 'original'
        ? _originalExtension(input)
        : format as String;
    final tagging = _boolean(tags, 'enabled', true);
    final coverEnabled = tagging && _boolean(tags, 'cover', false);
    final download = xmlyMap(task.settings['download']);
    final minimum = download['minimumFreeMiB'] ?? 512;
    if (minimum is! int) throw const XmlyException('invalid_space', '可用空间设置无效');
    final sourceSize = await File(source).length();
    // Lossless PCM-derived FLAC may be much larger than a compressed source.
    final pcmReserve =
        (_duration(input) *
                (int.tryParse('${sourceAudio['sample_rate']}') ?? 48000) *
                ((sourceAudio['channels'] as num?)?.toInt() ?? 2) *
                4)
            .ceil();
    await _paths.checkRoot(
      task.rootDirectory,
      minimumFreeMiB: minimum,
      reserveBytes: math.max(sourceSize * 2, pcmReserve),
    );
    final total =
        xmlyPositive(task.track.raw['totalCount']) ??
        xmlyPositive(task.track.raw['total']);
    final target = _paths.targetPath(
      root: task.rootDirectory,
      track: task.track,
      extension: extension,
      settings: task.settings,
      totalTracks: total,
    );
    await Directory(p.dirname(target)).create(recursive: true);
    final sourceDigest = await _fileHash(source, checkpoint);
    final signature = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'task': task.id,
              'account': task.accountIdentity,
              'track': task.track.toJson(),
              'media': media,
              'tags': tags,
              'source': sourceDigest,
            }),
          ),
        )
        .toString();
    final originalHash = format == 'original'
        ? await _audioHash(source, checkpoint, details: input)
        : null;
    final warnings = <String>[];
    return _outputs.synchronized(() async {
      await checkpoint?.call();
      final conflict = download['conflict'] ?? 'skip';
      if (conflict is! String)
        throw const XmlyException('invalid_conflict', '同名文件处理方式无效');
      // A numbered result from an earlier completion belongs to this task too.
      final prior = task.finalPath;
      if (conflict == 'skip') {
        for (final candidate in {
          target,
          if (prior != null && p.isWithin(task.rootDirectory, prior)) prior,
        }) {
          final verified = await _existing(
            candidate,
            signature,
            input,
            format as String,
            originalHash,
            checkpoint,
          );
          if (verified != null)
            return MediaResult(
              path: candidate,
              warnings: warnings,
              probe: verified,
            );
        }
      }
      final destination = await _paths.chooseDestination(
        target,
        conflict: conflict,
      );
      if (p.equals(source, p.normalize(p.absolute(destination)))) {
        throw const XmlyException('invalid_commit', '源音频不能作为输出文件');
      }
      if (conflict == 'skip' &&
          await FileSystemEntity.type(destination, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw const XmlyException('destination_exists', '同名文件无法验证，请选择覆盖或添加编号');
      }
      final temporary = await Directory(p.dirname(destination))
          .createTemp('.xmplus-media-');
      try {
        final output = p.join(temporary.path, 'output.$extension');
        String? cover;
        if (coverEnabled && task.track.coverUrl != null) {
          if (const {'mp3', 'm4a', 'm4b', 'flac'}.contains(extension)) {
            try {
              cover = await _cover(
                task.track.coverUrl!,
                temporary.path,
                checkpoint,
              );
              final image = xmlyMap(
                jsonDecode(
                  await _run(
                    ffprobePath,
                    [
                      '-v',
                      'error',
                      ..._protocols,
                      '-select_streams',
                      'v:0',
                      '-show_entries',
                      'stream=codec_name,width,height',
                      '-of',
                      'json',
                      cover,
                    ],
                    checkpoint: checkpoint,
                    timeout: const Duration(seconds: 15),
                  ),
                ),
              );
              final streams = image['streams'];
              final stream = streams is List && streams.length == 1
                  ? xmlyMap(streams.first)
                  : const <String, dynamic>{};
              if (!const {'png', 'mjpeg'}.contains(stream['codec_name']) ||
                  stream['width'] is! num ||
                  stream['height'] is! num ||
                  (stream['width'] as num) <= 0 ||
                  (stream['height'] as num) <= 0 ||
                  (stream['width'] as num) * (stream['height'] as num) >
                      40000000) {
                throw const FormatException('Invalid cover dimensions');
              }
              await _run(
                ffmpegPath,
                [
                  '-v',
                  'error',
                  '-xerror',
                  '-nostdin',
                  ..._protocols,
                  '-i',
                  cover,
                  '-map',
                  '0:v:0',
                  '-frames:v',
                  '1',
                  '-f',
                  'null',
                  '-',
                ],
                checkpoint: checkpoint,
                timeout: const Duration(seconds: 15),
              );
            } on _MediaCancelled {
              rethrow;
            } catch (_) {
              cover = null;
              warnings.add('封面获取失败，已保留音频');
            }
          } else {
            warnings.add('此格式不支持内嵌封面，已保留音频');
          }
        }
        final originalFormats = '${xmlyMap(input['format'])['format_name']}'
            .split(',');
        if (format == 'original' &&
            !tagging &&
            originalFormats.contains(extension)) {
          await _copy(source, output, checkpoint);
        } else {
          final args = [
            '-v',
            'error',
            '-nostdin',
            '-y',
            ..._protocols,
            '-i',
            source,
            if (cover != null) ...[..._protocols, '-i', cover],
            '-map',
            '0:a:0',
            if (cover != null) ...['-map', '1:v:0'],
            '-map_metadata',
            tagging || format == 'original' ? '0' : '-1',
            '-map_chapters',
            '-1',
            '-c:a',
            switch (format) {
              'original' => 'copy',
              'mp3' => 'libmp3lame',
              'flac' => 'flac',
              _ => 'aac',
            },
            if (const {'mp3', 'm4a', 'm4b'}.contains(format)) ...[
              '-b:a',
              '${bitrate}k',
            ],
            if (cover != null) ...[
              '-c:v',
              'copy',
              '-disposition:v:0',
              'attached_pic',
              '-metadata:s:v:0',
              'title=Album cover',
              '-metadata:s:v:0',
              'comment=Cover (front)',
            ],
            if (tagging) ..._metadata(task, tags, total),
            if (extension == 'mp3') ...['-id3v2_version', '3'],
            if (const {'m4a', 'm4b'}.contains(extension)) ...[
              '-movflags',
              '+faststart',
              '-metadata',
              'media_type=2',
              '-f',
              'mp4',
            ],
            output,
          ];
          await _run(ffmpegPath, args, checkpoint: checkpoint);
        }
        final outputProbe = await _probe(output, checkpoint);
        _compatible(input, outputProbe, format as String);
        if (cover != null &&
            !(outputProbe['streams'] as List).any(
              (stream) =>
                  xmlyMap(stream)['codec_type'] == 'video' &&
                  xmlyMap(xmlyMap(stream)['disposition'])['attached_pic'] == 1,
            )) {
          warnings.add('封面未能写入，已保留音频');
        }
        await _decode(output, checkpoint);
        if (originalHash != null &&
            originalHash !=
                await _audioHash(output, checkpoint, details: outputProbe)) {
          throw const XmlyException(
            'media_stream_changed',
            '原始音频流校验失败，请选择其他格式',
          );
        }
        final digest = await _fileHash(output, checkpoint);
        final manifest = File(p.join(temporary.path, 'manifest.json'));
        await manifest.writeAsString(
          jsonEncode({
            'version': 1,
            'signature': signature,
            'sha256': digest,
            'bytes': await File(output).length(),
          }),
          flush: true,
        );
        await checkpoint?.call();
        // No checkpoint after the atomic commit: a completed output is a success.
        await _paths.commit(
          output,
          destination,
          overwrite: conflict == 'overwrite',
        );
        try {
          await _paths.commit(
            manifest.path,
            '$destination.xmplus-media.json',
            overwrite: true,
          );
        } catch (_) {
          warnings.add('校验记录保存失败，重试时不会自动跳过此文件');
        }
        return MediaResult(
          path: destination,
          warnings: warnings,
          probe: outputProbe,
        );
      } finally {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          /* Only disposable processor output. */
        }
      }
    });
  }

  Future<Map<String, dynamic>?> _existing(
    String path,
    String signature,
    Map<String, dynamic> input,
    String format,
    String? originalHash,
    Future<void> Function()? checkpoint,
  ) async {
    await checkpoint?.call();
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file)
        return null;
      final manifest = File('$path.xmplus-media.json');
      if (!await manifest.exists() || await manifest.length() > 16384)
        return null;
      final saved = xmlyMap(jsonDecode(await manifest.readAsString()));
      if (saved['version'] != 1 ||
          saved['signature'] != signature ||
          saved['bytes'] != await File(path).length() ||
          saved['sha256'] != await _fileHash(path, checkpoint))
        return null;
      final result = await _probe(path, checkpoint);
      _compatible(input, result, format);
      await _decode(path, checkpoint);
      if (originalHash != null &&
          originalHash != await _audioHash(path, checkpoint, details: result))
        return null;
      return result;
    } on _MediaCancelled {
      rethrow;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on XmlyException {
      return null;
    }
  }

  static bool _boolean(
    Map<String, dynamic> options,
    String key,
    bool fallback,
  ) {
    final value = options[key] ?? fallback;
    if (value is! bool) throw const XmlyException('media_settings', '媒体设置无效');
    return value;
  }

  static Map<String, dynamic> _audio(Map<String, dynamic> probe) {
    final streams = probe['streams'];
    if (streams is List) {
      for (final stream in streams) {
        final value = xmlyMap(stream);
        if (value['codec_type'] == 'audio' &&
            value['codec_name'] is String &&
            value['codec_name'] != 'unknown')
          return value;
      }
    }
    throw const XmlyException('media_probe', '文件中没有有效音轨');
  }

  static double _duration(Map<String, dynamic> probe) {
    final duration =
        double.tryParse('${_audio(probe)['duration']}') ??
        double.tryParse('${xmlyMap(probe['format'])['duration']}');
    if (duration == null || !duration.isFinite || duration <= 0) {
      throw const XmlyException('media_probe', '无法取得有效音频时长');
    }
    return duration;
  }

  static String _originalExtension(Map<String, dynamic> input) {
    final formats = '${xmlyMap(input['format'])['format_name']}'
        .split(',')
        .toSet();
    final codec = _audio(input)['codec_name'] as String;
    if (formats.contains('mp3') && codec == 'mp3') return 'mp3';
    if (formats.intersection({
          'mov',
          'mp4',
          'm4a',
          '3gp',
          '3g2',
          'mj2',
        }).isNotEmpty &&
        const {'aac', 'alac', 'mp3'}.contains(codec))
      return 'm4a';
    if (formats.contains('flac') && codec == 'flac') return 'flac';
    if (formats.contains('ogg') &&
        const {'vorbis', 'opus', 'flac'}.contains(codec))
      return 'ogg';
    if (formats.contains('wav') && codec.startsWith('pcm_')) return 'wav';
    // ADTS AAC packets can be losslessly remuxed to MP4, without trusting a URL extension.
    if (formats.contains('aac') && codec == 'aac') return 'm4a';
    throw const XmlyException(
      'media_original_unsupported',
      '此源格式不能原样写入标签，请选择 MP3、M4A 或 FLAC',
    );
  }

  static List<String> _metadata(
    DownloadTask task,
    Map<String, dynamic> options,
    int? total,
  ) {
    final track = task.track;
    final overrides = xmlyMap(options['overrides']);
    const allowed = {'titlePrefix', 'album', 'artist', 'genre', 'description'};
    for (final entry in overrides.entries) {
      if (!allowed.contains(entry.key) ||
          entry.value is! String ||
          (entry.value as String).length > 65536 ||
          (entry.value as String).contains('\u0000')) {
        throw const XmlyException('media_tags', '标签内容无效');
      }
    }
    String value(String key, String fallback) =>
        overrides.containsKey(key) ? overrides[key] as String : fallback;
    final order = track.orderNo ?? track.officialPosition;
    final tags = <String, String>{
      'title': '${value('titlePrefix', '')}${track.title}',
      'album': value('album', track.album),
      'artist': value('artist', track.artist),
      'album_artist': value('artist', track.artist),
      'genre': value('genre', 'Audiobook'),
      'comment': 'https://www.ximalaya.com/sound/${track.number}',
      if (order != null) 'track': total != null ? '$order/$total' : '$order',
      if (track.intro.isNotEmpty || overrides.containsKey('description'))
        'description': value('description', track.intro),
    };
    final year = '${track.raw['year'] ?? ''}';
    if (RegExp(r'^[12][0-9]{3}$').hasMatch(year)) tags['date'] = year;
    return [
      for (final entry in tags.entries) ...[
        '-metadata',
        '${entry.key}=${entry.value}',
      ],
    ];
  }

  static void _compatible(
    Map<String, dynamic> input,
    Map<String, dynamic> output,
    String format,
  ) {
    final source = _audio(input), result = _audio(output);
    final expected = switch (format) {
      'original' => source['codec_name'],
      'mp3' => 'mp3',
      'flac' => 'flac',
      _ => 'aac',
    };
    final before = _duration(input), after = _duration(output);
    final extension = format == 'original' ? _originalExtension(input) : format;
    final containers = '${xmlyMap(output['format'])['format_name']}'
        .split(',')
        .toSet();
    final expectedContainers = switch (extension) {
      'm4a' || 'm4b' => const {'mov', 'mp4', 'm4a'},
      _ => {extension},
    };
    if (containers.intersection(expectedContainers).isEmpty) {
      throw const XmlyException('media_validation', '输出容器校验失败');
    }
    if (result['codec_name'] != expected ||
        (before - after).abs() > math.max(2.0, before * .01) ||
        source['sample_rate'] != result['sample_rate'] ||
        source['channels'] != result['channels']) {
      throw const XmlyException('media_validation', '处理后的音轨、时长或声道校验失败');
    }
  }

  Future<void> _decode(String path, Future<void> Function()? checkpoint) async {
    await _run(ffmpegPath, [
      '-v',
      'error',
      '-xerror',
      '-nostdin',
      ..._protocols,
      '-i',
      path,
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ], checkpoint: checkpoint);
  }

  static Future<String> _localFile(String value) async {
    if (!p.isAbsolute(value) ||
        value.contains('\u0000') ||
        value.startsWith(r'\\') ||
        value.startsWith('//') ||
        await FileSystemEntity.type(value, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const XmlyException('media_local_file', '媒体处理只接受本地音频文件');
    }
    return File(value).resolveSymbolicLinks();
  }

  static Future<String> _fileHash(
    String path,
    Future<void> Function()? checkpoint,
  ) async {
    final sink = _DigestSink();
    final converter = sha256.startChunkedConversion(sink);
    await for (final bytes in File(path).openRead()) {
      await checkpoint?.call();
      converter.add(bytes);
    }
    converter.close();
    return sink.value!.toString();
  }

  static Future<void> _copy(
    String source,
    String target,
    Future<void> Function()? checkpoint,
  ) async {
    final output = await File(target).open(mode: FileMode.writeOnly);
    try {
      await for (final bytes in File(source).openRead()) {
        await checkpoint?.call();
        await output.writeFrom(bytes);
      }
      await output.flush();
    } finally {
      await output.close();
    }
  }

  static Future<String> _cover(
    Uri initial,
    String directory,
    Future<void> Function()? checkpoint,
  ) async {
    for (var attempt = 0; ; attempt++) {
      await checkpoint?.call();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final addresses = await _safeCoverUri(uri);
        return uri.scheme == 'https'
            ? SecureSocket.startConnect(addresses.first, uri.port)
            : Socket.startConnect(addresses.first, uri.port);
      };
      // Retry-After is outside this per-attempt redirect/body deadline.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Future<T> wait<T>(Future<T> future) async {
        final pending = future.then<Object>(
          (value) => (value,),
          onError: (Object error, StackTrace stack) => (error, stack),
        );
        while (true) {
          await checkpoint?.call();
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) throw TimeoutException('Cover timeout');
          final outcome = await Future.any<Object?>([
            pending,
            Future<void>.delayed(
              left < const Duration(milliseconds: 100)
                  ? left
                  : const Duration(milliseconds: 100),
            ).then<Object?>((_) => null),
          ]);
          if (outcome case (Object error, StackTrace stack)) {
            Error.throwWithStackTrace(error, stack);
          }
          if (outcome != null) return (outcome as (T,)).$1;
        }
      }

      RequestDiagnostic? diagnostic;
      HttpClientResponse? response;
      var definitive = false;
      Duration? delay;
      try {
        var uri = initial;
        for (var redirects = 0; redirects <= 5; redirects++) {
          response = null;
          diagnostic = null;
          final bytes = <int>[];
          diagnostic = RequestDiagnostic(
            account: '公共嵌入封面（无账号）',
            method: 'GET',
            url: '$uri',
          )..responseByteCount = (() => bytes.length);
          await wait(_safeCoverUri(uri));
          response = null;
          final request = await wait(client.getUrl(uri));
          request.followRedirects = false;
          request.headers.forEach((name, values) {
            diagnostic!.requestHeaders[name] = List<String>.of(values);
          });
          final current = await wait(request.close());
          response = current;
          diagnostic
            ..status = current.statusCode
            ..completeness = '响应体接收中；失败时保留全部已接收字节';
          current.headers.forEach((name, values) {
            diagnostic!.responseHeaders[name] = List<String>.of(values);
          });
          final redirect = const {
            301,
            302,
            303,
            307,
            308,
          }.contains(current.statusCode);
          final location = current.headers.value(HttpHeaders.locationHeader);
          if (redirect && location != null && redirects < 5) {
            await current.listen((_) {}).cancel();
            uri = uri.resolve(location);
            continue;
          }
          const limit = 5 * 1024 * 1024;
          if (current.contentLength > limit) {
            definitive = true;
            diagnostic.completeness = '未读取响应体：Content-Length 超过 5 MiB 安全上限';
            throw const HttpException('Cover too large');
          }
          final iterator = StreamIterator(current);
          try {
            while (await wait(iterator.moveNext())) {
              final room = limit - bytes.length;
              if (iterator.current.length > room) {
                bytes.addAll(iterator.current.take(room));
                definitive = true;
                diagnostic.completeness = '响应体超过 5 MiB 安全上限；已捕获上限内全部字节';
                throw const HttpException('Cover too large');
              }
              bytes.addAll(iterator.current);
            }
          } finally {
            await iterator.cancel();
          }
          diagnostic.completeness = '完整响应体';
          if (redirect || current.statusCode != 200) {
            definitive = redirect || !retryableStatus(current.statusCode);
            throw HttpException(
              'Invalid cover response: HTTP ${current.statusCode}',
            );
          }
          definitive = true;
          final png =
              bytes.length >= 8 &&
              const [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every(
                (entry) => bytes[entry.key] == entry.value,
              );
          final jpeg =
              bytes.length >= 3 &&
              bytes[0] == 255 &&
              bytes[1] == 216 &&
              bytes[2] == 255;
          if (!png && !jpeg) throw const FormatException('Invalid cover image');
          await checkpoint?.call();
          final file = File(p.join(directory, png ? 'cover.png' : 'cover.jpg'));
          await file.writeAsBytes(bytes, flush: true);
          return file.path;
        }
        throw const FormatException('Cover redirect limit');
      } catch (error) {
        if (retryableTransport(error)) diagnostic?.transportError = '$error';
        await diagnostic?.fail(error);
        if (definitive ||
            attempt == 4 ||
            error is FormatException ||
            error is TlsException ||
            error is _MediaCancelled ||
            !(retryableStatus(response?.statusCode) ||
                retryableTransport(error)))
          rethrow;
        delay = retryDelay(
          attempt,
          response?.headers.value(HttpHeaders.retryAfterHeader),
        );
      } finally {
        client.close(force: true);
      }
      await waitToRetry(delay, checkpoint: checkpoint);
    }
  }

  static Future<List<InternetAddress>> _safeCoverUri(Uri uri) async {
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 80 && uri.port != 443) ||
        uri.toString().length > 16384)
      throw const FormatException('Invalid cover URL');
    final addresses = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 10));
    if (addresses.isEmpty ||
        addresses.any((address) {
          final bytes = address.rawAddress;
          if (address.type == InternetAddressType.IPv4) {
            return bytes[0] == 0 ||
                bytes[0] == 10 ||
                bytes[0] == 127 ||
                bytes[0] >= 224 ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 &&
                    (bytes[1] == 168 ||
                        (bytes[1] == 0 && (bytes[2] == 0 || bytes[2] == 2)))) ||
                (bytes[0] == 198 &&
                    (bytes[1] == 18 ||
                        bytes[1] == 19 ||
                        (bytes[1] == 51 && bytes[2] == 100))) ||
                (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) ||
                (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
          }
          return (bytes[0] & 0xe0) !=
              0x20; // Only global IPv6 unicast, never mapped IPv4.
        }))
      throw const FormatException('Non-public cover URL');
    return addresses;
  }

  Future<String> _run(
    String executable,
    List<String> arguments, {
    Future<void> Function()? checkpoint,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    await checkpoint?.call();
    if (Platform.isAndroid) {
      final tools = await AndroidPlatform.mediaToolPaths();
      executable = tools[executable == ffmpegPath ? 'ffmpeg' : 'ffprobe']!;
    }
    Process process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
    } on ProcessException {
      if (Platform.isAndroid) {
        throw const XmlyException(
          'media_tool_missing',
          '随附 Android FFmpeg/FFprobe 无法启动，请重新安装完整安装包；源缓存已保留，在线收听不受影响',
        );
      }
      throw const XmlyException('media_tool_missing', '无法启动媒体工具，请检查路径');
    }
    final stdout = <int>[], stderr = <int>[];
    var overflow = false, finished = false;
    Object? stopped;
    StackTrace? stoppedStack;
    void stop(Object error, StackTrace stack) {
      stopped ??= error;
      stoppedStack ??= stack;
      process.kill(ProcessSignal.sigkill);
    }

    Future<void> drain(Stream<List<int>> stream, List<int> buffer) async {
      await for (final bytes in stream) {
        final room = _limit - buffer.length;
        if (room > 0) buffer.addAll(bytes.take(room));
        if (bytes.length > room) {
          overflow = true;
          process.kill(ProcessSignal.sigkill);
        }
      }
    }

    final out = drain(process.stdout, stdout),
        err = drain(process.stderr, stderr);
    final exited = process.exitCode.then((code) {
      finished = true;
      return code;
    });
    final timer = Timer(
      timeout,
      () => stop(
        const XmlyException('media_timeout', '媒体处理超时，源文件已保留'),
        StackTrace.current,
      ),
    );
    final monitor = () async {
      while (!finished && stopped == null && !overflow) {
        await Future.any<void>([
          exited.then((_) {}),
          Future<void>.delayed(const Duration(milliseconds: 100)),
        ]);
        if (finished) break;
        try {
          await checkpoint?.call();
        } catch (error, stack) {
          stop(error, stack);
        }
      }
    }();
    try {
      final code = await exited;
      await Future.wait([out, err, monitor]);
      if (stopped != null) Error.throwWithStackTrace(stopped!, stoppedStack!);
      if (overflow)
        throw const XmlyException('media_output_limit', '媒体工具输出异常，源文件已保留');
      if (code != 0)
        throw const XmlyException('media_process', '媒体处理失败，源文件已保留，请检查格式或工具');
      return utf8.decode(stdout, allowMalformed: true);
    } finally {
      timer.cancel();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class _MediaCancelled implements Exception {
  _MediaCancelled(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}
