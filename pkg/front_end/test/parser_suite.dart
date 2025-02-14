// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async' show Future;

import 'dart:convert' show jsonDecode;

import 'dart:io' show File;

import 'dart:typed_data' show Uint8List;

import 'package:front_end/src/fasta/command_line_reporting.dart'
    as command_line_reporting;

import 'package:front_end/src/fasta/messages.dart' show Message;

import 'package:_fe_analyzer_shared/src/parser/parser.dart'
    show Parser, lengthOfSpan;

import 'package:_fe_analyzer_shared/src/scanner/scanner.dart'
    show ErrorToken, ScannerConfiguration, Token, Utf8BytesScanner;

import 'package:_fe_analyzer_shared/src/scanner/utf8_bytes_scanner.dart'
    show Utf8BytesScanner;

import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;

import 'package:front_end/src/fasta/source/stack_listener_impl.dart'
    show offsetForToken;

import 'package:kernel/ast.dart';

import 'package:testing/testing.dart'
    show
        Chain,
        ChainContext,
        ExpectationSet,
        Result,
        Step,
        TestDescription,
        runMe;

import 'utils/kernel_chain.dart' show MatchContext;

import 'parser_test_listener.dart' show ParserTestListener;

import 'parser_test_parser.dart' show TestParser;

const String EXPECTATIONS = '''
[
  {
    "name": "ExpectationFileMismatch",
    "group": "Fail"
  },
  {
    "name": "ExpectationFileMissing",
    "group": "Fail"
  }
]
''';

main([List<String> arguments = const []]) =>
    runMe(arguments, createContext, configurationPath: "../testing.json");

Future<Context> createContext(
    Chain suite, Map<String, String> environment) async {
  return new Context(suite.name, environment["updateExpectations"] == "true",
      environment["trace"] == "true");
}

ScannerConfiguration scannerConfiguration = new ScannerConfiguration(
    enableTripleShift: true,
    enableExtensionMethods: true,
    enableNonNullable: true);

class Context extends ChainContext with MatchContext {
  final bool updateExpectations;
  final bool addTrace;
  final String suiteName;

  Context(this.suiteName, this.updateExpectations, this.addTrace);

  final List<Step> steps = const <Step>[
    const TokenStep(true, ".scanner.expect"),
    const TokenStep(false, ".parser.expect"),
    const ListenerStep(),
    const IntertwinedStep(),
  ];

  final ExpectationSet expectationSet =
      new ExpectationSet.fromJsonList(jsonDecode(EXPECTATIONS));
}

class ListenerStep extends Step<TestDescription, TestDescription, Context> {
  const ListenerStep();

  String get name => "listener";

  Future<Result<TestDescription>> run(
      TestDescription description, Context context) {
    List<int> lineStarts = new List<int>();
    Token firstToken = scanUri(description.uri, lineStarts: lineStarts);

    if (firstToken == null) {
      return Future.value(crash(description, StackTrace.current));
    }

    File f = new File.fromUri(description.uri);
    List<int> rawBytes = f.readAsBytesSync();
    Source source =
        new Source(lineStarts, rawBytes, description.uri, description.uri);

    String shortName = "${context.suiteName}/${description.shortName}";

    ParserTestListenerWithMessageFormatting parserTestListener =
        new ParserTestListenerWithMessageFormatting(
            context.addTrace, source, shortName);
    Parser parser = new Parser(parserTestListener);
    parser.parseUnit(firstToken);

    String errors = "";
    if (parserTestListener.errors.isNotEmpty) {
      errors = "Problems reported:\n\n"
          "${parserTestListener.errors.join("\n\n")}\n\n";
    }

    return context.match<TestDescription>(".expect",
        "${errors}${parserTestListener.sb}", description.uri, description);
  }
}

class IntertwinedStep extends Step<TestDescription, TestDescription, Context> {
  const IntertwinedStep();

  String get name => "intertwined";

  Future<Result<TestDescription>> run(
      TestDescription description, Context context) {
    Token firstToken = scanUri(description.uri);

    if (firstToken == null) {
      return Future.value(crash(description, StackTrace.current));
    }

    ParserTestListenerForIntertwined parserTestListener =
        new ParserTestListenerForIntertwined(context.addTrace);
    TestParser parser = new TestParser(parserTestListener, context.addTrace);
    parserTestListener.parser = parser;
    parser.sb = parserTestListener.sb;
    parser.parseUnit(firstToken);

    return context.match<TestDescription>(
        ".intertwined.expect", "${parser.sb}", description.uri, description);
  }
}

class TokenStep extends Step<TestDescription, TestDescription, Context> {
  final bool onlyScanner;
  final String suffix;

  const TokenStep(this.onlyScanner, this.suffix);

  String get name => "token";

