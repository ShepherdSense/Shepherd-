/// Shared inference kernel for Shepherd's tiny embedded models.
///
/// Both the disturbance classifier and the track stitcher are small
/// multilayer perceptrons (standardized inputs, relu hidden layers)
/// trained in Python with scikit-learn and exported as JSON. The
/// output activation mirrors sklearn exactly: softmax for 3+ classes,
/// single logistic output for the binary case. This file implements
/// the one exact forward pass they share — pure Dart math, no native
/// plugins — so there is a single kernel to verify (see
/// test/ai_golden.json and test/stitcher_golden.json).
///
/// These are narrow task specialists, not LLMs. They never detect
/// anything on their own: the deterministic tripwire/tracker remain the
/// detectors, and model outputs are shown as estimates with confidence.
library;

import 'dart:convert';
import 'dart:math';

class DenseLayer {
  DenseLayer(this.w, this.b);

  /// w[out][in]
  final List<List<double>> w;
  final List<double> b;
}

class TinyMlp {
  TinyMlp._(
    this.classNames,
    this.mean,
    this.scale,
    this.layers,
    this.holdoutAccuracy,
  );

  final List<String> classNames;
  final List<double> mean;
  final List<double> scale;
  final List<DenseLayer> layers;
  final double holdoutAccuracy;

  /// Build from a decoded model document in the format written by
  /// tools/train_*.py (feature_names, classes, scaler_mean,
  /// scaler_scale, layers[{W, b}], holdout_accuracy).
  factory TinyMlp.fromJson(Map<String, dynamic> j) {
    final layers = [
      for (final l in (j['layers'] as List).cast<Map<String, dynamic>>())
        DenseLayer(
          (l['W'] as List)
              .map((r) =>
                  (r as List).map((v) => (v as num).toDouble()).toList())
              .toList(),
          (l['b'] as List).map((v) => (v as num).toDouble()).toList(),
        ),
    ];
    return TinyMlp._(
      (j['classes'] as List).map((c) => '$c').toList(),
      (j['scaler_mean'] as List).map((v) => (v as num).toDouble()).toList(),
      (j['scaler_scale'] as List).map((v) => (v as num).toDouble()).toList(),
      layers,
      (j['holdout_accuracy'] as num).toDouble(),
    );
  }

  /// Class name -> probability. Standardize, relu hidden layers,
  /// softmax output.
  Map<String, double> predictProbs(List<double> features) {
    var a = [
      for (var i = 0; i < features.length; i++)
        (features[i] - mean[i]) / scale[i],
    ];
    for (var li = 0; li < layers.length; li++) {
      final l = layers[li];
      final last = li == layers.length - 1;
      final out = List<double>.filled(l.b.length, 0.0);
      for (var j = 0; j < l.b.length; j++) {
        var s = l.b[j];
        final wj = l.w[j];
        for (var i = 0; i < a.length; i++) {
          s += wj[i] * a[i];
        }
        out[j] = last ? s : (s > 0 ? s : 0.0);
      }
      a = out;
    }
    var m = a[0];
    for (final v in a) {
      if (v > m) m = v;
    }
    // Output activation mirrors scikit-learn's MLPClassifier: softmax
    // for 3+ classes, but a SINGLE logistic output for the binary
    // case (where it models P(classNames[1])).
    if (a.length == 1 && classNames.length == 2) {
      final p1 = 1.0 / (1.0 + exp(-a[0]));
      return {classNames[0]: 1.0 - p1, classNames[1]: p1};
    }
    var z = 0.0;
    final e = List<double>.filled(a.length, 0.0);
    for (var j = 0; j < a.length; j++) {
      e[j] = exp(a[j] - m);
      z += e[j];
    }
    return {for (var j = 0; j < classNames.length; j++) classNames[j]: e[j] / z};
  }

  /// (top class name, confidence).
  (String, double) classify(List<double> features) {
    final probs = predictProbs(features);
    var best = classNames[0];
    var bestP = -1.0;
    probs.forEach((k, p) {
      if (p > bestP) {
        bestP = p;
        best = k;
      }
    });
    // NaN inputs give NaN probabilities, which no `p > bestP` ever wins:
    // report "no answer" (confidence 0) rather than a fake class at -100%.
    if (!bestP.isFinite || bestP < 0) return (classNames[0], 0.0);
    return (best, bestP);
  }

  static Map<String, dynamic> decodeJson(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;
}
