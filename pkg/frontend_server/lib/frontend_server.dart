// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

library frontend_server;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide FileSystemEntity;

import 'package:args/args.dart';
import 'package:dev_compiler/dev_compiler.dart' show DevCompilerTarget;

// front_end/src imports below that require lint `ignore_for_file`
// are a temporary state of things until frontend team builds better api
// that would replace api used below. This api was made private in
// an effort to discourage further use.
// ignore_for_file: implementation_imports
import 'package:front_end/src/api_prototype/compiler_options.dart'
    show CompilerOptions, parseExperimentalFlags;
import 'package:front_end/src/api_unstable/vm.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/binary/limited_ast_to_binary.dart';
import 'package:kernel/kernel.dart'
    show Component, loadComponentSourceFromBytes;
import 'package:kernel/target/targets.dart' show targets, TargetFlags;
import 'package:path/path.dart' as path;
import 'package:usage/uuid/uuid.dart';

import 'package:vm/metadata/binary_cache.dart'
    show BinaryCacheMetadataRepository;

import 'package:vm/bytecode/gen_bytecode.dart'
    show generateBytecode, createFreshComponentWithBytecode;
import 'package:vm/bytecode/options.dart' show BytecodeOptions;
import 'package:vm/incremental_compiler.dart' show IncrementalCompiler;
import 'package:vm/kernel_front_end.dart';

import 'src/javascript_bundle.dart';
import 'src/strong_components.dart';

ArgParser argParser = ArgParser(allowTrailingOptions: true)
  ..addFlag('train',
      help: 'Run through sample command line to produce snapshot',
      negatable: false)
  ..addFlag('incremental',
      help: 'Run compiler in incremental mode', defaultsTo: false)
  ..addOption('sdk-root',
      help: 'Path to sdk root',
      defaultsTo: '../../out/android_debug/flutter_patched_sdk')
  ..addOption('platform', help: 'Platform kernel filename')
  ..addFlag('aot',
      help: 'Run compiler in AOT mode (enables whole-program transformations)',
      defaultsTo: false)
// TODO(alexmarkov): Cleanup uses in Flutter and remove these obsolete flags.
  ..addFlag('strong', help: 'Obsolete', defaultsTo: true)
  ..addFlag('tfa',
      help:
          'Enable global type flow analysis and related transformations in AOT mode.',
      defaultsTo: false)
  ..addFlag('protobuf-tree-shaker',
      help: 'Enable protobuf tree shaker transformation in AOT mode.',
      defaultsTo: false)
  ..addFlag('link-platform',
      help:
          'When in batch mode, link platform kernel file into result kernel file.'
          ' Intended use is to satisfy different loading strategies implemented'
          ' by gen_snapshot(which needs platform embedded) vs'
          ' Flutter engine(which does not)',
      defaultsTo: true)
  ..addOption('import-dill',
      help: 'Import libraries from existing dill file', defaultsTo: null)
  ..addOption('output-dill',
      help: 'Output path for the generated dill', defaultsTo: null)
  ..addOption('output-incremental-dill',
      help: 'Output path for the generated incremental dill', defaultsTo: null)
  ..addOption('depfile',
      help: 'Path to output Ninja depfile. Only used in batch mode.')
  ..addOption('packages',
      help: '.packages file to use for compilation', defaultsTo: null)
  ..addOption('target',
      help: 'Target model that determines what core libraries are available',
      allowed: <String>[
        'vm',
        'flutter',
        'flutter_runner',
        'dart_runner',
        'dartdevc'
      ],
      defaultsTo: 'vm')
  ..addMultiOption('filesystem-root',
      help: 'File path that is used as a root in virtual filesystem used in'
          ' compiled kernel files. When used --output-dill should be provided'
          ' as well.',
      hide: true)
  ..addOption('filesystem-scheme',
      help:
          'Scheme that is used in virtual filesystem set up via --filesystem-root'
          ' option',
      defaultsTo: 'org-dartlang-root',
      hide: true)
  ..addFlag('verbose', help: 'Enables verbose output from the compiler.')
  ..addOption('initialize-from-dill',
      help: 'Normally the output dill is used to specify which dill to '
          'initialize from, but it can be overwritten here.',
      defaultsTo: null,
      hide: true)
  ..addMultiOption('define',
      abbr: 'D',
      help: 'The values for the environment constants (e.g. -Dkey=value).')
  ..addFlag('embed-source-text',
      help: 'Includes sources into generated dill file. Having sources'
          ' allows to effectively use observatory to debug produced'
          ' application, produces better stack traces on exceptions.',
      defaultsTo: true)
  ..addFlag('unsafe-package-serialization',
      help: '*Deprecated* '
          'Potentially unsafe: Does not allow for invalidating packages, '
          'additionally the output dill file might include more libraries than '
          'needed. The use case is test-runs, where invalidation is not really '
          'used, and where dill filesize does not matter, and the gain is '
          'improved speed.',
      defaultsTo: false,
      hide: true)
  ..addFlag('incremental-serialization',
      help: 'Re-use previously serialized data when serializing. '
          'The output dill file might include more libraries than strictly '
          'needed, but the serialization phase will generally be much faster.',
      defaultsTo: true,
      negatable: true,
      hide: true)
  ..addFlag('track-widget-creation',
      help: 'Run a kernel transformer to track creation locations for widgets.',
      defaultsTo: false)
  ..addFlag('gen-bytecode', help: 'Generate bytecode', defaultsTo: null)
  ..addMultiOption('bytecode-options',
      help: 'Specify options for bytecode generation:',
      valueHelp: 'opt1,opt2,...',
      allowed: BytecodeOptions.commandLineFlags.keys,
      allowedHelp: BytecodeOptions.commandLineFlags)
  ..addFlag('drop-ast',
      help: 'Include only bytecode into the output file', defaultsTo: true)
  ..addFlag('enable-asserts',
      help: 'Whether asserts will be enabled.', defaultsTo: false)
  ..addMultiOption('enable-experiment',
      help: 'Comma separated list of experimental features, eg set-literals.',
      hide: true)
  ..addFlag('split-output-by-packages',
      help:
          'Split resulting kernel file into multiple files (one per package).',
      defaultsTo: false)
  ..addOption('component-name', help: 'Name of the Fuchsia component')
  ..addOption('data-dir',
      help: 'Name of the subdirectory of //data for output files')
  ..addOption('far-manifest', help: 'Path to output Fuchsia package manifest');

