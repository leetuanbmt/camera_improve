// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';

/// Data returned from [CameraPlatform.captureToMemory].
///
/// Contains the JPEG image bytes and the dimensions of the captured image.
class CapturedImageData {
  /// Creates a new [CapturedImageData] instance.
  const CapturedImageData({
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// The JPEG image data as bytes.
  final Uint8List bytes;

  /// The width of the captured image in pixels.
  final int width;

  /// The height of the captured image in pixels.
  final int height;
}
