import 'package:flutter/material.dart';

Future<bool> showConfirmationDialog(
  BuildContext context,
  Widget title, {
  Widget? content,
  String confirmLabel = '确认',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: title,
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ==
    true;