String usage = '''
Usage: server [options] [input.dart]

If filename or uri pointing to the entrypoint is provided on the command line,
then the server compiles it, generates dill file and exits.
If no entrypoint is provided on the command line, server waits for
instructions from stdin.

Instructions:
- compile <input.dart>
- recompile [<input.dart>] <boundary-key>
<invalidated file uri>
<invalidated file uri>
...
<boundary-key>
- accept
- quit

Output:
- result <boundary-key>
<compiler output>
<boundary-key> [<output.dill>]

Options:
${argParser.usage}
''';

enum _State {
  READY_FOR_INSTRUCTION,
  RECOMPILE_LIST,
  COMPILE_EXPRESSION_EXPRESSION,
  COMPILE_EXPRESSION_DEFS,
  COMPILE_EXPRESSION_TYPEDEFS,
  COMPILE_EXPRESSION_LIBRARY_URI,
  COMPILE_EXPRESSION_KLASS,
  COMPILE_EXPRESSION_IS_STATIC
}

/// Actions that every compiler should implement.
abstract class CompilerInterface {
  /// Compile given Dart program identified by `entryPoint` with given list of
  /// `options`. When `generator` parameter is omitted, new instance of
  /// `IncrementalKernelGenerator` is created by this method. Main use for this
  /// parameter is for mocking in tests.
  /// Returns [true] if compilation was successful and produced no errors.
  Future<bool> compile(
    String entryPoint,
    ArgResults options, {
    IncrementalCompiler generator,
  });

  /// Assuming some Dart program was previously compiled, recompile it again
  /// taking into account some changed(invalidated) sources.
  Future<Null> recompileDelta({String entryPoint});

  /// Accept results of previous compilation so that next recompilation cycle
  /// won't recompile sources that were previously reported as changed.
  void acceptLastDelta();

  /// Rejects results of previous compilation and sets compiler back to last
  /// accepted state.
  Future<void> rejectLastDelta();

  /// This let's compiler know that source file identifed by `uri` was changed.
  void invalidate(Uri uri);

  /// Resets incremental compiler accept/reject status so that next time
  /// recompile is requested, complete kernel file is produced.
  void resetIncrementalCompiler();

  /// Compiles [expression] with free variables listed in [definitions],
  /// free type variables listed in [typedDefinitions]. "Free" means their
  /// values are through evaluation API call, rather than coming from running
  /// application.
  /// If [klass] is not [null], expression is compiled in context of [klass]
  /// class.
  /// If [klass] is [null],expression is compiled at top-level of
  /// [libraryUrl] library. If [klass] is not [null], [isStatic] determines
  /// whether expression can refer to [this] or not.
  Future<Null> compileExpression(
      String expression,
      List<String> definitions,
      List<String> typeDefinitions,
      String libraryUri,
      String klass,
      bool isStatic);

  /// Communicates an error [msg] to the client.
  void reportError(String msg);
}

abstract class ProgramTransformer {
  void transform(Component component);
}

/// Class that for test mocking purposes encapsulates creation of [BinaryPrinter].
class BinaryPrinterFactory {
  /// Creates new [BinaryPrinter] to write to [targetSink].
  BinaryPrinter newBinaryPrinter(Sink<List<int>> targetSink) {
    return LimitedBinaryPrinter(targetSink, (_) => true /* predicate */,
        false /* excludeUriToSource */);
  }
}

class FrontendCompiler implements CompilerInterface {
  FrontendCompiler(this._outputStream,
      {this.printerFactory,
      this.transformer,
      this.unsafePackageSerialization,
      this.incrementalSerialization: true}) {
    _outputStream ??= stdout;
    printerFactory ??= new BinaryPrinterFactory();
  }

  StringSink _outputStream;
  BinaryPrinterFactory printerFactory;
  bool unsafePackageSerialization;
  bool incrementalSerialization;

