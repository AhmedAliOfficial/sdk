// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:core' hide MapEntry;

import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;

import 'package:kernel/ast.dart' hide Variance;

import '../constant_context.dart' show ConstantContext;

import '../kernel/body_builder.dart' show BodyBuilder;

import '../kernel/expression_generator_helper.dart'
    show ExpressionGeneratorHelper;

import '../kernel/kernel_builder.dart'
    show isRedirectingGenerativeConstructorImplementation;

import '../loader.dart' show Loader;

import '../messages.dart'
    show
        Message,
        messageMoreThanOneSuperOrThisInitializer,
        messageSuperInitializerNotLast,
        messageThisInitializerNotAlone,
        noLength;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import 'builder.dart';
import 'class_builder.dart';
import 'formal_parameter_builder.dart';
import 'function_builder.dart';
import 'library_builder.dart';
import 'member_builder.dart';
import 'metadata_builder.dart';
import 'type_builder.dart';
import 'type_variable_builder.dart';

abstract class ConstructorBuilder implements FunctionBuilder {
  int get charOpenParenOffset;

  bool hasMovedSuperInitializer;

  SuperInitializer superInitializer;

  RedirectingInitializer redirectingInitializer;

  Token beginInitializers;

  @override
  ConstructorBuilder get actualOrigin;

  ConstructorBuilder get patchForTesting;

  Constructor get actualConstructor;

  @override
  ConstructorBuilder get origin;

  bool get isRedirectingGenerativeConstructor;

  bool get isEligibleForTopLevelInference;

  /// The [Constructor] built by this builder.
  Constructor get constructor;

  void injectInvalidInitializer(
      Message message, int charOffset, ExpressionGeneratorHelper helper);

  void addInitializer(
      Initializer initializer, ExpressionGeneratorHelper helper);

  void prepareInitializers();
}

