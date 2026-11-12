import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

bool retryableStatus(int? status) =>
    status == 408 ||
    status == 425 ||
    status == 429 ||
    status != null &&
        status >= 500 &&
        status <= 599 &&
        status != 501 &&
        status != 505;

bool retryableTransport(Object error) {
  if (error is HandshakeException || error is TlsException) return false;
  if (error is DioException) {
    if (error.error is HandshakeException || error.error is TlsException) {
      return false;
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => retryableStatus(
        error.response?.statusCode,
      ),
      DioExceptionType.unknown =>
        error.error != null && retryableTransport(error.error!),
      _ => false,
    };
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is HttpException;
}

/// Parse the provider's cooldown without a policy-specific upper bound. Values
/// beyond DateTime's range saturate only at the latest representable deadline.
Duration? serverRetryAfter(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  final now = DateTime.now().toUtc();
  if (RegExp(r'^[0-9]+$').hasMatch(text)) {
    final seconds = BigInt.parse(text);
    final maximum = DateTime.fromMillisecondsSinceEpoch(
      8640000000000000,
      isUtc: true,
    ).difference(now);
    final micros = seconds * BigInt.from(Duration.microsecondsPerSecond);
    return micros > BigInt.from(maximum.inMicroseconds)
        ? maximum
        : Duration(microseconds: micros.toInt());
  }
  try {
    final delay = HttpDate.parse(text).difference(now);
    return delay.isNegative ? Duration.zero : delay;
  } on HttpException {
    return null;
  }
}

Duration retryDelay(int attempt, String? retryAfter) {
  final backoff = Duration(seconds: 1 << attempt);
  final server = serverRetryAfter(retryAfter) ?? Duration.zero;
  return server > backoff ? server : backoff;
}

/// A close signal interrupts even a long server cooldown and cancels its timer.
Future<void> waitToRetry(
  Duration delay, {
  Future<void>? closed,
  Future<void> Function()? checkpoint,
}) async {
  final watch = Stopwatch()..start();
  final closing = closed?.then<bool>((_) => true);
  while (true) {
    await checkpoint?.call();
    final left = delay - watch.elapsed;
    if (left <= Duration.zero) return;
    final ready = Completer<void>();
    final timer = Timer(
      checkpoint != null && left > const Duration(milliseconds: 100)
          ? const Duration(milliseconds: 100)
          : left,
      ready.complete,
    );
    try {
      final stopped = await Future.any<bool>([
        ready.future.then((_) => false),
        if (closing != null) closing,
      ]);
      if (stopped) throw StateError('HTTP client closed');
    } finally {
      timer.cancel();
    }
  }
}