  CompilerOptions _compilerOptions;
  BytecodeOptions _bytecodeOptions;
  FileSystem _fileSystem;
  Uri _mainSource;
  ArgResults _options;

  IncrementalCompiler _generator;
  String _kernelBinaryFilename;
  String _kernelBinaryFilenameIncremental;
  String _kernelBinaryFilenameFull;
  String _initializeFromDill;

  Set<Uri> previouslyReportedDependencies = Set<Uri>();

  final ProgramTransformer transformer;

  final List<String> errors = List<String>();

  @override
  Future<bool> compile(
    String entryPoint,
    ArgResults options, {
    IncrementalCompiler generator,
  }) async {
    _options = options;
    _fileSystem = createFrontEndFileSystem(
        options['filesystem-scheme'], options['filesystem-root']);
    _mainSource = _getFileOrUri(entryPoint);
    _kernelBinaryFilenameFull = _options['output-dill'] ?? '$entryPoint.dill';
    _kernelBinaryFilenameIncremental = _options['output-incremental-dill'] ??
        (_options['output-dill'] != null
            ? '${_options['output-dill']}.incremental.dill'
            : '$entryPoint.incremental.dill');
    _kernelBinaryFilename = _kernelBinaryFilenameFull;
    _initializeFromDill =
        _options['initialize-from-dill'] ?? _kernelBinaryFilenameFull;
    final String boundaryKey = Uuid().generateV4();
    _outputStream.writeln('result $boundaryKey');
    final Uri sdkRoot = _ensureFolderPath(options['sdk-root']);
    final String platformKernelDill =
        options['platform'] ?? 'platform_strong.dill';
    final CompilerOptions compilerOptions = CompilerOptions()
      ..sdkRoot = sdkRoot
      ..fileSystem = _fileSystem
      ..packagesFileUri = _getFileOrUri(_options['packages'])
      ..sdkSummary = sdkRoot.resolve(platformKernelDill)
      ..verbose = options['verbose']
      ..embedSourceText = options['embed-source-text']
      ..experimentalFlags = parseExperimentalFlags(
          parseExperimentalArguments(options['enable-experiment']),
          onError: (msg) => errors.add(msg))
      ..onDiagnostic = (DiagnosticMessage message) {
        bool printMessage;
        switch (message.severity) {
          case Severity.error:
          case Severity.internalProblem:
            printMessage = true;
            errors.addAll(message.plainTextFormatted);
            break;
          case Severity.warning:
            printMessage = true;
            break;
          case Severity.context:
          case Severity.ignored:
            throw 'Unexpected severity: ${message.severity}';
        }
        if (printMessage) {
          printDiagnosticMessage(message, _outputStream.writeln);
        }
      };

    if (options.wasParsed('filesystem-root')) {
      if (_options['output-dill'] == null) {
        print('When --filesystem-root is specified it is required to specify'
            ' --output-dill option that points to physical file system location'
            ' of a target dill file.');
        return false;
      }
    }

    final Map<String, String> environmentDefines = {};
    if (!parseCommandLineDefines(
        options['define'], environmentDefines, usage)) {
      return false;
    }

    compilerOptions.bytecode = options['gen-bytecode'] ?? options['aot'];
    final BytecodeOptions bytecodeOptions = BytecodeOptions(
      enableAsserts: options['enable-asserts'],
      emitSourceFiles: options['embed-source-text'],
      environmentDefines: environmentDefines,
      aot: options['aot'],
    )..parseCommandLineFlags(options['bytecode-options']);

    // Initialize additional supported kernel targets.
    targets['dartdevc'] = (TargetFlags flags) => DevCompilerTarget(flags);
    compilerOptions.target = createFrontEndTarget(
      options['target'],
      trackWidgetCreation: options['track-widget-creation'],
    );
    if (compilerOptions.target == null) {
      print('Failed to create front-end target ${options['target']}.');
      return false;
    }

    final String importDill = options['import-dill'];
    if (importDill != null) {
      compilerOptions.inputSummaries = <Uri>[
        Uri.base.resolveUri(Uri.file(importDill))
      ];
    }

    if (compilerOptions.bytecode && _initializeFromDill != null) {
      // If we are generating bytecode, put bytecode only (not AST) in
      // [_kernelBinaryFilename], which the user of this tool will eventually
      // feed to Flutter engine or flutter_tester. Use a separate file to cache
      // the AST result to initialize the incremental compiler for the next
      // invocation of this tool.
      _initializeFromDill += ".ast";
    }

    _compilerOptions = compilerOptions;
    _bytecodeOptions = bytecodeOptions;

    KernelCompilationResults results;
    IncrementalSerializer incrementalSerializer;
    if (options['incremental']) {
      setVMEnvironmentDefines(environmentDefines, _compilerOptions);

      _compilerOptions.omitPlatform = false;
      _generator = generator ?? _createGenerator(Uri.file(_initializeFromDill));
      await invalidateIfInitializingFromDill();
      Component component =
          await _runWithPrintRedirection(() => _generator.compile());
      results = KernelCompilationResults(
          component,
          _generator.getClassHierarchy(),
          _generator.getCoreTypes(),
          component.uriToSource.keys);

      incrementalSerializer = _generator.incrementalSerializer;
    } else {
      if (options['link-platform']) {
        // TODO(aam): Remove linkedDependencies once platform is directly embedded
        // into VM snapshot and http://dartbug.com/30111 is fixed.
        compilerOptions.linkedDependencies = <Uri>[
          sdkRoot.resolve(platformKernelDill)
        ];
      }
      // No bytecode at this step. Bytecode is generated later in _writePackage.
      results = await _runWithPrintRedirection(() => compileToKernel(
          _mainSource, compilerOptions,
          aot: options['aot'],
          useGlobalTypeFlowAnalysis: options['tfa'],
          environmentDefines: environmentDefines,
          enableAsserts: options['enable-asserts'],
          useProtobufTreeShaker: options['protobuf-tree-shaker']));
    }
    if (results.component != null) {
      transformer?.transform(results.component);

      if (_compilerOptions.target.name == 'dartdevc') {
        await writeJavascriptBundle(results, _kernelBinaryFilename);
      } else {
        await writeDillFile(results, _kernelBinaryFilename,
            filterExternal: importDill != null,
            incrementalSerializer: incrementalSerializer);
      }

      _outputStream.writeln(boundaryKey);
      await _outputDependenciesDelta(results.compiledSources);
      _outputStream
          .writeln('$boundaryKey $_kernelBinaryFilename ${errors.length}');
      final String depfile = options['depfile'];
      if (depfile != null) {
        await writeDepfile(compilerOptions.fileSystem, results.compiledSources,
            _kernelBinaryFilename, depfile);
      }

      _kernelBinaryFilename = _kernelBinaryFilenameIncremental;
    } else
      _outputStream.writeln(boundaryKey);
    return errors.isEmpty;
  }

