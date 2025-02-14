// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Defines the VM-specific translation of Dart source code to kernel binaries.
library vm.kernel_front_end;

import 'dart:async';
import 'dart:io' show File, IOSink, IOException;

import 'package:args/args.dart' show ArgParser, ArgResults;

import 'package:build_integration/file_system/multi_root.dart'
    show MultiRootFileSystem, MultiRootFileSystemEntity;

import 'package:crypto/crypto.dart';

import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerContext,
        CompilerOptions,
        CompilerResult,
        DiagnosticMessage,
        DiagnosticMessageHandler,
        FileSystem,
        FileSystemEntity,
        FileSystemException,
        ProcessedOptions,
        Severity,
        StandardFileSystem,
        getMessageUri,
        kernelForProgram,
        parseExperimentalArguments,
        parseExperimentalFlags,
        printDiagnosticMessage;

import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;
import 'package:kernel/ast.dart' show Component, Library, Reference;
import 'package:kernel/binary/ast_to_binary.dart' show BinaryPrinter;
import 'package:kernel/binary/limited_ast_to_binary.dart'
    show LimitedBinaryPrinter;
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/target/targets.dart' show Target, TargetFlags, getTarget;

import 'bytecode/bytecode_serialization.dart' show BytecodeSizeStatistics;
import 'bytecode/gen_bytecode.dart'
    show generateBytecode, createFreshComponentWithBytecode;
import 'bytecode/options.dart' show BytecodeOptions;

import 'target/install.dart' show installAdditionalTargets;
import 'transformations/devirtualization.dart' as devirtualization
    show transformComponent;
import 'transformations/mixin_deduplication.dart' as mixin_deduplication
    show transformComponent;
import 'transformations/no_dynamic_invocations_annotator.dart'
    as no_dynamic_invocations_annotator show transformComponent;
import 'transformations/protobuf_aware_treeshaker/transformer.dart'
    as protobuf_tree_shaker;
import 'transformations/type_flow/transformer.dart' as globalTypeFlow
    show transformComponent;
import 'transformations/obfuscation_prohibitions_annotator.dart'
    as obfuscationProhibitions;
import 'transformations/call_site_annotator.dart' as call_site_annotator;
import 'transformations/unreachable_code_elimination.dart'
    as unreachable_code_elimination;

/// Declare options consumed by [runCompiler].
void declareCompilerOptions(ArgParser args) {
  args.addOption('platform',
      help: 'Path to vm_platform_strong.dill file', defaultsTo: null);
  args.addOption('packages', help: 'Path to .packages file', defaultsTo: null);
  args.addOption('output',
      abbr: 'o', help: 'Path to resulting dill file', defaultsTo: null);
  args.addFlag('aot',
      help:
          'Produce kernel file for AOT compilation (enables global transformations).',
      defaultsTo: false);
  args.addOption('depfile', help: 'Path to output Ninja depfile');
  args.addFlag('link-platform',
      help: 'Include platform into resulting kernel file.', defaultsTo: true);
  args.addFlag('embed-sources',
      help: 'Embed source files in the generated kernel component',
      defaultsTo: true);
  args.addMultiOption('filesystem-root',
      help: 'A base path for the multi-root virtual file system.'
          ' If multi-root file system is used, the input script and .packages file should be specified using URI.');
  args.addOption('filesystem-scheme',
      help: 'The URI scheme for the multi-root virtual filesystem.');
  args.addOption('target',
      help: 'Target model that determines what core libraries are available',
      allowed: <String>['vm', 'flutter', 'flutter_runner', 'dart_runner'],
      defaultsTo: 'vm');
  args.addFlag('tfa',
      help:
          'Enable global type flow analysis and related transformations in AOT mode.',
      defaultsTo: true);
  args.addFlag('protobuf-tree-shaker',
      help: 'Enable protobuf tree shaker transformation in AOT mode.',
      defaultsTo: false);
  args.addMultiOption('define',
      abbr: 'D',
      help: 'The values for the environment constants (e.g. -Dkey=value).');
  args.addFlag('enable-asserts',
      help: 'Whether asserts will be enabled.', defaultsTo: false);
  args.addFlag('split-output-by-packages',
      help:
          'Split resulting kernel file into multiple files (one per package).',
      defaultsTo: false);
  args.addFlag('gen-bytecode', help: 'Generate bytecode', defaultsTo: null);
  args.addMultiOption('bytecode-options',
      help: 'Specify options for bytecode generation:',
      valueHelp: 'opt1,opt2,...',
      allowed: BytecodeOptions.commandLineFlags.keys,
      allowedHelp: BytecodeOptions.commandLineFlags);
  args.addFlag('drop-ast',
      help: 'Include only bytecode into the output file', defaultsTo: true);
  args.addMultiOption('enable-experiment',
      help: 'Comma separated list of experimental features to enable.');
  args.addFlag('help',
      abbr: 'h', negatable: false, help: 'Print this help message.');
}

