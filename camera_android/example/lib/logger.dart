import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

class Logger {
  Logger._();

  static void d(Object? message) {
    if (kDebugMode) {
      dev.log('[DEBUG] $message', name: '🔍');
    }
  }

  static void e(String message) {
    if (kDebugMode) {
      dev.log('[ERROR] $message', name: '❌');
    }
  }

  static void log(Object? msg, {String tag = 'Camera Example'}) {
    dev.log('$msg', name: tag);
  }
}