  Future<Component> _generateBytecodeIfNeeded(Component component) async {
    if (_compilerOptions.bytecode && errors.isEmpty) {
      await runWithFrontEndCompilerContext(
          _mainSource, _compilerOptions, component, () {
        generateBytecode(component,
            coreTypes: _generator.getCoreTypes(),
            hierarchy: _generator.getClassHierarchy(),
            options: _bytecodeOptions);
        if (_options['drop-ast']) {
          component = createFreshComponentWithBytecode(component);
        }
      });
    }
    return component;
  }

  void _outputDependenciesDelta(Iterable<Uri> compiledSources) async {
    Set<Uri> uris = Set<Uri>();
    for (Uri uri in compiledSources) {
      // Skip empty or corelib dependencies.
      if (uri == null || uri.scheme == 'org-dartlang-sdk') continue;
      uris.add(uri);
    }
    for (Uri uri in uris) {
      if (previouslyReportedDependencies.contains(uri)) {
        continue;
      }
      try {
        _outputStream.writeln('+${await asFileUri(_fileSystem, uri)}');
      } on FileSystemException {
        // Ignore errors from invalid import uris.
      }
    }
    for (Uri uri in previouslyReportedDependencies) {
      if (uris.contains(uri)) {
        continue;
      }
      try {
        _outputStream.writeln('-${await asFileUri(_fileSystem, uri)}');
      } on FileSystemException {
        // Ignore errors from invalid import uris.
      }
    }
    previouslyReportedDependencies = uris;
  }

  /// Write a JavaScript bundle containg the provided component.
  Future<void> writeJavascriptBundle(
      KernelCompilationResults results, String filename) async {
    final Component component = results.component;
    // Compute strongly connected components.
    final strongComponents = StrongComponents(component, _mainSource,
        _compilerOptions.packagesFileUri, _compilerOptions.fileSystem);
    await strongComponents.computeModules();

    // Create JavaScript bundler.
    final File sourceFile = File('$filename.sources');
    final File manifestFile = File('$filename.json');
    final File sourceMapsFile = File('$filename.map');
    if (!sourceFile.parent.existsSync()) {
      sourceFile.parent.createSync(recursive: true);
    }
    final bundler = JavaScriptBundler(component, strongComponents);
    final sourceFileSink = sourceFile.openWrite();
    final manifestFileSink = manifestFile.openWrite();
    final sourceMapsFileSink = sourceMapsFile.openWrite();
    bundler.compile(results.classHierarchy, results.coreTypes, sourceFileSink,
        manifestFileSink, sourceMapsFileSink);
    await Future.wait([
      sourceFileSink.close(),
      manifestFileSink.close(),
      sourceMapsFileSink.close()
    ]);
  }

