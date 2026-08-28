import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_js/quickjs/quickjs_runtime2.dart';

class AddonTypescriptCompiler {
  AddonTypescriptCompiler({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  static const _compilerAsset = 'assets/typescript/sucrase.js';
  static const _maximumSourceCharacters = 768 * 1024;

  final AssetBundle _bundle;
  Future<String>? _compilerSource;

  Future<String> compile(String source) async {
    if (source.isEmpty ||
        utf8.encode(source).length > _maximumSourceCharacters) {
      throw const FormatException('The TypeScript addon payload is invalid.');
    }
    final compiler = await (_compilerSource ??= _bundle.loadString(
      _compilerAsset,
      cache: true,
    ));
    // Dart worker isolates have a much smaller native stack than Flutter's
    // main isolate on Android. Sucrase legitimately needs more than that
    // worker stack for some real Seanime providers, so running it there can
    // hit the OS guard page before QuickJS can report a JavaScript error.
    // Compilation is an install/update-only operation; keep it on the main
    // isolate where the native bridge can safely grant the larger bounded
    // QuickJS stack below. QuickJS's two five-second execution deadlines
    // still bound initialization and transformation independently.
    return _compileInQuickJs(compiler: compiler, source: source);
  }
}

String _compileInQuickJs({required String compiler, required String source}) {
  final runtime = QuickJsRuntime2(
    timeout: 5000,
    memoryLimit: 48 * 1024 * 1024,
    stackSize: 4 * 1024 * 1024,
  );
  try {
    final compilerResult = runtime.evaluate(
      compiler,
      sourceUrl: 'asset://typescript.js',
    );
    if (compilerResult.isError) {
      throw FormatException(
        'Could not initialize the TypeScript transformer: '
        '${compilerResult.stringResult}',
      );
    }
    final result = runtime.evaluate('''
      JSON.stringify({code: __tetoCompileTypescript(${jsonEncode(source)})})
    ''', sourceUrl: 'tetotv://typescript-compiler.js');
    if (result.isError) {
      throw FormatException(
        'TypeScript compilation failed: ${result.stringResult}',
      );
    }
    final decoded = jsonDecode(result.stringResult);
    if (decoded is! Map) {
      throw const FormatException(
        'The TypeScript compiler returned no output.',
      );
    }
    final code = decoded['code'];
    if (code is! String || code.trim().isEmpty) {
      throw const FormatException('The TypeScript compiler returned no code.');
    }
    if (utf8.encode(code).length >
        AddonTypescriptCompiler._maximumSourceCharacters) {
      throw const FormatException(
        'The compiled TypeScript addon payload is too large.',
      );
    }
    return code;
  } finally {
    runtime.dispose();
  }
}
