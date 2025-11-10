// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Data for native board overlay processing
///
/// Native will calculate coordinates after knowing actual camera image size
@immutable
class BoardOverlayData {
  /// Creates board overlay data for native processing
  const BoardOverlayData({
    required this.boardImageBytes,
    required this.boardScreenX,
    required this.boardScreenY,
    required this.boardScreenWidth,
    required this.boardScreenHeight,
    required this.previewWidth,
    required this.previewHeight,
    required this.devicePixelRatio,
    required this.targetWidth,
    required this.targetHeight,
    required this.deviceOrientationDegrees,
    this.usePreviewFrame = false,
  });

  /// Board image as PNG/JPEG bytes (high-DPI screenshot)
  final Uint8List boardImageBytes;

  /// Board position on screen (logical pixels)
  final double boardScreenX;
  final double boardScreenY;

  /// Board widget size on screen (logical pixels)
  final double boardScreenWidth;
  final double boardScreenHeight;

  /// Preview size for coordinate mapping
  final double previewWidth;
  final double previewHeight;

  /// Device pixel ratio (for board screenshot)
  final double devicePixelRatio;

  /// Target output image size
  final int targetWidth;
  final int targetHeight;

  /// Device orientation in degrees (0, 90, 180, 270)
  final int deviceOrientationDegrees;

  /// Whether to capture using the preview frame instead of full-resolution JPEG.
  final bool usePreviewFrame;

  /// Convert to map for platform channel
  Map<String, dynamic> toMap() {
    return {
      'boardImageBytes': boardImageBytes,
      'boardScreenX': boardScreenX,
      'boardScreenY': boardScreenY,
      'boardScreenWidth': boardScreenWidth,
      'boardScreenHeight': boardScreenHeight,
      'previewWidth': previewWidth,
      'previewHeight': previewHeight,
      'devicePixelRatio': devicePixelRatio,
      'targetWidth': targetWidth,
      'targetHeight': targetHeight,
      'deviceOrientationDegrees': deviceOrientationDegrees,
      'usePreviewFrame': usePreviewFrame,
    };
  }

  @override
  String toString() {
    return 'BoardOverlayData(screenPos: ($boardScreenX, $boardScreenY), '
        'screenSize: ${boardScreenWidth}x$boardScreenHeight, target: ${targetWidth}x$targetHeight)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BoardOverlayData &&
            runtimeType == other.runtimeType &&
            boardImageBytes == other.boardImageBytes &&
            boardScreenX == other.boardScreenX &&
            boardScreenY == other.boardScreenY &&
            boardScreenWidth == other.boardScreenWidth &&
            boardScreenHeight == other.boardScreenHeight &&
            previewWidth == other.previewWidth &&
            previewHeight == other.previewHeight &&
            devicePixelRatio == other.devicePixelRatio &&
            targetWidth == other.targetWidth &&
            targetHeight == other.targetHeight &&
            deviceOrientationDegrees == other.deviceOrientationDegrees &&
            usePreviewFrame == other.usePreviewFrame;
  }

  @override
  int get hashCode {
    return Object.hash(
      boardImageBytes,
      boardScreenX,
      boardScreenY,
      boardScreenWidth,
      boardScreenHeight,
      previewWidth,
      previewHeight,
      devicePixelRatio,
      targetWidth,
      targetHeight,
      deviceOrientationDegrees,
      usePreviewFrame,
    );
  }
}