  writeDillFile(KernelCompilationResults results, String filename,
      {bool filterExternal: false,
      IncrementalSerializer incrementalSerializer}) async {
    final Component component = results.component;
    // Remove the cache that came either from this function or from
    // initializing from a kernel file.
    component.metadata.remove(BinaryCacheMetadataRepository.repositoryTag);

    if (_compilerOptions.bytecode) {
      {
        // Generate bytecode as the output proper.
        final IOSink sink = File(filename).openWrite();
        await runWithFrontEndCompilerContext(
            _mainSource, _compilerOptions, component, () async {
          if (_options['incremental']) {
            // When loading a single kernel buffer with multiple sub-components,
            // the VM expects 'main' to be the first sub-component.
            await forEachPackage(component,
                (String package, List<Library> libraries) async {
              _writePackage(results, package, libraries, sink);
            }, mainFirst: true);
          } else {
            _writePackage(results, 'main', component.libraries, sink);
          }
        });
        await sink.close();
      }

      {
        // Generate AST as a cache. This goes to [_initializeFromDill] instead
        // of [filename] so that a later invocation of frontend_server will the
        // same arguments will use this to initialize its incremental kernel
        // compiler.
        final repository = BinaryCacheMetadataRepository();
        component.addMetadataRepository(repository);
        for (var lib in component.libraries) {
          var bytes = BinaryCacheMetadataRepository.lookup(lib);
          if (bytes != null) {
            repository.mapping[lib] = bytes;
          }
        }

        final file = new File(_initializeFromDill);
        await file.create(recursive: true);
        final IOSink sink = file.openWrite();
        final BinaryPrinter printer = filterExternal
            ? LimitedBinaryPrinter(
                sink,
                // ignore: DEPRECATED_MEMBER_USE
                (lib) => !lib.isExternal,
                true /* excludeUriToSource */)
            : printerFactory.newBinaryPrinter(sink);

        sortComponent(component);

        printer.writeComponentFile(component);
        await sink.close();
      }
    } else {
      // Generate AST as the output proper.
      final IOSink sink = File(filename).openWrite();
      final BinaryPrinter printer = filterExternal
          ? LimitedBinaryPrinter(
              sink,
              // ignore: DEPRECATED_MEMBER_USE
              (lib) => !lib.isExternal,
              true /* excludeUriToSource */)
          : printerFactory.newBinaryPrinter(sink);

      sortComponent(component);

      if (incrementalSerializer != null) {
        incrementalSerializer.writePackagesToSinkAndTrimComponent(
            component, sink);
      } else if (unsafePackageSerialization == true) {
        writePackagesToSinkAndTrimComponent(component, sink);
      }

      printer.writeComponentFile(component);
      await sink.close();
    }

    if (_options['split-output-by-packages']) {
      await writeOutputSplitByPackages(
          _mainSource,
          _compilerOptions,
          results.component,
          results.coreTypes,
          results.classHierarchy,
          filename,
          genBytecode: _compilerOptions.bytecode,
          bytecodeOptions: _bytecodeOptions,
          dropAST: _options['drop-ast']);
    }

    final String manifestFilename = _options['far-manifest'];
    if (manifestFilename != null) {
      final String output = _options['output-dill'];
      final String dataDir = _options.options.contains('component-name')
          ? _options['component-name']
          : _options['data-dir'];
      await createFarManifest(output, dataDir, manifestFilename);
    }
  }

  Future<Null> invalidateIfInitializingFromDill() async {
    if (_kernelBinaryFilename != _kernelBinaryFilenameFull) return null;
    // If the generator is initialized, it's not going to initialize from dill
    // again anyway, so there's no reason to spend time invalidating what should
    // be invalidated by the normal approach anyway.
    if (_generator.initialized) return null;

    final File f = File(_initializeFromDill);
    if (!f.existsSync()) return null;

    Component component;
    try {
      component = loadComponentSourceFromBytes(f.readAsBytesSync());
    } catch (e) {
      // If we cannot load the dill file we shouldn't initialize from it.
      _generator = _createGenerator(null);
      return null;
    }

    nextUri:
    for (Uri uri in component.uriToSource.keys) {
      if (uri == null || '$uri' == '') continue nextUri;

      final List<int> oldBytes = component.uriToSource[uri].source;
      FileSystemEntity entity;
      try {
        entity = _compilerOptions.fileSystem.entityForUri(uri);
      } catch (_) {
        // Ignore errors that might be caused by non-file uris.
        continue nextUri;
      }

      bool exists;
      try {
        exists = await entity.exists();
      } catch (e) {
        exists = false;
      }

      if (!exists) {
        _generator.invalidate(uri);
        continue nextUri;
      }
      final List<int> newBytes = await entity.readAsBytes();
      if (oldBytes.length != newBytes.length) {
        _generator.invalidate(uri);
        continue nextUri;
      }
      for (int i = 0; i < oldBytes.length; ++i) {
        if (oldBytes[i] != newBytes[i]) {
          _generator.invalidate(uri);
          continue nextUri;
        }
      }
    }
  }

  void _writePackage(KernelCompilationResults result, String package,
      List<Library> libraries, IOSink sink) {
    final canCache = libraries.isNotEmpty &&
        _compilerOptions.bytecode &&
        errors.isEmpty &&
        package != "main";

    if (canCache) {
      var cachedBytes = BinaryCacheMetadataRepository.lookup(libraries.first);
      if (cachedBytes != null) {
        sink.add(cachedBytes);
        return;
      }
    }

    Component partComponent = result.component;
    if (_compilerOptions.bytecode && errors.isEmpty) {
      generateBytecode(partComponent,
          options: _bytecodeOptions,
          libraries: libraries,
          coreTypes: _generator?.getCoreTypes(),
          hierarchy: _generator?.getClassHierarchy());

      if (_options['drop-ast']) {
        partComponent = createFreshComponentWithBytecode(partComponent);
      }
    }

    final byteSink = ByteSink();
    final BinaryPrinter printer = LimitedBinaryPrinter(byteSink,
        (lib) => packageFor(lib) == package, false /* excludeUriToSource */);
    printer.writeComponentFile(partComponent);

    final bytes = byteSink.builder.takeBytes();
    sink.add(bytes);
    if (canCache) {
      BinaryCacheMetadataRepository.insert(libraries.first, bytes);
    }
  }