/// Create ArgParser and populate it with options consumed by [runCompiler].
ArgParser createCompilerArgParser() {
  final ArgParser argParser = new ArgParser(allowTrailingOptions: true);
  declareCompilerOptions(argParser);
  return argParser;
}

const int successExitCode = 0;
const int badUsageExitCode = 1;
const int compileTimeErrorExitCode = 254;

/// Run kernel compiler tool with given [options] and [usage]
/// and return exit code.
Future<int> runCompiler(ArgResults options, String usage) async {
  final String platformKernel = options['platform'];

  if (options['help']) {
    print(usage);
    return successExitCode;
  }

  if ((options.rest.length != 1) || (platformKernel == null)) {
    print(usage);
    return badUsageExitCode;
  }

  final String input = options.rest.single;
  final String outputFileName = options['output'] ?? "$input.dill";
  final String packages = options['packages'];
  final String targetName = options['target'];
  final String fileSystemScheme = options['filesystem-scheme'];
  final String depfile = options['depfile'];
  final List<String> fileSystemRoots = options['filesystem-root'];
  final bool aot = options['aot'];
  final bool tfa = options['tfa'];
  final bool linkPlatform = options['link-platform'];
  final bool embedSources = options['embed-sources'];
  final bool genBytecode = options['gen-bytecode'] ?? aot;
  final bool dropAST = options['drop-ast'];
  final bool enableAsserts = options['enable-asserts'];
  final bool useProtobufTreeShaker = options['protobuf-tree-shaker'];
  final bool splitOutputByPackages = options['split-output-by-packages'];
  final List<String> experimentalFlags = options['enable-experiment'];
  final Map<String, String> environmentDefines = {};

  if (!parseCommandLineDefines(options['define'], environmentDefines, usage)) {
    return badUsageExitCode;
  }

  final BytecodeOptions bytecodeOptions = new BytecodeOptions(
    enableAsserts: enableAsserts,
    emitSourceFiles: embedSources,
    environmentDefines: environmentDefines,
    aot: aot,
  )..parseCommandLineFlags(options['bytecode-options']);

  final target = createFrontEndTarget(targetName);
  if (target == null) {
    print('Failed to create front-end target $targetName.');
    return badUsageExitCode;
  }

  final fileSystem =
      createFrontEndFileSystem(fileSystemScheme, fileSystemRoots);

  final Uri packagesUri = packages != null
      ? convertFileOrUriArgumentToUri(fileSystem, packages)
      : null;

  final platformKernelUri = Uri.base.resolveUri(new Uri.file(platformKernel));
  final List<Uri> linkedDependencies = <Uri>[];
  if (aot || linkPlatform) {
    linkedDependencies.add(platformKernelUri);
  }

  Uri mainUri = convertFileOrUriArgumentToUri(fileSystem, input);
  if (packagesUri != null) {
    mainUri = await convertToPackageUri(fileSystem, mainUri, packagesUri);
  }

  final errorPrinter = new ErrorPrinter();
  final errorDetector = new ErrorDetector(previousErrorHandler: errorPrinter);

  final CompilerOptions compilerOptions = new CompilerOptions()
    ..sdkSummary = platformKernelUri
    ..target = target
    ..fileSystem = fileSystem
    ..linkedDependencies = linkedDependencies
    ..packagesFileUri = packagesUri
    ..experimentalFlags = parseExperimentalFlags(
        parseExperimentalArguments(experimentalFlags),
        onError: print)
    ..onDiagnostic = (DiagnosticMessage m) {
      errorDetector(m);
    }
    ..embedSourceText = embedSources;

  final results = await compileToKernel(mainUri, compilerOptions,
      aot: aot,
      useGlobalTypeFlowAnalysis: tfa,
      environmentDefines: environmentDefines,
      enableAsserts: enableAsserts,
      genBytecode: genBytecode,
      bytecodeOptions: bytecodeOptions,
      dropAST: dropAST && !splitOutputByPackages,
      useProtobufTreeShaker: useProtobufTreeShaker);

  errorPrinter.printCompilationMessages();

  if (errorDetector.hasCompilationErrors || (results.component == null)) {
    return compileTimeErrorExitCode;
  }

  if (bytecodeOptions.showBytecodeSizeStatistics && !splitOutputByPackages) {
    BytecodeSizeStatistics.reset();
  }

  final IOSink sink = new File(outputFileName).openWrite();
  final BinaryPrinter printer = new BinaryPrinter(sink);
  printer.writeComponentFile(results.component);
  await sink.close();

  if (bytecodeOptions.showBytecodeSizeStatistics && !splitOutputByPackages) {
    BytecodeSizeStatistics.dump();
  }

  if (depfile != null) {
    await writeDepfile(
        fileSystem, results.compiledSources, outputFileName, depfile);
  }

  if (splitOutputByPackages) {
    await writeOutputSplitByPackages(
      mainUri,
      compilerOptions,
      results.component,
      results.coreTypes,
      results.classHierarchy,
      outputFileName,
      genBytecode: genBytecode,
      bytecodeOptions: bytecodeOptions,
      dropAST: dropAST,
    );
  }

  return successExitCode;
}

