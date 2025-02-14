// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.member_builder;

import 'dart:core' hide MapEntry;

import 'package:kernel/ast.dart';

import '../../base/common.dart';

import '../kernel/class_hierarchy_builder.dart';
import '../problems.dart' show unsupported;
import '../type_inference/type_inference_engine.dart'
    show InferenceDataForTesting;

import 'builder.dart';
import 'class_builder.dart';
import 'declaration_builder.dart';
import 'extension_builder.dart';
import 'library_builder.dart';
import 'modifier_builder.dart';

abstract class MemberBuilder implements ModifierBuilder, ClassMember {
  void set parent(Builder value);

  LibraryBuilder get library;

  /// The [Member] built by this builder;
  Member get member;

  /// The [Member] to use when reading from this member builder.
  ///
  /// For a field, a getter or a regular method this is the [member] itself.
  /// For an instance extension method this is special tear-off function. For
  /// a constructor, an operator, a factory or a setter this is `null`.
  Member get readTarget;

  /// The [Member] to use when write to this member builder.
  ///
  /// For an assignable field or a setter this is the [member] itself. For
  /// a constructor, a non-assignable field, a getter, an operator or a regular
  /// method this is `null`.
  Member get writeTarget;

  /// The [Member] to use when invoking this member builder.
  ///
  /// For a constructor, a field, a regular method, a getter an operator or
  /// a factory this is the [member] itself. For a setter this is `null`.
  Member get invokeTarget;

  // TODO(johnniwinther): Remove this and create a [ProcedureBuilder] interface.
  ProcedureKind get kind;

  void buildOutlineExpressions(LibraryBuilder library);

  void inferType();

  void inferCopiedType(covariant Object other);
}

abstract class MemberBuilderImpl extends ModifierBuilderImpl
    implements MemberBuilder {
  /// For top-level members, the parent is set correctly during
  /// construction. However, for class members, the parent is initially the
  /// library and updated later.
  @override
  Builder parent;

  @override
  String get name;

  MemberDataForTesting dataForTesting;

  MemberBuilderImpl(this.parent, int charOffset)
      : dataForTesting =
            retainDataForTesting ? new MemberDataForTesting() : null,
        super(parent, charOffset);

  @override
  bool get isDeclarationInstanceMember => isDeclarationMember && !isStatic;

  @override
  bool get isClassInstanceMember => isClassMember && !isStatic;

  @override
  bool get isExtensionInstanceMember => isExtensionMember && !isStatic;

  @override
  bool get isDeclarationMember => parent is DeclarationBuilder;

  @override
  bool get isClassMember => parent is ClassBuilder;

  @override
  bool get isExtensionMember => parent is ExtensionBuilder;

  @override
  bool get isTopLevel => !isDeclarationMember;

  @override
  bool get isNative => false;

  bool get isRedirectingGenerativeConstructor => false;

  @override
  LibraryBuilder get library {
    if (parent is LibraryBuilder) {
      LibraryBuilder library = parent;
      return library.partOfLibrary ?? library;
    } else if (parent is ExtensionBuilder) {
      ExtensionBuilder extension = parent;
      return extension.library;
    } else {
      ClassBuilder cls = parent;
      return cls.library;
    }
  }

  // TODO(johnniwinther): Remove this and create a [ProcedureBuilder] interface.
  @override
  ProcedureKind get kind => unsupported("kind", charOffset, fileUri);

  @override
  void buildOutlineExpressions(LibraryBuilder library) {}

  void buildMembers(
      LibraryBuilder library, void Function(Member, BuiltMemberKind) f);

  @override
  String get fullNameForErrors => name;

  @override
  void inferType() => unsupported("inferType", charOffset, fileUri);

  @override
  void inferCopiedType(covariant Object other) {
    unsupported("inferType", charOffset, fileUri);
  }

  @override
  ClassBuilder get classBuilder => parent is ClassBuilder ? parent : null;
}

enum BuiltMemberKind {
  Constructor,
  RedirectingFactory,
  Field,
  Method,
  ExtensionField,
  ExtensionMethod,
  ExtensionGetter,
  ExtensionSetter,
  ExtensionOperator,
  ExtensionTearOff,
}

class MemberDataForTesting {
  final InferenceDataForTesting inferenceData = new InferenceDataForTesting();

  MemberBuilder patchForTesting;
}