  @override
  Future<Null> recompileDelta({String entryPoint}) async {
    final String boundaryKey = Uuid().generateV4();
    _outputStream.writeln('result $boundaryKey');
    await invalidateIfInitializingFromDill();
    if (entryPoint != null) {
      _mainSource = _getFileOrUri(entryPoint);
    }
    errors.clear();

    Component deltaProgram = await _generator.compile(entryPoint: _mainSource);
    if (deltaProgram != null && transformer != null) {
      transformer.transform(deltaProgram);
    }

    KernelCompilationResults results = KernelCompilationResults(
        deltaProgram,
        _generator.getClassHierarchy(),
        _generator.getCoreTypes(),
        deltaProgram.uriToSource.keys);

    if (_compilerOptions.target.name == 'dartdevc') {
      await writeJavascriptBundle(results, _kernelBinaryFilename);
    } else {
      await writeDillFile(results, _kernelBinaryFilename,
          incrementalSerializer: _generator.incrementalSerializer);
    }

    _outputStream.writeln(boundaryKey);
    await _outputDependenciesDelta(results.compiledSources);
    _outputStream
        .writeln('$boundaryKey $_kernelBinaryFilename ${errors.length}');
    _kernelBinaryFilename = _kernelBinaryFilenameIncremental;
  }

  @override
  Future<Null> compileExpression(
      String expression,
      List<String> definitions,
      List<String> typeDefinitions,
      String libraryUri,
      String klass,
      bool isStatic) async {
    final String boundaryKey = Uuid().generateV4();
    _outputStream.writeln('result $boundaryKey');
    Procedure procedure = await _generator.compileExpression(
        expression, definitions, typeDefinitions, libraryUri, klass, isStatic);
    if (procedure != null) {
      Component component = createExpressionEvaluationComponent(procedure);
      component = await _generateBytecodeIfNeeded(component);
      final IOSink sink = File(_kernelBinaryFilename).openWrite();
      sink.add(serializeComponent(component));
      await sink.close();
      _outputStream
          .writeln('$boundaryKey $_kernelBinaryFilename ${errors.length}');
      _kernelBinaryFilename = _kernelBinaryFilenameIncremental;
    } else {
      _outputStream.writeln(boundaryKey);
    }
  }

  @override
  void reportError(String msg) {
    final String boundaryKey = Uuid().generateV4();
    _outputStream.writeln('result $boundaryKey');
    _outputStream.writeln(msg);
    _outputStream.writeln(boundaryKey);
  }

  /// Map of already serialized dill data. All uris in a serialized component
  /// maps to the same blob of data. Used by
  /// [writePackagesToSinkAndTrimComponent].
  Map<Uri, List<int>> cachedPackageLibraries = Map<Uri, List<int>>();

  /// Map of dependencies for already serialized dill data.
  /// E.g. if blob1 dependents on blob2, but only using a single file from blob1
  /// that does not dependent on blob2, blob2 would not be included leaving the
  /// dill file in a weird state that could cause the VM to crash if asked to
  /// forcefully compile everything. Used by
  /// [writePackagesToSinkAndTrimComponent].
  Map<Uri, List<Uri>> cachedPackageDependencies = Map<Uri, List<Uri>>();

  writePackagesToSinkAndTrimComponent(
      Component deltaProgram, Sink<List<int>> ioSink) {
    if (deltaProgram == null) return;

    List<Library> packageLibraries = List<Library>();
    List<Library> libraries = List<Library>();
    deltaProgram.computeCanonicalNames();

    for (var lib in deltaProgram.libraries) {
      Uri uri = lib.importUri;
      if (uri.scheme == "package") {
        packageLibraries.add(lib);
      } else {
        libraries.add(lib);
      }
    }
    deltaProgram.libraries
      ..clear()
      ..addAll(libraries);

    Map<String, List<Library>> newPackages = Map<String, List<Library>>();
    Set<List<int>> alreadyAdded = Set<List<int>>();

    addDataAndDependentData(List<int> data, Uri uri) {
      if (alreadyAdded.add(data)) {
        ioSink.add(data);
        // Now also add all dependencies.
        for (Uri dep in cachedPackageDependencies[uri]) {
          addDataAndDependentData(cachedPackageLibraries[dep], dep);
        }
      }
    }

    for (Library lib in packageLibraries) {
      List<int> data = cachedPackageLibraries[lib.fileUri];
      if (data != null) {
        addDataAndDependentData(data, lib.fileUri);
      } else {
        String package = lib.importUri.pathSegments.first;
        newPackages[package] ??= <Library>[];
        newPackages[package].add(lib);
      }
    }

    for (String package in newPackages.keys) {
      List<Library> libraries = newPackages[package];
      Component singleLibrary = Component(
          libraries: libraries,
          uriToSource: deltaProgram.uriToSource,
          nameRoot: deltaProgram.root);
      ByteSink byteSink = ByteSink();
      final BinaryPrinter printer = printerFactory.newBinaryPrinter(byteSink);
      printer.writeComponentFile(singleLibrary);

      // Record things this package blob dependent on.
      Set<Uri> libraryUris = Set<Uri>();
      for (Library lib in libraries) {
        libraryUris.add(lib.fileUri);
      }
      Set<Uri> deps = Set<Uri>();
      for (Library lib in libraries) {
        for (LibraryDependency dep in lib.dependencies) {
          Library dependencyLibrary = dep.importedLibraryReference.asLibrary;
          if (dependencyLibrary.importUri.scheme != "package") continue;
          Uri dependencyLibraryUri =
              dep.importedLibraryReference.asLibrary.fileUri;
          if (libraryUris.contains(dependencyLibraryUri)) continue;
          deps.add(dependencyLibraryUri);
        }
      }

      List<int> data = byteSink.builder.takeBytes();
      for (Library lib in libraries) {
        cachedPackageLibraries[lib.fileUri] = data;
        cachedPackageDependencies[lib.fileUri] = List<Uri>.from(deps);
      }
      ioSink.add(data);
    }
  }