/// Results of [compileToKernel]: generated kernel [Component] and
/// collection of compiled sources.
class KernelCompilationResults {
  final Component component;
  final ClassHierarchy classHierarchy;
  final CoreTypes coreTypes;
  final Iterable<Uri> compiledSources;

  KernelCompilationResults(this.component, this.classHierarchy, this.coreTypes,
      this.compiledSources);
}

/// Generates a kernel representation of the program whose main library is in
/// the given [source]. Intended for whole program (non-modular) compilation.
///
/// VM-specific replacement of [kernelForProgram].
///
Future<KernelCompilationResults> compileToKernel(
    Uri source, CompilerOptions options,
    {bool aot: false,
    bool useGlobalTypeFlowAnalysis: false,
    Map<String, String> environmentDefines,
    bool enableAsserts: true,
    bool genBytecode: false,
    BytecodeOptions bytecodeOptions,
    bool dropAST: false,
    bool useProtobufTreeShaker: false}) async {
  // Replace error handler to detect if there are compilation errors.
  final errorDetector =
      new ErrorDetector(previousErrorHandler: options.onDiagnostic);
  options.onDiagnostic = errorDetector;

  setVMEnvironmentDefines(environmentDefines, options);
  CompilerResult compilerResult = await kernelForProgram(source, options);

  Component component = compilerResult?.component;
  final compiledSources = component?.uriToSource?.keys;

  // Run global transformations only if component is correct.
  if (aot && component != null) {
    await runGlobalTransformations(
        options.target,
        component,
        useGlobalTypeFlowAnalysis,
        enableAsserts,
        useProtobufTreeShaker,
        errorDetector);
  }

  if (genBytecode && !errorDetector.hasCompilationErrors && component != null) {
    await runWithFrontEndCompilerContext(source, options, component, () {
      generateBytecode(component,
          hierarchy: compilerResult.classHierarchy,
          coreTypes: compilerResult.coreTypes,
          options: bytecodeOptions);
    });

    if (dropAST) {
      component = createFreshComponentWithBytecode(component);
    }
  }

  // Restore error handler (in case 'options' are reused).
  options.onDiagnostic = errorDetector.previousErrorHandler;

  return new KernelCompilationResults(component, compilerResult?.classHierarchy,
      compilerResult?.coreTypes, compiledSources);
}

