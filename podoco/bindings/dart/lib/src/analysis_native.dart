part of 'analysis.dart';

void _checkNative() {
  final actual = native.podoco_abi_version();
  if (actual != 2) {
    throw UnsupportedError('Podoco ABI $actual is incompatible with ABI 2.');
  }
}

/// Compiled backend flags; actual model operations come from Analyzer.capabilities.
bool get coreMlAvailable {
  _checkNative();
  return native.podoco_features() & native.PODOCO_FEATURE_COREML != 0;
}

/// Registry entries for leak diagnostics, not a process-memory measurement.
int get nativeLiveHandles {
  _checkNative();
  return native.podoco_live_handles();
}

native.PodocoBytes _bytes(Arena arena, List<int> bytes) {
  final value = arena<native.PodocoBytes>();
  final data = bytes.isEmpty
      ? nullptr.cast<Uint8>()
      : arena<Uint8>(bytes.length);
  if (bytes.isNotEmpty) data.asTypedList(bytes.length).setAll(0, bytes);
  value.ref
    ..data = data
    ..len = bytes.length;
  return value.ref;
}

native.PodocoBytes _jsonBytes(Arena arena, Object? value) =>
    _bytes(arena, utf8.encode(jsonEncode(value)));
JsonObject _takeJson(
  int handle, {
  int maxBytes = native.PODOCO_MAX_METADATA_BYTES,
}) {
  try {
    return using((arena) {
      final view = arena<native.PodocoBytes>();
      if (native.podoco_buffer_view(handle, view, nullptr) !=
          native.PODOCO_OK) {
        throw const PodocoException(
          'invalid_result',
          'Native buffer handle is invalid',
        );
      }
      if (view.ref.len > maxBytes) {
        throw const PodocoException(
          'limit_exceeded',
          'Native metadata exceeds negotiated limit',
        );
      }
      return _map(
        jsonDecode(utf8.decode(view.ref.data.asTypedList(view.ref.len))),
      );
    });
  } finally {
    native.podoco_release(handle);
  }
}

int _check(int status, Pointer<Uint64> error) {
  if (status >= 0) return status;
  if (error.value == 0) {
    throw const PodocoException(
      'native_failure',
      'Native call failed without a diagnostic',
    );
  }
  throw PodocoException.fromJson(_takeJson(error.value));
}

int _newHandle(int Function(Pointer<Uint64>, Pointer<Uint64>) call) =>
    using((arena) {
      final output = arena<Uint64>(), error = arena<Uint64>();
      final status = _check(call(output, error), error);
      if (status != native.PODOCO_OK || output.value == 0) {
        throw const PodocoException(
          'invalid_result',
          'Native call returned no handle',
        );
      }
      return output.value;
    });
void _control(int Function(Pointer<Uint64>) call) => using((arena) {
  final error = arena<Uint64>();
  _check(call(error), error);
});
JsonObject? _poll(
  int Function(Pointer<Uint64>, Pointer<Uint64>) call, {
  int maxBytes = native.PODOCO_MAX_METADATA_BYTES,
}) => using((arena) {
  final output = arena<Uint64>(), error = arena<Uint64>();
  final status = _check(call(output, error), error);
  if (status == native.PODOCO_PENDING) return null;
  if (status != native.PODOCO_OK || output.value == 0) {
    throw const PodocoException('invalid_result', 'Invalid native poll status');
  }
  return _takeJson(output.value, maxBytes: maxBytes);
});

int _openNative(JsonObject config) {
  _checkNative();
  return using(
    (arena) => _newHandle(
      (out, error) =>
          native.podoco_analyzer_open(_jsonBytes(arena, config), out, error),
    ),
  );
}

JsonObject _verifyNative(String directory) {
  _checkNative();
  return using(
    (arena) => _takeJson(
      _newHandle(
        (out, error) => native.podoco_bundle_verify(
          _bytes(arena, utf8.encode(directory)),
          out,
          error,
        ),
      ),
    ),
  );
}

void _requireFormulaExtension() {
  _checkNative();
  if (native.podoco_features() & native.PODOCO_FEATURE_FORMULA == 0) {
    throw const PodocoException(
      'unsupported_capability',
      'This native library predates the formula extension.',
    );
  }
}

JsonObject _verifyFormulaNative(String directory) {
  _requireFormulaExtension();
  return using(
    (arena) => _takeJson(
      _newHandle(
        (out, error) => native.podoco_formula_bundle_verify(
          _bytes(arena, utf8.encode(directory)),
          out,
          error,
        ),
      ),
    ),
  );
}

Future<void> _releaseAsync(int handle) =>
    Isolate.run(() => native.podoco_release(handle)).then((_) {});
final _handleFinalizer = Finalizer<int>((handle) {
  unawaited(_releaseAsync(handle));
});

/// Verified offline identity. Analyzer opening rechecks payloads before loading;
/// keep files/symlink targets immutable throughout use.
class ModelBundle {
  final String directory, id, profile, manifestSha256;
  final Capabilities declaredCapabilities;
  ModelBundle._(this.directory, JsonObject j)
    : id = _text(j['id']),
      profile = _text(j['profile']),
      manifestSha256 = _text(j['manifest_sha256']),
      declaredCapabilities = Capabilities._(_map(j['capabilities']));
  static Future<ModelBundle> verify(String directory) async {
    final result = await Isolate.run(() => _verifyNative(directory));
    _schema(result);
    return ModelBundle._(directory, result);
  }
}

