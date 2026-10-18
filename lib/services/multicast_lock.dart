/// Android Wi-Fi MulticastLock bridge (MainActivity.kt, channel
/// `shepherd/multicast_lock`).
///
/// Most Android Wi-Fi stacks drop inbound multicast unless an app
/// holds a MulticastLock, so the CoT listener hears nothing without
/// it. No-op on every other platform; never throws.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class MulticastLock {
  static const _channel = MethodChannel('shepherd/multicast_lock');

  /// True when the lock is held (or the platform needs none).
  static Future<bool> acquire() async {
    if (!Platform.isAndroid) return true;
    try {
      return (await _channel.invokeMethod<bool>('acquire')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
