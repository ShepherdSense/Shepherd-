/// Golden-vector test for the disturbance classifier (v0.24.0 fix for
/// the Reviewer-2 finding that no automated Dart test loaded the
/// shipped weights).
///
/// Loads the SHIPPED model (assets/models/disturbance_clf.json) into
/// the real TinyMlp kernel and checks its probabilities on the fixed
/// golden feature vector against test/ai_golden.json — the expected
/// output written by tools/train_disturbance_clf.py from scikit-learn.
/// If the weights and the Dart kernel ever drift apart, this fails.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/tiny_ml.dart';

void main() {
  test('shipped disturbance_clf weights reproduce the golden vector', () {
    final modelJson = jsonDecode(
      File('assets/models/disturbance_clf.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final golden = jsonDecode(
      File('test/ai_golden.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    final mlp = TinyMlp.fromJson(modelJson);
    final x = (golden['x'] as List).map((v) => (v as num).toDouble()).toList();
    final classes = (golden['classes'] as List).map((c) => '$c').toList();
    final expected =
        (golden['probs'] as List).map((v) => (v as num).toDouble()).toList();

    expect(mlp.classNames, classes);
    final probs = mlp.predictProbs(x);
    for (var i = 0; i < classes.length; i++) {
      expect(
        probs[classes[i]],
        closeTo(expected[i], 1e-6),
        reason: 'golden probability drift for class ${classes[i]}',
      );
    }
    final (label, confidence) = mlp.classify(x);
    var best = 0;
    for (var i = 1; i < expected.length; i++) {
      if (expected[i] > expected[best]) best = i;
    }
    expect(label, classes[best]);
    expect(confidence, closeTo(expected[best], 1e-6));
  });

  test('golden vector class order matches the model classes', () {
    final modelJson = jsonDecode(
      File('assets/models/disturbance_clf.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final golden = jsonDecode(
      File('test/ai_golden.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(golden['classes'], modelJson['classes']);
    expect(modelJson['feature_names'] as List, hasLength(10));
  });
}