class ConstructorBuilderImpl extends FunctionBuilderImpl
    implements ConstructorBuilder {
  final Constructor _constructor;

  @override
  final int charOpenParenOffset;

  @override
  bool hasMovedSuperInitializer = false;

  @override
  SuperInitializer superInitializer;

  @override
  RedirectingInitializer redirectingInitializer;

  @override
  Token beginInitializers;

  @override
  ConstructorBuilder actualOrigin;

  @override
  Constructor get actualConstructor => _constructor;

  ConstructorBuilderImpl(
      List<MetadataBuilder> metadata,
      int modifiers,
      TypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      SourceLibraryBuilder compilationUnit,
      int startCharOffset,
      int charOffset,
      this.charOpenParenOffset,
      int charEndOffset,
      [String nativeMethodName])
      : _constructor = new Constructor(null, fileUri: compilationUnit?.fileUri)
          ..startFileOffset = startCharOffset
          ..fileOffset = charOffset
          ..fileEndOffset = charEndOffset,
        super(metadata, modifiers, returnType, name, typeVariables, formals,
            compilationUnit, charOffset, nativeMethodName);

  @override
  Member get readTarget => null;

  @override
  Member get writeTarget => null;

  @override
  Member get invokeTarget => constructor;

  @override
  ConstructorBuilder get origin => actualOrigin ?? this;

  @override
  ConstructorBuilder get patchForTesting => dataForTesting?.patchForTesting;

  @override
  bool get isDeclarationInstanceMember => false;

  @override
  bool get isClassInstanceMember => false;

  @override
  bool get isConstructor => true;

  @override
  AsyncMarker get asyncModifier => AsyncMarker.Sync;

  @override
  ProcedureKind get kind => null;

  @override
  bool get isRedirectingGenerativeConstructor {
    return isRedirectingGenerativeConstructorImplementation(_constructor);
  }

  @override
  bool get isEligibleForTopLevelInference {
    if (formals != null) {
      for (FormalParameterBuilder formal in formals) {
        if (formal.type == null && formal.isInitializingFormal) return true;
      }
    }
    return false;
  }

  @override
  void buildMembers(
      LibraryBuilder library, void Function(Member, BuiltMemberKind) f) {
    Member member = build(library);
    f(member, BuiltMemberKind.Constructor);
  }

  @override
  Constructor build(SourceLibraryBuilder libraryBuilder) {
    if (_constructor.name == null) {
      _constructor.function = buildFunction(libraryBuilder);
      _constructor.function.parent = _constructor;
      _constructor.function.fileOffset = charOpenParenOffset;
      _constructor.function.fileEndOffset = _constructor.fileEndOffset;
      _constructor.function.typeParameters = const <TypeParameter>[];
      _constructor.isConst = isConst;
      _constructor.isExternal = isExternal;
      _constructor.name = new Name(name, libraryBuilder.library);
    }
    if (isEligibleForTopLevelInference) {
      for (FormalParameterBuilder formal in formals) {
        if (formal.type == null && formal.isInitializingFormal) {
          formal.variable.type = null;
        }
      }
      libraryBuilder.loader.typeInferenceEngine.toBeInferred[_constructor] =
          libraryBuilder;
    }
    return _constructor;
  }

  @override
  void buildOutlineExpressions(LibraryBuilder library) {
    super.buildOutlineExpressions(library);

    // For modular compilation purposes we need to include initializers
    // for const constructors into the outline.
    if (isConst && beginInitializers != null) {
      ClassBuilder classBuilder = parent;
      BodyBuilder bodyBuilder = library.loader
          .createBodyBuilderForOutlineExpression(
              library, classBuilder, this, classBuilder.scope, fileUri);
      bodyBuilder.constantContext = ConstantContext.required;
      bodyBuilder.parseInitializers(beginInitializers);
      bodyBuilder.resolveRedirectingFactoryTargets();
    }
    beginInitializers = null;
  }

  @override
  FunctionNode buildFunction(LibraryBuilder library) {
    // According to the specification §9.3 the return type of a constructor
    // function is its enclosing class.
    FunctionNode functionNode = super.buildFunction(library);
    ClassBuilder enclosingClassBuilder = parent;
    Class enclosingClass = enclosingClassBuilder.cls;
    List<DartType> typeParameterTypes = new List<DartType>();
    for (int i = 0; i < enclosingClass.typeParameters.length; i++) {
      TypeParameter typeParameter = enclosingClass.typeParameters[i];
      typeParameterTypes.add(new TypeParameterType(typeParameter));
    }
    functionNode.returnType =
        new InterfaceType(enclosingClass, typeParameterTypes);
    return functionNode;
  }

  @override
  Constructor get constructor => isPatch ? origin.constructor : _constructor;

  @override
  Member get member => constructor;

  @override
  void injectInvalidInitializer(
      Message message, int charOffset, ExpressionGeneratorHelper helper) {
    List<Initializer> initializers = _constructor.initializers;
    Initializer lastInitializer = initializers.removeLast();
    assert(lastInitializer == superInitializer ||
        lastInitializer == redirectingInitializer);
    Initializer error = helper.buildInvalidInitializer(
        helper.buildProblem(message, charOffset, noLength));
    initializers.add(error..parent = _constructor);
    initializers.add(lastInitializer);
  }

  @override
  void addInitializer(
      Initializer initializer, ExpressionGeneratorHelper helper) {
    List<Initializer> initializers = _constructor.initializers;
    if (initializer is SuperInitializer) {
      if (superInitializer != null || redirectingInitializer != null) {
        injectInvalidInitializer(messageMoreThanOneSuperOrThisInitializer,
            initializer.fileOffset, helper);
      } else {
        initializers.add(initializer..parent = _constructor);
        superInitializer = initializer;
      }
    } else if (initializer is RedirectingInitializer) {
      if (superInitializer != null || redirectingInitializer != null) {
        injectInvalidInitializer(messageMoreThanOneSuperOrThisInitializer,
            initializer.fileOffset, helper);
      } else if (_constructor.initializers.isNotEmpty) {
        Initializer first = _constructor.initializers.first;
        Initializer error = helper.buildInvalidInitializer(helper.buildProblem(
            messageThisInitializerNotAlone, first.fileOffset, noLength));
        initializers.add(error..parent = _constructor);
      } else {
        initializers.add(initializer..parent = _constructor);
        redirectingInitializer = initializer;
      }
    } else if (redirectingInitializer != null) {
      injectInvalidInitializer(
          messageThisInitializerNotAlone, initializer.fileOffset, helper);
    } else if (superInitializer != null) {
      injectInvalidInitializer(
          messageSuperInitializerNotLast, superInitializer.fileOffset, helper);
    } else {
      initializers.add(initializer..parent = _constructor);
    }
  }

  @override
  int finishPatch() {
    if (!isPatch) return 0;

    // TODO(ahe): restore file-offset once we track both origin and patch file
    // URIs. See https://github.com/dart-lang/sdk/issues/31579
    origin.constructor.fileUri = fileUri;
    origin.constructor.startFileOffset = _constructor.startFileOffset;
    origin.constructor.fileOffset = _constructor.fileOffset;
    origin.constructor.fileEndOffset = _constructor.fileEndOffset;
    origin.constructor.annotations
        .forEach((m) => m.fileOffset = _constructor.fileOffset);

    origin.constructor.isExternal = _constructor.isExternal;
    origin.constructor.function = _constructor.function;
    origin.constructor.function.parent = origin.constructor;
    origin.constructor.initializers = _constructor.initializers;
    setParents(origin.constructor.initializers, origin.constructor);
    return 1;
  }

  @override
  void becomeNative(Loader loader) {
    _constructor.isExternal = true;
    super.becomeNative(loader);
  }

  @override
  void applyPatch(Builder patch) {
    if (patch is ConstructorBuilderImpl) {
      if (checkPatch(patch)) {
        patch.actualOrigin = this;
        dataForTesting?.patchForTesting = patch;
      }
    } else {
      reportPatchMismatch(patch);
    }
  }

  @override
  void prepareInitializers() {
    // For const constructors we parse initializers already at the outlining
    // stage, there is no easy way to make body building stage skip initializer
    // parsing, so we simply clear parsed initializers and rebuild them
    // again.
    // Note: this method clears both initializers from the target Kernel node
    // and internal state associated with parsing initializers.
    if (_constructor.isConst) {
      _constructor.initializers.length = 0;
      redirectingInitializer = null;
      superInitializer = null;
      hasMovedSuperInitializer = false;
    }
  }
}
