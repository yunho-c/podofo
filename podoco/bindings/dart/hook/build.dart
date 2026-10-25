import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final config = input.config.code;
    if (config.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError('Podoco currently bundles a shared library.');
    }
    if (config.targetOS != OS.current ||
        config.targetArchitecture != Architecture.current) {
      throw UnsupportedError(
        'Podoco currently supports native desktop host builds. '
        'Cross-compilation and mobile packaging are not configured yet.',
      );
    }
    final target = switch ((config.targetOS, config.targetArchitecture)) {
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      _ => throw UnsupportedError('Unsupported Podoco desktop target.'),
    };
    final libraryName = config.targetOS.dylibFileName('podoco_ffi');
    final supplied = input.userDefines['native-library'];
    if (supplied != null && supplied is! String) {
      throw FormatException('Podoco native-library must be a filesystem path.');
    }
    // Explicit file handling also supports absolute Windows drive paths.
    final prebuilt = supplied is String && File(supplied).isAbsolute
        ? File(supplied).uri
        : input.userDefines.path('native-library');
    Uri source;
    if (prebuilt != null) {
      source = prebuilt;
      output.dependencies.add(source);
    } else {
      final root = input.packageRoot.resolve('../../');
      if (!File.fromUri(root.resolve('crates/podoco-ffi/Cargo.toml'))
          .existsSync()) {
        throw StateError(
          'Podoco Rust sources are absent. Use the repository checkout or set '
          'hooks.user_defines.podoco.native-library in your pubspec.yaml.',
        );
      }
      final cargoOutput = input.outputDirectory.resolve('cargo/');
      final environment = Map<String, String>.of(Platform.environment);
      if (config.targetOS == OS.macOS) {
        environment.remove('IPHONEOS_DEPLOYMENT_TARGET');
        environment['MACOSX_DEPLOYMENT_TARGET'] =
            '${config.macOS.targetVersion}.0';
      }
      final result = await Process.run(
        'cargo',
        [
          'build',
          '--manifest-path',
          root.resolve('Cargo.toml').toFilePath(),
          '--locked',
          '--release',
          '--package',
          'podoco-ffi',
          '--target',
          target,
          '--target-dir',
          cargoOutput.toFilePath(),
        ],
        workingDirectory: root.toFilePath(),
        environment: environment,
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) {
        throw StateError('Cargo failed:\n${result.stdout}\n${result.stderr}');
      }
      source = cargoOutput.resolve('$target/release/$libraryName');
      for (final name in [
        'Cargo.toml',
        'Cargo.lock',
        'rust-toolchain.toml',
        'tools/codegen/Cargo.toml',
      ]) {
        output.dependencies.add(root.resolve(name));
      }
      final crates = Directory.fromUri(root.resolve('crates/'));
      output.dependencies.add(crates.uri);
      await for (final entry in crates.list(
        recursive: true,
        followLinks: false,
      )) {
        output.dependencies.add(entry.uri);
      }
    }
    if (!File.fromUri(source).existsSync()) {
      throw StateError('Podoco native library does not exist: $source');
    }
    final destination = input.outputDirectory.resolve(libraryName);
    await File.fromUri(source).copy(destination.toFilePath());
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/bindings.g.dart',
        file: destination,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}
