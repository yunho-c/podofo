// import 'package:flutter/material.dart';

import 'package:shadcn_flutter/shadcn_flutter.dart';

class CommandPalette extends StatelessWidget {
  const CommandPalette({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 600,
        height: 400,
        decoration: BoxDecoration(
          // color: Theme.of(context).colorScheme.surface,
          color: Theme.of(context).colorScheme.background,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(50),
              spreadRadius: 5,
              blurRadius: 7,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Column(
          children: [
            TextField(
              autofocus: true,
              // decoration: InputDecoration(
              //   contentPadding: EdgeInsets.all(16),
              //   border: InputBorder.none,
              //   hintText: 'Search files by name',
              // ),
            ),
            Divider(height: 1),
            Expanded(child: Center(child: Text('No results found'))),
          ],
        ),
      ),
    );
  }
}