/// Verified formula assets. Opening rechecks all hashes before loading models.
class FormulaBundle {
  final String directory, id, profile, manifestSha256;
  FormulaBundle._(this.directory, JsonObject j)
    : id = _text(j['id']),
      profile = _text(j['profile']),
      manifestSha256 = _sha(j['manifest_sha256']);
  static Future<FormulaBundle> verify(String directory) async {
    final result = await Isolate.run(() => _verifyFormulaNative(directory));
    _schema(result);
    return FormulaBundle._(directory, result);
  }
}

/// Greedy generation cap, excluding the start token. Capped output is truncated.
class FormulaOptions {
  final int maxNewTokens;
  FormulaOptions({this.maxNewTokens = 2048}) {
    if (maxNewTokens < 1 || maxNewTokens > 2048) {
      throw RangeError.range(maxNewTokens, 1, 2048, 'maxNewTokens');
    }
  }
}

Pointer<native.PodocoImageDescriptor> _descriptor(
  Arena arena,
  ImageDescriptor d,
) {
  final p = arena<native.PodocoImageDescriptor>();
  p.ref
    ..struct_size = sizeOf<native.PodocoImageDescriptor>()
    ..width = d.width
    ..height = d.height
    ..pixel_format = d.format.index
    ..alpha_mode = d.alpha.index
    ..reserved = 0
    ..row_bytes = d.rowStride;
  return p;
}

/// Owned immutable input. A source transfers its PageInput/image to the job;
/// the pump disposes it after replying. Explicit disposal is idempotent.
class PageImage {
  int _handle;
  final ImageDescriptor descriptor;
  final int retainedBytes;
  final Future<void> _released;
  PageImage._(
    this._handle,
    this.descriptor,
    this.retainedBytes,
    this._released,
  ) {
    _handleFinalizer.attach(this, _handle, detach: this);
  }

  /// Safe copied input. A temporary native staging copy bridges Dart's managed
  /// bytes; Rust copies it into immutable storage before return.
  factory PageImage.copy({
    required ImageDescriptor descriptor,
    required Uint8List bytes,
    required int byteBudget,
  }) {
    _checkNative();
    if (byteBudget <= 0) {
      throw ArgumentError('byteBudget must be positive');
    }
    final handle = using(
      (arena) => _newHandle(
        (out, error) => native.podoco_image_copy(
          _descriptor(arena, descriptor),
          _bytes(arena, bytes),
          byteBudget,
          out,
          error,
        ),
      ),
    );
    return PageImage._(handle, descriptor, bytes.length, Future.value());
  }

  /// Advanced renderer adapter: no pixel copy at this handoff. The allocation
  /// must remain immutable and live until onRelease runs. No escaped writable
  /// views may exist. Rejection keeps ownership and does not call onRelease.
  /// onRelease must synchronously free or relinquish the allocation.
  /// The callback must free/relinquish the allocation exactly once.
  factory PageImage.importNative({
    required ImageDescriptor descriptor,
    required Pointer<Uint8> pointer,
    required int initializedBytes,
    required int retainedBytes,
    required int byteBudget,
    required void Function() onRelease,
  }) {
    _checkNative();
    if (byteBudget <= 0 ||
        initializedBytes < 0 ||
        retainedBytes < initializedBytes) {
      throw ArgumentError('Invalid native storage limits');
    }
    final released = Completer<void>();
    released.future.ignore(); // A finalizer may be the only cleanup observer.
    late final NativeCallable<Void Function(Uint64)> listener;
    listener = NativeCallable<Void Function(Uint64)>.listener((int token) {
      try {
        onRelease();
        released.complete();
      } catch (e, s) {
        released.completeError(e, s);
      } finally {
        listener.close();
      }
    });
    try {
      final handle = using((arena) {
        final view = arena<native.PodocoBytes>()
          ..ref.data = pointer
          ..ref.len = initializedBytes;
        return _newHandle(
          (out, error) => native.podoco_image_import(
            _descriptor(arena, descriptor),
            view.ref,
            retainedBytes,
            byteBudget,
            listener.nativeFunction,
            0,
            out,
            error,
          ),
        );
      });
      return PageImage._(handle, descriptor, retainedBytes, released.future);
    } catch (_) {
      listener.close();
      rethrow;
    }
  }
  bool get isDisposed => _handle == 0;
  Future<void> dispose() {
    if (_handle != 0) {
      final id = _handle;
      _handle = 0;
      _handleFinalizer.detach(this);
      if (native.podoco_release(id) != native.PODOCO_OK) {
        throw const PodocoException(
          'invalid_input',
          'Image was already released',
        );
      }
    }
    return _released;
  }
}

class PageInput {
  final PageDescriptor page;
  final PageImage image;
  final Affine pixelToPage;
  final String renderProfile;
  PageInput({
    required this.page,
    required this.image,
    required this.pixelToPage,
    required this.renderProfile,
  }) {
    _text(renderProfile);
  }
  JsonObject _metadata() => {
    'schema_version': 0,
    'page': page.toJson(),
    'pixel_to_page': pixelToPage.toJson(),
    'render_profile': renderProfile,
  };
}

Future<void> _closeAnalyzerAsync(int handle) => Isolate.run(
  () => _control((error) => native.podoco_analyzer_close(handle, error)),
);
