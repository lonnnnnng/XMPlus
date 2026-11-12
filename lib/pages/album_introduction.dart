import 'package:flutter/material.dart';

import '../common/widgets/local_panel.dart';

/// A short catalogue summary with the complete text in a local reading panel.
class AlbumIntroduction extends StatelessWidget {
  const AlbumIntroduction({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 3,
          ellipsis: '\u2026',
        )..layout(maxWidth: constraints.maxWidth);
        final truncated = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (truncated)
              TextButton.icon(
                onPressed: () => showLocalPanel<void>(
                  context: context,
                  title: '专辑简介',
                  width: 640,
                  builder: (context) => Scrollbar(
                    child: SingleChildScrollView(
                      primary: true,
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(text),
                    ),
                  ),
                ),
                icon: const Icon(Icons.notes_rounded, size: 18),
                label: const Text('查看完整简介'),
              ),
          ],
        );
      },
    );
  }
}
