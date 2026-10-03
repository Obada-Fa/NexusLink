import 'package:flutter/material.dart';

/// Keeps an input controller alive until the dialog route has fully unmounted.
/// showDialog's result resolves at pop, before its reverse transition ends.
class ControllerOwnedDialog extends StatefulWidget {
  const ControllerOwnedDialog({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  State<ControllerOwnedDialog> createState() => _ControllerOwnedDialogState();
}

class _ControllerOwnedDialogState extends State<ControllerOwnedDialog> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }
}
