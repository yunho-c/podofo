import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  final descriptor = ImageDescriptor(
    width: 2,
    height: 2,
    rowStride: 8,
    format: PixelFormat.rgba8,
    alpha: AlphaMode.opaque,
  );
  test(
    'copied images release idempotently and reject invalid lengths',
    () async {
      final before = nativeLiveHandles;
      final pixels = Uint8List(16)..fillRange(0, 16, 255);
      final image = PageImage.copy(
        descriptor: descriptor,
        bytes: pixels,
        byteBudget: 16,
      );
      pixels.fillRange(0, 16, 0);
      expect(image.retainedBytes, 16);
      await image.dispose();
      await image.dispose();
      expect(image.isDisposed, isTrue);
      expect(
        () => PageImage.copy(
          descriptor: descriptor,
          bytes: Uint8List(15),
          byteBudget: 16,
        ),
        throwsA(isA<PodocoException>()),
      );
      expect(nativeLiveHandles, before);
    },
  );
  test(
    'native lease rejection retains caller ownership; accepted release is once',
    () async {
      final before = nativeLiveHandles;
      final pixels = calloc<Uint8>(16);
      var releases = 0;
      void release() {
        releases++;
        calloc.free(pixels);
      }

      expect(
        () => PageImage.importNative(
          descriptor: descriptor,
          pointer: pixels,
          initializedBytes: 16,
          retainedBytes: 16,
          byteBudget: 15,
          onRelease: release,
        ),
        throwsA(isA<PodocoException>()),
      );
      expect(releases, 0);
      final image = PageImage.importNative(
        descriptor: descriptor,
        pointer: pixels,
        initializedBytes: 16,
        retainedBytes: 16,
        byteBudget: 16,
        onRelease: release,
      );
      await image.dispose();
      await image.dispose();
      expect(releases, 1);
      expect(nativeLiveHandles, before);
    },
  );
}