void setVMEnvironmentDefines(
    Map<String, dynamic> environmentDefines, CompilerOptions options) {
  // TODO(alexmarkov): move this logic into VmTarget and call from front-end
  // in order to have the same defines when compiling platform.
  assert(environmentDefines != null);
  if (environmentDefines['dart.vm.product'] == 'true') {
    environmentDefines['dart.developer.causal_async_stacks'] = 'false';
  }
  environmentDefines['dart.isVM'] = 'true';
  // TODO(dartbug.com/36460): Derive dart.library.* definitions from platform.
  for (String library in options.target.extraRequiredLibraries) {
    Uri libraryUri = Uri.parse(library);
    if (libraryUri.scheme == 'dart') {
      final path = libraryUri.path;
      if (!path.startsWith('_')) {
        environmentDefines['dart.library.${path}'] = 'true';
      }
    }
  }
  // dart:core is not mentioned in Target.extraRequiredLibraries.
  environmentDefines['dart.library.core'] = 'true';
  options.environmentDefines = environmentDefines;
}

Future runGlobalTransformations(
    Target target,
    Component component,
    bool useGlobalTypeFlowAnalysis,
    bool enableAsserts,
    bool useProtobufTreeShaker,
    ErrorDetector errorDetector) async {
  if (errorDetector.hasCompilationErrors) return;

  final coreTypes = new CoreTypes(component);

  // TODO(alexmarkov, dmitryas): Consider doing canonicalization of identical
  // mixin applications when creating mixin applications in frontend,
  // so all backends (and all transformation passes from the very beginning)
  // can benefit from mixin de-duplication.
  // At least, in addition to VM/AOT case we should run this transformation
  // when building a platform dill file for VM/JIT case.
  mixin_deduplication.transformComponent(component);

  // Unreachable code elimination transformation should be performed
  // before type flow analysis so TFA won't take unreachable code into account.
  unreachable_code_elimination.transformComponent(component, enableAsserts);

  if (useGlobalTypeFlowAnalysis) {
    globalTypeFlow.transformComponent(target, coreTypes, component);
  } else {
    devirtualization.transformComponent(coreTypes, component);
    no_dynamic_invocations_annotator.transformComponent(component);
  }

  if (useProtobufTreeShaker) {
    if (!useGlobalTypeFlowAnalysis) {
      throw 'Protobuf tree shaker requires type flow analysis (--tfa)';
    }

    protobuf_tree_shaker.removeUnusedProtoReferences(
        component, coreTypes, null);

    globalTypeFlow.transformComponent(target, coreTypes, component);
  }

  // TODO(35069): avoid recomputing CSA by reading it from the platform files.
  void ignoreAmbiguousSupertypes(cls, a, b) {}
  final hierarchy = new ClassHierarchy(component,
      onAmbiguousSupertypes: ignoreAmbiguousSupertypes);
  call_site_annotator.transformLibraries(
      component, component.libraries, coreTypes, hierarchy);

  // We don't know yet whether gen_snapshot will want to do obfuscation, but if
  // it does it will need the obfuscation prohibitions.
  obfuscationProhibitions.transformComponent(component, coreTypes);
}

/// Runs given [action] with [CompilerContext]. This is needed to
/// be able to report compile-time errors.
Future<T> runWithFrontEndCompilerContext<T>(Uri source,
    CompilerOptions compilerOptions, Component component, T action()) async {
  final processedOptions =
      new ProcessedOptions(options: compilerOptions, inputs: [source]);

  // Run within the context, so we have uri source tokens...
  return await CompilerContext.runWithOptions(processedOptions,
      (CompilerContext context) async {
    // To make the fileUri/fileOffset -> line/column mapping, we need to
    // pre-fill the map.
    context.uriToSource.addAll(component.uriToSource);

    return action();
  });
}

