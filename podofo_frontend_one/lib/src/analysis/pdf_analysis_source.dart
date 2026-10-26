import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../services/pdf_session.dart';
import 'pdf_image_input.dart';

/// Layout-only experimental raster policy. Formula resolution is qualified
/// separately. pdfrx already applies CropBox and page rotation.
const layoutRenderProfile =
    'pdfrx-0.6.1-white-no-annotations-144dpi-edge2048-v1';

podoco.DocumentRef analysisDocumentRef(PdfSession session) =>
    podoco.DocumentRef(
      sha256.convert(utf8.encode(session.path)).toString(),
      session.analysisRevision,
    );

({int width, int height}) analysisRasterSize(
  double width,
  double height,
  int byteBudget,
) {
  if (!width.isFinite ||
      !height.isFinite ||
      width <= 0 ||
      height <= 0 ||
      byteBudget < 4) {
    throw ArgumentError('Invalid analysis raster dimensions or budget');
  }
  final scale = math.min(
    2.0,
    math.min(
      2048 / math.max(width, height),
      math.sqrt(byteBudget / (4.0 * width * height)),
    ),
  );
  final w = math.max(1, (width * scale).floor());
  final h = math.max(1, (height * scale).floor());
  if (w * h * 4 > byteBudget) {
    throw const podoco.PodocoException(
      'limit_exceeded',
      'Page aspect ratio exceeds raster budget',
    );
  }
  return (width: w, height: h);
}

/// Canonical displayed page points map directly to pdfrx's painted page rect.
/// Do not rotate these a second time through PdfRect.toRect.
Rect analysisRect(
  podoco.PageRect bounds,
  podoco.PageSpace space,
  Rect pageRect,
) => Rect.fromLTRB(
  pageRect.left + bounds.left * pageRect.width / space.width,
  pageRect.top + bounds.top * pageRect.height / space.height,
  pageRect.left + bounds.right * pageRect.width / space.width,
  pageRect.top + bounds.bottom * pageRect.height / space.height,
);

class PdfAnalysisSource implements podoco.PageSource {
  PdfAnalysisSource._(
    this.session,
    this.snapshot,
    this.pages,
    this.preferNativeLease,
    this.transfers,
  );
  final PdfSession session;
  final podoco.DocumentRef snapshot;
  final bool preferNativeLease;
  final AnalysisImageTransfers? transfers;
  @override
  final List<podoco.PageDescriptor> pages;
  @override
  podoco.DocumentRef get document => analysisDocumentRef(session);
  bool get isCurrent => !session.lease.isClosed && document == snapshot;

  static Future<PdfAnalysisSource> create(
    PdfSession session, {
    bool preferNativeLease = true,
    AnalysisImageTransfers? transfers,
  }) => session.readLocked((pdf) async {
    final document = analysisDocumentRef(session);
    return PdfAnalysisSource._(
      session,
      document,
      List.unmodifiable([
        for (var i = 0; i < pdf.pages.length; i++)
          podoco.PageDescriptor(
            podoco.PageKey(document, i),
            podoco.PageSpace(pdf.pages[i].width, pdf.pages[i].height),
          ),
      ]),
      preferNativeLease,
      transfers,
    );
  });

  @override
  Future<podoco.PageInput> loadPage(podoco.PageRequest request) =>
      session.readLocked((pdf) async {
        void check() {
          if (!isCurrent || request.page.key.document != snapshot) {
            throw const podoco.PodocoException(
              'source_changed',
              'PDF revision changed',
            );
          }
          if (request.cancellation.isCancelled) {
            throw const podoco.PodocoException(
              'cancelled',
              'Page rendering cancelled',
            );
          }
        }

        check();
        final page = pdf.pages[request.page.key.pageIndex];
        final size = analysisRasterSize(
          page.width,
          page.height,
          request.byteBudget,
        );
        final token = page.createCancellationToken();
        var rendering = true;
        request.cancellation.cancelled.then((_) {
          if (rendering) token.cancel();
        });
        PdfImage? image;
        try {
          image = await page.render(
            width: size.width,
            height: size.height,
            fullWidth: size.width.toDouble(),
            fullHeight: size.height.toDouble(),
            backgroundColor: 0xffffffff,
            annotationRenderingMode: PdfAnnotationRenderingMode.none,
            cancellationToken: token,
          );
          check();
          if (image == null) throw StateError('PDF page rendering failed');
          final transform = podoco.Affine([
            page.width / image.width,
            0,
            0,
            page.height / image.height,
            0,
            0,
          ]);
          final input = analysisImageInput(
            image,
            byteBudget: request.byteBudget,
            preferNativeLease: preferNativeLease,
            transfers: transfers,
          );
          return podoco.PageInput(
            page: request.page,
            image: input,
            pixelToPage: transform,
            renderProfile: layoutRenderProfile,
          );
        } finally {
          rendering = false;
          image?.dispose();
        }
      });
}
