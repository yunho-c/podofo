import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:podofo_one/src/providers/providers.dart';

class OutlinePane extends StatelessWidget {
  const OutlinePane({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Outline'));
  }
}