class ErrorDetector {
  final DiagnosticMessageHandler previousErrorHandler;
  bool hasCompilationErrors = false;

  ErrorDetector({this.previousErrorHandler});

  void call(DiagnosticMessage message) {
    if (message.severity == Severity.error) {
      hasCompilationErrors = true;
    }

    previousErrorHandler?.call(message);
  }
}

class ErrorPrinter {
  final DiagnosticMessageHandler previousErrorHandler;
  final compilationMessages = <Uri, List<DiagnosticMessage>>{};

  ErrorPrinter({this.previousErrorHandler});

  void call(DiagnosticMessage message) {
    final sourceUri = getMessageUri(message);
    (compilationMessages[sourceUri] ??= <DiagnosticMessage>[]).add(message);
    previousErrorHandler?.call(message);
  }

  void printCompilationMessages() {
    final sortedUris = compilationMessages.keys.toList()
      ..sort((a, b) => '$a'.compareTo('$b'));
    for (final Uri sourceUri in sortedUris) {
      for (final DiagnosticMessage message in compilationMessages[sourceUri]) {
        printDiagnosticMessage(message, print);
      }
    }
  }
}

bool parseCommandLineDefines(
    List<String> dFlags, Map<String, String> environmentDefines, String usage) {
  for (final String dflag in dFlags) {
    final equalsSignIndex = dflag.indexOf('=');
    if (equalsSignIndex < 0) {
      // Ignored.
    } else if (equalsSignIndex > 0) {
      final key = dflag.substring(0, equalsSignIndex);
      final value = dflag.substring(equalsSignIndex + 1);
      environmentDefines[key] = value;
    } else {
      print('The environment constant options must have a key (was: "$dflag")');
      print(usage);
      return false;
    }
  }
  return true;
}

/// Create front-end target with given name.
Target createFrontEndTarget(String targetName,
    {bool trackWidgetCreation = false}) {
  // Make sure VM-specific targets are available.
  installAdditionalTargets();

  final TargetFlags targetFlags =
      new TargetFlags(trackWidgetCreation: trackWidgetCreation);
  return getTarget(targetName, targetFlags);
}

/// Create a front-end file system.
/// If requested, create a virtual mutli-root file system.
FileSystem createFrontEndFileSystem(
    String multiRootFileSystemScheme, List<String> multiRootFileSystemRoots) {
  FileSystem fileSystem = StandardFileSystem.instance;
  if (multiRootFileSystemRoots != null &&
      multiRootFileSystemRoots.isNotEmpty &&
      multiRootFileSystemScheme != null) {
    final rootUris = <Uri>[];
    for (String root in multiRootFileSystemRoots) {
      rootUris.add(Uri.base.resolveUri(new Uri.file(root)));
    }
    fileSystem = new MultiRootFileSystem(
        multiRootFileSystemScheme, rootUris, fileSystem);
  }
  return fileSystem;
}

/// Convert command line argument [input] which is a file or URI to an
/// absolute URI.
///
/// If virtual multi-root file system is used, or [input] can be parsed to a
/// URI with 'package' or 'file' scheme, then [input] is interpreted as URI.
/// Otherwise [input] is interpreted as a file path.
Uri convertFileOrUriArgumentToUri(FileSystem fileSystem, String input) {
  if (input == null) {
    return null;
  }
  // If using virtual multi-root file system, input source argument should be
  // specified as URI.
  if (fileSystem is MultiRootFileSystem) {
    return Uri.base.resolve(input);
  }
  try {
    Uri uri = Uri.parse(input);
    if (uri.scheme == 'package' || uri.scheme == 'file') {
      return uri;
    }
  } on FormatException {
    // Ignore, treat input argument as file path.
  }
  return Uri.base.resolveUri(new Uri.file(input));
}

