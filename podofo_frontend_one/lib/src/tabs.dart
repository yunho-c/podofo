import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class Tab {
  Tab({required this.title, required this.child});
  final String title;
  final Widget child;
}

final List<Tab> initialTabs = [
  Tab(
    title: 'README.md',
    child: const Center(child: Text('README.md')),
  ),
  Tab(
    title: 'Relativity.pdf',
    child: const Center(child: Text('Relativity.pdf')),
  ),
];

final tabsProvider = StateProvider<List<Tab>>((ref) => initialTabs);

final currentTabIndexProvider = StateProvider<int>((ref) => 0);
