import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart'; // Import for date formatting

/// Simple logging utility class.
class Log {
  // Date formatter for timestamps
  static final _formatter = DateFormat('HH:mm:ss.SSS');

  static void _log(String level, String emoji, String message) {
    if (kDebugMode) {
      final timestamp = _formatter.format(DateTime.now());
      debugPrint('[$level] $timestamp $emoji $message');
    }
  }

  /// Logs an informational message.
  static void info(String message) {
    _log('INFO', '💙', message);
  }

  /// Logs a debug message (more verbose).
  static void debug(String message) {
    _log('DEBUG', '🐛', message);
  }

  /// Logs an error message, optionally including the error object and stack trace.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    final timestamp = _formatter.format(DateTime.now());
    if (kDebugMode) {
      debugPrint('[ERROR] $timestamp 💥 $message');
      if (error != null) {
        debugPrint('  Error: $error');
      }
      if (stackTrace != null) {
        debugPrint('  StackTrace: $stackTrace');
      }
    }
    // In a real app, you would send this to an error reporting service
    // (e.g., Sentry, Firebase Crashlytics).
  }
}