/// Convert a URI which may use virtual file system schema to a real file URI.
Future<Uri> asFileUri(FileSystem fileSystem, Uri uri) async {
  FileSystemEntity fse = fileSystem.entityForUri(uri);
  if (fse is MultiRootFileSystemEntity) {
    fse = await (fse as MultiRootFileSystemEntity).delegate;
  }
  return fse.uri;
}

/// Convert URI to a package URI if it is inside one of the packages.
Future<Uri> convertToPackageUri(
    FileSystem fileSystem, Uri uri, Uri packagesUri) async {
  if (uri.scheme == 'package') {
    return uri;
  }
  // Convert virtual URI to a real file URI.
  String uriString = (await asFileUri(fileSystem, uri)).toString();
  List<String> packages;
  try {
    packages =
        await new File((await asFileUri(fileSystem, packagesUri)).toFilePath())
            .readAsLines();
  } on IOException {
    // Can't read packages file - silently give up.
    return uri;
  }
  // file:///a/b/x/y/main.dart -> package:x.y/main.dart
  for (var line in packages) {
    if (line.isEmpty || line.startsWith("#")) {
      continue;
    }

    final colon = line.indexOf(':');
    if (colon == -1) {
      continue;
    }
    final packageName = line.substring(0, colon);
    String packagePath;
    try {
      packagePath = (await asFileUri(
              fileSystem, packagesUri.resolve(line.substring(colon + 1))))
          .toString();
    } on FileSystemException {
      // Can't resolve package path.
      continue;
    }
    if (uriString.startsWith(packagePath)) {
      return Uri.parse(
          'package:$packageName/${uriString.substring(packagePath.length)}');
    }
  }
  return uri;
}

/// Write a separate kernel binary for each package. The name of the
/// output kernel binary is '[outputFileName]-$package.dilp'.
/// The list of package names is written into a file '[outputFileName]-packages'.
///
/// Generates bytecode for each package if requested.
Future writeOutputSplitByPackages(
  Uri source,
  CompilerOptions compilerOptions,
  Component component,
  CoreTypes coreTypes,
  ClassHierarchy hierarchy,
  String outputFileName, {
  bool genBytecode: false,
  BytecodeOptions bytecodeOptions,
  bool dropAST: false,
}) async {
  if (bytecodeOptions.showBytecodeSizeStatistics) {
    BytecodeSizeStatistics.reset();
  }

  final packages = new List<String>();
  await runWithFrontEndCompilerContext(source, compilerOptions, component,
      () async {
    // When loading a kernel file list, flutter_runner and dart_runner expect
    // 'main' to be last.
    await forEachPackage(component,
        (String package, List<Library> libraries) async {
      packages.add(package);
      final String filename = '$outputFileName-$package.dilp';
      final IOSink sink = new File(filename).openWrite();

      Component partComponent = component;
      if (genBytecode) {
        generateBytecode(partComponent,
            options: bytecodeOptions,
            libraries: libraries,
            hierarchy: hierarchy,
            coreTypes: coreTypes);

        if (dropAST) {
          partComponent = createFreshComponentWithBytecode(partComponent);
        }
      }

      final BinaryPrinter printer = new LimitedBinaryPrinter(sink,
          (lib) => packageFor(lib) == package, false /* excludeUriToSource */);
      printer.writeComponentFile(partComponent);

      await sink.close();
    }, mainFirst: false);
  });

  if (bytecodeOptions.showBytecodeSizeStatistics) {
    BytecodeSizeStatistics.dump();
  }

  final IOSink packagesList = new File('$outputFileName-packages').openWrite();
  for (String package in packages) {
    packagesList.writeln(package);
  }
  await packagesList.close();
}

String packageFor(Library lib) {
  // Core libraries are not written into any package kernel binaries.
  // ignore: DEPRECATED_MEMBER_USE
  if (lib.isExternal) return null;

  // Packages are written into their own kernel binaries.
  Uri uri = lib.importUri;
  if (uri.scheme == 'package') return uri.pathSegments.first;

  // Everything else (e.g., file: or data: imports) is lumped into the main
  // kernel binary.
  return 'main';
}

