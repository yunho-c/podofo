import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_diagnostics.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/photo_diagnostics_provider.dart';
import 'package:podofo_one/src/providers/theme_provider.dart' show typography;
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/panes/debug_pane.dart';

class _UserState extends UserStateNotifier {
  @override
  UserState build() => UserState();
}

void main() {
  testWidgets(
    'sidebar toggle, rejection details, session switching and empty state',
    (tester) async {
      late PdfSession session;
      late PhotoPageAnalysis analysis;
      await tester.runAsync(() async {
        await (FontLoader('Urbanist')..addFont(
              rootBundle.load(
                'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
              ),
            ))
            .load();
        await pdfrxInitialize();
        session = await PdfSession.open(
          'test/fixtures/photo_dark_mode/mixed.pdf',
        );
        analysis = await session.readLocked((pdf) => analyzePhotos(pdf, 10));
      });
      final current = StateProvider<Document?>(
        (ref) => Document(session: session),
      );
      final container = ProviderContainer(
        overrides: [
          currentDocumentProvider.overrideWith((ref) => ref.watch(current)),
          userStateNotifierProvider.overrideWith(_UserState.new),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadcnApp(
            theme: ThemeData(typography: typography),
            home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: const ValueKey('sidebar-capture'),
                child: const SizedBox(width: 250, child: DebugPane()),
              ),
            ),
          ),
        ),
      );
      Future<void> expand(String label) async {
        final trigger = find.ancestor(
          of: find.text(label),
          matching: find.byType(CollapsibleTrigger),
        );
        final button = find.descendant(
          of: trigger,
          matching: find.byType(GhostButton),
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }

      await expand('Dark Mode');
      await tester.pumpAndSettle();
      expect(container.read(showPhotoDiagnosticsProvider), isFalse);
      await tester.tap(find.byKey(const ValueKey('photo-diagnostics-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(showPhotoDiagnosticsProvider), isTrue);
      expect(find.text('Waiting for visible pages…'), findsOneWidget);
      final diagnostics = container.read(photoDiagnosticsProvider(session));
      final entry = PhotoDiagnosticEntry(
        pageNumber: 10,
        candidate: analysis.candidates.single,
        rect: const Rect.fromLTWH(.1, .1, .5, .5),
        preserved: false,
        inactiveReason: 'inversion-off',
      );
      diagnostics.publish(
        PhotoDiagnosticsSnapshot(
          revision: session.revision,
          pages: [
            PhotoDiagnosticPage(10, analysis, [entry]),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(diagnostics.value, isNotNull);
      await tester.ensureVisible(find.text('${entry.label} · rejected'));
      await expand('${entry.label} · rejected');
      await tester.pumpAndSettle();
      expect(find.text('limited-palette'), findsOneWidget);
      expect(find.textContaining('Palette cells:'), findsOneWidget);
      await tester.ensureVisible(find.text('limited-palette'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('sidebar-capture')),
        );
        final image = await boundary.toImage();
        final file = File('build/photo-dark-mode/diagnostics-sidebar.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
      });
      // The pane follows the active session and cannot expose a closed tab's data.
      container.read(current.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('Open a PDF to inspect its images.'), findsOneWidget);
      expect(find.text('limited-palette'), findsNothing);
      diagnostics.publish(null); // Safe even if auto-disposal has already run.
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(() async {
        await session.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('diagnostic outlines and labels pass pointer input through', (
    tester,
  ) async {
    var taps = 0;
    const candidate = PhotoCandidate(
      1,
      'time-budget',
      region: PhotoRegion(0, 0, 100, 100),
    );
    final entry = PhotoDiagnosticEntry(
      pageNumber: 1,
      candidate: candidate,
      rect: const Rect.fromLTWH(0, 0, 1, 1),
      preserved: false,
      inactiveReason: 'inversion-off',
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
            Positioned.fill(
              child: PhotoDiagnosticsOverlay(
                snapshot: PhotoDiagnosticsSnapshot(
                  revision: 0,
                  pages: [
                    PhotoDiagnosticPage(1, const PhotoPageAnalysis(), [entry]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.tapAt(const Offset(300, 300));
    expect(taps, 2);
  });
}