  @override
  void acceptLastDelta() {
    _generator.accept();
  }

  @override
  Future<void> rejectLastDelta() async {
    await _generator.reject();
    final String boundaryKey = Uuid().generateV4();
    _outputStream.writeln('result $boundaryKey');
    _outputStream.writeln(boundaryKey);
  }

  @override
  void invalidate(Uri uri) {
    _generator.invalidate(uri);
  }

  @override
  void resetIncrementalCompiler() {
    _generator.resetDeltaState();
    _kernelBinaryFilename = _kernelBinaryFilenameFull;
  }

  Uri _getFileOrUri(String fileOrUri) =>
      convertFileOrUriArgumentToUri(_fileSystem, fileOrUri);

  IncrementalCompiler _createGenerator(Uri initializeFromDillUri) {
    return IncrementalCompiler(_compilerOptions, _mainSource,
        initializeFromDillUri: initializeFromDillUri,
        incrementalSerialization: incrementalSerialization);
  }

  Uri _ensureFolderPath(String path) {
    String uriPath = Uri.file(path).toString();
    if (!uriPath.endsWith('/')) {
      uriPath = '$uriPath/';
    }
    return Uri.base.resolve(uriPath);
  }

  /// Runs the given function [f] in a Zone that redirects all prints into
  /// [_outputStream].
  Future<T> _runWithPrintRedirection<T>(Future<T> f()) {
    return runZoned(() => Future<T>(f),
        zoneSpecification: ZoneSpecification(
            print: (Zone self, ZoneDelegate parent, Zone zone, String line) =>
                _outputStream.writeln(line)));
  }
}

/// A [Sink] that directly writes data into a byte builder.
class ByteSink implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder();

  void add(List<int> data) {
    builder.add(data);
  }

  void close() {}
}

class _CompileExpressionRequest {
  String expression;
  // Note that FE will reject a compileExpression command by returning a null
  // procedure when defs or typeDefs include an illegal identifier.
  List<String> defs = <String>[];
  List<String> typeDefs = <String>[];
  String library;
  String klass;
  bool isStatic;
}