  Future<Result<TestDescription>> run(
      TestDescription description, Context context) {
    List<int> lineStarts = new List<int>();
    Token firstToken = scanUri(description.uri, lineStarts: lineStarts);

    if (firstToken == null) {
      return Future.value(crash(description, StackTrace.current));
    }

    StringBuffer beforeParser = tokenStreamToString(firstToken, lineStarts);
    StringBuffer beforeParserWithTypes =
        tokenStreamToString(firstToken, lineStarts, addTypes: true);
    if (onlyScanner) {
      return context.match<TestDescription>(
          suffix,
          "${beforeParser}\n\n${beforeParserWithTypes}",
          description.uri,
          description);
    }

    ParserTestListener parserTestListener =
        new ParserTestListener(context.addTrace);
    Parser parser = new Parser(parserTestListener);
    bool parserCrashed = false;
    dynamic parserCrashedE;
    StackTrace parserCrashedSt;
    try {
      parser.parseUnit(firstToken);
    } catch (e, st) {
      parserCrashed = true;
      parserCrashedE = e;
      parserCrashedSt = st;
    }

    StringBuffer afterParser = tokenStreamToString(firstToken, lineStarts);
    StringBuffer afterParserWithTypes =
        tokenStreamToString(firstToken, lineStarts, addTypes: true);

    bool rewritten = beforeParser.toString() != afterParser.toString();
    String rewrittenString =
        rewritten ? "NOTICE: Stream was rewritten by parser!\n\n" : "";

    Future<Result<TestDescription>> result = context.match<TestDescription>(
        suffix,
        "${rewrittenString}${afterParser}\n\n${afterParserWithTypes}",
        description.uri,
        description);
    return result.then((result) {
      if (parserCrashed) {
        return crash("Parser crashed: $parserCrashedE", parserCrashedSt);
      } else {
        return result;
      }
    });
  }

  StringBuffer tokenStreamToString(Token firstToken, List<int> lineStarts,
      {bool addTypes: false}) {
    StringBuffer sb = new StringBuffer();
    Token token = firstToken;
    bool printed = false;
    int endOfLast = -1;
    int lineStartsIteratorLine = 1;
    Iterator<int> lineStartsIterator = lineStarts.iterator;
    lineStartsIterator.moveNext();
    lineStartsIterator.moveNext();
    lineStartsIteratorLine++;
    while (token != null) {
      int prevLine = lineStartsIteratorLine;
      while (token.offset >= lineStartsIterator.current &&
          lineStartsIterator.moveNext()) {
        lineStartsIteratorLine++;
      }
      if (printed &&
          (token.offset > endOfLast || prevLine < lineStartsIteratorLine)) {
        if (prevLine < lineStartsIteratorLine) {
          for (int i = prevLine; i < lineStartsIteratorLine; i++) {
            sb.write("\n");
          }
        } else {
          sb.write(" ");
        }
      }
      if (token is! ErrorToken) {
        sb.write(token.lexeme);
      }
      if (addTypes) {
        sb.write("[${token.runtimeType}]");
      }
      printed = true;
      endOfLast = token.end;
      if (token == token.next) break;
      token = token.next;
    }
    return sb;
  }
}

Token scanUri(Uri uri, {List<int> lineStarts}) {
  File f = new File.fromUri(uri);
  List<int> rawBytes = f.readAsBytesSync();

  Uint8List bytes = new Uint8List(rawBytes.length + 1);
  bytes.setRange(0, rawBytes.length, rawBytes);

  Utf8BytesScanner scanner = new Utf8BytesScanner(bytes,
      includeComments: true, configuration: scannerConfiguration);
  Token firstToken = scanner.tokenize();
  if (lineStarts != null) {
    lineStarts.addAll(scanner.lineStarts);
  }
  return firstToken;
}

class ParserTestListenerWithMessageFormatting extends ParserTestListener {
  final Source source;
  final String shortName;
  final List<String> errors = new List<String>();

  ParserTestListenerWithMessageFormatting(
      bool trace, this.source, this.shortName)
      : super(trace);

  void handleRecoverableError(
      Message message, Token startToken, Token endToken) {
    if (source != null) {
      Location location =
          source.getLocation(source.fileUri, offsetForToken(startToken));
      int length = lengthOfSpan(startToken, endToken);
      if (length <= 0) length = 1;
      errors.add(command_line_reporting.formatErrorMessage(
          source.getTextLine(location.line),
          location,
          length,
          shortName,
          message.message));
    } else {
      errors.add(message.message);
    }

    super.handleRecoverableError(message, startToken, endToken);
  }
}

class ParserTestListenerForIntertwined
    extends ParserTestListenerWithMessageFormatting {
  TestParser parser;

  ParserTestListenerForIntertwined(bool trace) : super(trace, null, null);

  void doPrint(String s) {
    int prevIndent = super.indent;
    super.indent = parser.indent;
    super.doPrint("listener: " + s);
    super.indent = prevIndent;
  }
}
