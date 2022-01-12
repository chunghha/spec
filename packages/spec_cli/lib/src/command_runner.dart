import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod/riverpod.dart';

import 'container.dart';
import 'dart_test.dart';
import 'io.dart';
import 'renderer.dart';
import 'rendering.dart';
import 'suites.dart';
import 'tests.dart';
import 'vt100.dart';

Future<int> specCommandRunner(List<String> args) async {
  return spec(options: SpecOptions.fromArgs(args));
}

@immutable
class SpecOptions {
  const SpecOptions({
    this.fileFilters = const [],
    this.testNameFilters = const [],
    this.watch = false,
    this.coverage = false,
  });

  factory SpecOptions.fromArgs(List<String> args) {
    final parser = ArgParser()
      ..addFlag(
        'watch',
        abbr: 'w',
        negatable: false,
        help: 'Listens to changes in the project and '
            'run tests whenever something changed',
      )
      ..addFlag(
        'coverage',
        abbr: 'c',
        negatable: false,
        help: 'Extract code coverage reports.',
      )
      ..addMultiOption(
        'name',
        abbr: 'n',
        help: 'Filters tests by name.',
      );

    final result = parser.parse(args);

    return SpecOptions(
      watch: result['watch'] as bool,
      fileFilters: result.rest,
      testNameFilters: result['name'] as List<String>,
      coverage: result['coverage'] as bool,
    );
  }

  final List<String> fileFilters;
  final List<String> testNameFilters;
  final bool watch;
  final bool coverage;

  @override
  bool operator ==(Object other) =>
      other is SpecOptions &&
      other.runtimeType == runtimeType &&
      other.coverage == coverage &&
      other.watch == watch &&
      const DeepCollectionEquality().equals(other.fileFilters, fileFilters) &&
      const DeepCollectionEquality()
          .equals(testNameFilters, other.testNameFilters);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        coverage,
        watch,
        const DeepCollectionEquality().hash(fileFilters),
        const DeepCollectionEquality().hash(testNameFilters),
      );

  @override
  String toString() {
    return 'SpecOptions('
        'watch: $watch, '
        'coverage: $coverage, '
        'fileFilters: $fileFilters, '
        'testNameFilters: $testNameFilters'
        ')';
  }
}

Future<int> spec({
  String? workingDirectory,
  SpecOptions options = const SpecOptions(),
}) {
  return runScoped((ref) async {
    // initializing option providers from command line options.
    ref.read($testNameFilters.notifier).state = options.testNameFilters;
    ref.read($filePathFilters.notifier).state = options.fileFilters;

    if (options.watch) {
      stdout.write('${VT100.clearScreen}${VT100.moveCursorToTopLeft}');

      ref.listen(
        $fileChange,
        (prev, value) {
          ref.refresh($events);
        },
      );

      var lastFailedTests = <FailedTestLocation>[];
      ref.listen<AsyncValue<List<FailedTestLocation>>>(
          $currentlyFailedTestsLocation, (prev, value) {
        value.when(
          data: (value) => lastFailedTests = value,
          loading: () => lastFailedTests = [],
          error: (err, stack) {
            Zone.current.handleUncaughtError(err, stack!);
          },
        );
      });

      ref.listen($fileChange, (prev, value) {
        ref.read($failedTestsLocationFromPreviousRun.notifier).state =
            lastFailedTests;
      });
      stdin.listen((event) {
        if (event.first == 10) {
          // enter
          ref.read($failedTestsLocationFromPreviousRun.notifier).state =
              lastFailedTests;
        }
      });
    }

    final renderer = rendererOverride ??
        (options.watch ? FullScreenRenderer() : BacktrackingRenderer());

    ref.listen<AsyncValue<String>>(
      $output,
      (lastOutput, output) {
        output.when(
          loading: () {}, // nothing to do
          error: (err, stack) {
            Zone.current.handleUncaughtError(err, stack!);
          },
          data: (output) {
            if (output.trim().isNotEmpty) renderer.renderFrame(output);
          },
        );
      },
      fireImmediately: true,
    );

    return ref.read($exitCode.future);
  }, overrides: [
    $startTime.overrideWithValue(DateTime.now()),
    if (workingDirectory != null)
      $workingDirectory.overrideWithValue(Directory(workingDirectory)),
  ]);
}