/// Listens for the compilation commands on [input] stream.
/// This supports "interactive" recompilation mode of execution.
void listenAndCompile(CompilerInterface compiler, Stream<List<int>> input,
    ArgResults options, Completer<int> completer,
    {IncrementalCompiler generator}) {
  _State state = _State.READY_FOR_INSTRUCTION;
  _CompileExpressionRequest compileExpressionRequest;
  String boundaryKey;
  String recompileEntryPoint;
  input
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String string) async {
    switch (state) {
      case _State.READY_FOR_INSTRUCTION:
        const String COMPILE_INSTRUCTION_SPACE = 'compile ';
        const String RECOMPILE_INSTRUCTION_SPACE = 'recompile ';
        const String COMPILE_EXPRESSION_INSTRUCTION_SPACE =
            'compile-expression ';
        if (string.startsWith(COMPILE_INSTRUCTION_SPACE)) {
          final String entryPoint =
              string.substring(COMPILE_INSTRUCTION_SPACE.length);
          await compiler.compile(entryPoint, options, generator: generator);
        } else if (string.startsWith(RECOMPILE_INSTRUCTION_SPACE)) {
          // 'recompile [<entryPoint>] <boundarykey>'
          //   where <boundarykey> can't have spaces
          final String remainder =
              string.substring(RECOMPILE_INSTRUCTION_SPACE.length);
          final int spaceDelim = remainder.lastIndexOf(' ');
          if (spaceDelim > -1) {
            recompileEntryPoint = remainder.substring(0, spaceDelim);
            boundaryKey = remainder.substring(spaceDelim + 1);
          } else {
            boundaryKey = remainder;
          }
          state = _State.RECOMPILE_LIST;
        } else if (string.startsWith(COMPILE_EXPRESSION_INSTRUCTION_SPACE)) {
          // 'compile-expression <boundarykey>
          // expression
          // definitions (one per line)
          // ...
          // <boundarykey>
          // type-defintions (one per line)
          // ...
          // <boundarykey>
          // <libraryUri: String>
          // <klass: String>
          // <isStatic: true|false>
          compileExpressionRequest = _CompileExpressionRequest();
          boundaryKey =
              string.substring(COMPILE_EXPRESSION_INSTRUCTION_SPACE.length);
          state = _State.COMPILE_EXPRESSION_EXPRESSION;
        } else if (string == 'accept') {
          compiler.acceptLastDelta();
        } else if (string == 'reject') {
          await compiler.rejectLastDelta();
        } else if (string == 'reset') {
          compiler.resetIncrementalCompiler();
        } else if (string == 'quit') {
          completer.complete(0);
        }
        break;
      case _State.RECOMPILE_LIST:
        if (string == boundaryKey) {
          compiler.recompileDelta(entryPoint: recompileEntryPoint);
          state = _State.READY_FOR_INSTRUCTION;
        } else
          compiler.invalidate(Uri.base.resolve(string));
        break;
      case _State.COMPILE_EXPRESSION_EXPRESSION:
        compileExpressionRequest.expression = string;
        state = _State.COMPILE_EXPRESSION_DEFS;
        break;
      case _State.COMPILE_EXPRESSION_DEFS:
        if (string == boundaryKey) {
          state = _State.COMPILE_EXPRESSION_TYPEDEFS;
        } else {
          compileExpressionRequest.defs.add(string);
        }
        break;
      case _State.COMPILE_EXPRESSION_TYPEDEFS:
        if (string == boundaryKey) {
          state = _State.COMPILE_EXPRESSION_LIBRARY_URI;
        } else {
          compileExpressionRequest.typeDefs.add(string);
        }
        break;
      case _State.COMPILE_EXPRESSION_LIBRARY_URI:
        compileExpressionRequest.library = string;
        state = _State.COMPILE_EXPRESSION_KLASS;
        break;
      case _State.COMPILE_EXPRESSION_KLASS:
        compileExpressionRequest.klass = string.isEmpty ? null : string;
        state = _State.COMPILE_EXPRESSION_IS_STATIC;
        break;
      case _State.COMPILE_EXPRESSION_IS_STATIC:
        if (string == 'true' || string == 'false') {
          compileExpressionRequest.isStatic = string == 'true';
          compiler.compileExpression(
              compileExpressionRequest.expression,
              compileExpressionRequest.defs,
              compileExpressionRequest.typeDefs,
              compileExpressionRequest.library,
              compileExpressionRequest.klass,
              compileExpressionRequest.isStatic);
        } else {
          compiler
              .reportError('Got $string. Expected either "true" or "false"');
        }
        state = _State.READY_FOR_INSTRUCTION;
        break;
    }
  });
}

/// Entry point for this module, that creates `_FrontendCompiler` instance and
/// processes user input.
/// `compiler` is an optional parameter so it can be replaced with mocked
/// version for testing.
Future<int> starter(
  List<String> args, {
  CompilerInterface compiler,
  Stream<List<int>> input,
  StringSink output,
  IncrementalCompiler generator,
  BinaryPrinterFactory binaryPrinterFactory,
}) async {
  ArgResults options;
  try {
    options = argParser.parse(args);
  } catch (error) {
    print('ERROR: $error\n');
    print(usage);
    return 1;
  }

  if (options['train']) {
    if (options.rest.isEmpty) {
      throw Exception('Must specify input.dart');
    }

    final String input = options.rest[0];
    final String sdkRoot = options['sdk-root'];
    final String platform = options['platform'];
    final Directory temp =
        Directory.systemTemp.createTempSync('train_frontend_server');
    try {
      final String outputTrainingDill = path.join(temp.path, 'app.dill');
      final List<String> args = <String>[
        '--incremental',
        '--sdk-root=$sdkRoot',
        '--output-dill=$outputTrainingDill',
      ];
      if (platform != null) {
        args.add('--platform=${Uri.file(platform)}');
      }
      options = argParser.parse(args);
      compiler ??=
          FrontendCompiler(output, printerFactory: binaryPrinterFactory);

      await compiler.compile(input, options, generator: generator);
      compiler.acceptLastDelta();
      await compiler.recompileDelta();
      compiler.acceptLastDelta();
      compiler.resetIncrementalCompiler();
      await compiler.recompileDelta();
      compiler.acceptLastDelta();
      await compiler.recompileDelta();
      compiler.acceptLastDelta();
      return 0;
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  compiler ??= FrontendCompiler(output,
      printerFactory: binaryPrinterFactory,
      unsafePackageSerialization: options["unsafe-package-serialization"],
      incrementalSerialization: options["incremental-serialization"]);

  if (options.rest.isNotEmpty) {
    return await compiler.compile(options.rest[0], options,
            generator: generator)
        ? 0
        : 254;
  }

  Completer<int> completer = Completer<int>();
  listenAndCompile(compiler, input ?? stdin, options, completer,
      generator: generator);
  return completer.future;
}
