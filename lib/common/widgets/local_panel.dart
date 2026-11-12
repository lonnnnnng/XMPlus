import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps short player tasks over the current page on both phones and desktops.
Future<T?> showLocalPanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double width = 520,
  double height = 680,
}) {
  Widget frame(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    clipBehavior: Clip.antiAlias,
    borderRadius: BorderRadius.circular(24),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '收起$title',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: builder(context)),
      ],
    ),
  );

  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        alignment: Alignment.centerRight,
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(width: width, height: height, child: frame(context)),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // Drag dismissal calls pop directly and bypasses forms' saving PopScopes.
    enableDrag: false,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          height: math.min(height, constraints.maxHeight * 0.9),
          child: frame(context),
        ),
      ),
    ),
  );
}
