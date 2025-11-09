// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camera;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import androidx.annotation.NonNull;

/** Fast bitmap rotation utility optimized for performance. */
public class ImageRotator {

  /**
   * Rotates a bitmap by the specified angle using optimized canvas operations.
   * This is faster than Matrix.createBitmap for 90-degree rotations.
   *
   * @param source The source bitmap to rotate
   * @param angle The rotation angle (90, 180, or 270)
   * @return The rotated bitmap
   */
  public static Bitmap rotateFast(@NonNull Bitmap source, int angle) {
    if (angle == 0) {
      return source;
    }

    final int width = source.getWidth();
    final int height = source.getHeight();
    
    // For 90 and 270 degree rotations, swap dimensions
    final boolean swapDimensions = (angle == 90 || angle == 270);
    final int newWidth = swapDimensions ? height : width;
    final int newHeight = swapDimensions ? width : height;

    // Create output bitmap with RGB_565 for faster processing
    // Use ARGB_8888 config matching source for quality
    Bitmap rotated = Bitmap.createBitmap(newWidth, newHeight, source.getConfig());
    
    Canvas canvas = new Canvas(rotated);
    Matrix matrix = new Matrix();
    
    // Set rotation around center
    matrix.setRotate(angle, width / 2f, height / 2f);
    
    // Translate to center the rotated image
    if (angle == 90) {
      matrix.postTranslate(height / 2f - width / 2f, width / 2f - height / 2f);
    } else if (angle == 270) {
      matrix.postTranslate(height / 2f - width / 2f, width / 2f - height / 2f);
    }
    
    // Use bilinear filtering for better quality
    Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    canvas.drawBitmap(source, matrix, paint);
    
    return rotated;
  }

  /**
   * Rotates bitmap in-place by 180 degrees using pixel manipulation.
   * This is the fastest method for 180-degree rotation.
   *
   * @param source The bitmap to rotate
   * @return The rotated bitmap (may be the same instance)
   */
  public static Bitmap rotate180Fast(@NonNull Bitmap source) {
    final int width = source.getWidth();
    final int height = source.getHeight();
    
    // Get pixels
    int[] pixels = new int[width * height];
    source.getPixels(pixels, 0, width, 0, 0, width, height);
    
    // Reverse pixel array in-place
    int len = pixels.length;
    for (int i = 0; i < len / 2; i++) {
      int temp = pixels[i];
      pixels[i] = pixels[len - i - 1];
      pixels[len - i - 1] = temp;
    }
    
    // Set pixels back
    source.setPixels(pixels, 0, width, 0, 0, width, height);
    return source;
  }
}
