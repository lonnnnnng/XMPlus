import 'dart:io';

import 'package:path/path.dart' as p;

/// Preserve the Windows share prefix before package:path normalizes separators.
String absoluteFilePath(String value) => p.normalize(
  p.absolute(Platform.isWindows ? value.replaceAll('/', r'\') : value),
);
