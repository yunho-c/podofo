import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/document_provider.dart';
import '../components/custom_pdf_viewer.dart';

class MainArea extends ConsumerWidget {
  const MainArea({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lease = ref.watch(
      currentDocumentProvider.select((doc) => doc?.session.lease),
    );
    return CustomPdfViewer(key: ObjectKey(lease));
  }
}