/// Sort the libraries etc in the component. Helps packages to produce identical
/// output when their parts are imported in different orders in different
/// contexts.
void sortComponent(Component component) {
  component.libraries.sort((Library a, Library b) {
    return a.importUri.toString().compareTo(b.importUri.toString());
  });
  component.computeCanonicalNames();
  for (Library lib in component.libraries) {
    lib.additionalExports.sort((Reference a, Reference b) {
      return a.canonicalName.toString().compareTo(b.canonicalName.toString());
    });
  }
}

Future<Null> forEachPackage<T>(
    Component component, T action(String package, List<Library> libraries),
    {bool mainFirst}) async {
  sortComponent(component);

  final packages = new Map<String, List<Library>>();
  packages['main'] = new List<Library>(); // Always create 'main'.
  for (Library lib in component.libraries) {
    packages.putIfAbsent(packageFor(lib), () => new List<Library>()).add(lib);
  }
  packages.remove(null); // Ignore external libraries.

  final mainLibraries = packages.remove('main');
  if (mainFirst) {
    await action('main', mainLibraries);
  }

  final mainMethod = component.mainMethod;
  final problemsAsJson = component.problemsAsJson;
  component.mainMethod = null;
  component.problemsAsJson = null;
  for (String package in packages.keys) {
    await action(package, packages[package]);
  }
  component.mainMethod = mainMethod;
  component.problemsAsJson = problemsAsJson;

  if (!mainFirst) {
    await action('main', mainLibraries);
  }
}

String _escapePath(String path) {
  return path.replaceAll('\\', '\\\\').replaceAll(' ', '\\ ');
}

/// Create ninja dependencies file, as described in
/// https://ninja-build.org/manual.html#_depfile
Future<void> writeDepfile(FileSystem fileSystem, Iterable<Uri> compiledSources,
    String output, String depfile) async {
  final IOSink file = new File(depfile).openWrite();
  file.write(_escapePath(output));
  file.write(':');
  for (Uri dep in compiledSources) {
    // Skip empty or corelib dependencies.
    if (dep == null || dep.scheme == 'org-dartlang-sdk') continue;
    Uri uri = await asFileUri(fileSystem, dep);
    file.write(' ');
    file.write(_escapePath(uri.toFilePath()));
  }
  file.write('\n');
  await file.close();
}

Future<void> createFarManifest(
    String output, String dataDir, String packageManifestFilename) async {
  List<String> packages = await File('$output-packages').readAsLines();

  // Make sure the 'main' package is the last (convention with package loader).
  packages.remove('main');
  packages.add('main');

  final IOSink packageManifest = File(packageManifestFilename).openWrite();

  final String kernelListFilename = '$packageManifestFilename.dilplist';
  final IOSink kernelList = File(kernelListFilename).openWrite();
  for (String package in packages) {
    final String filenameInPackage = '$package.dilp';
    final String filenameInBuild = '$output-$package.dilp';
    packageManifest
        .write('data/$dataDir/$filenameInPackage=$filenameInBuild\n');
    kernelList.write('$filenameInPackage\n');
  }
  await kernelList.close();

  final String frameworkVersionFilename =
      '$packageManifestFilename.frameworkversion';
  final IOSink frameworkVersion = File(frameworkVersionFilename).openWrite();
  for (String package in [
    'collection',
    'flutter',
    'meta',
    'typed_data',
    'vector_math'
  ]) {
    Digest digest;
    if (packages.contains(package)) {
      final filenameInBuild = '$output-$package.dilp';
      final bytes = await File(filenameInBuild).readAsBytes();
      digest = sha256.convert(bytes);
    }
    frameworkVersion.write('$package=$digest\n');
  }
  await frameworkVersion.close();

  packageManifest.write('data/$dataDir/app.dilplist=$kernelListFilename\n');
  packageManifest
      .write('data/$dataDir/app.frameworkversion=$frameworkVersionFilename\n');
  await packageManifest.close();
}

// Used by kernel_front_end_test.dart
main() {}
