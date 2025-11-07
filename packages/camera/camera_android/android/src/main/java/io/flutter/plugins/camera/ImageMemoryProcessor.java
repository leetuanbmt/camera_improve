// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camera;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.media.Image;
import androidx.annotation.NonNull;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/** Processes a JPEG {@link Image} into memory and resizes it if needed. */
public class ImageMemoryProcessor implements Runnable {

  /** The JPEG image */
  private final Image image;

  /** Used to report the status of the processing action. */
  private final Callback callback;

  /** Whether to skip orientation correction for performance */
  private final boolean skipOrientationCorrection;

  /**
   * Creates an instance of the ImageMemoryProcessor runnable
   *
   * @param image - The image to process
   * @param callback - The callback that is run on completion, or when an error is encountered.
   */
  ImageMemoryProcessor(@NonNull Image image, @NonNull Callback callback) {
    this(image, callback, false);
  }

  /**
   * Creates an instance of the ImageMemoryProcessor runnable with option to skip orientation
   *
   * @param image - The image to process
   * @param callback - The callback that is run on completion, or when an error is encountered.
   * @param skipOrientationCorrection - If true, skip rotation for better performance
   */
  ImageMemoryProcessor(@NonNull Image image, @NonNull Callback callback, boolean skipOrientationCorrection) {
    this.image = image;
    this.callback = callback;
    this.skipOrientationCorrection = skipOrientationCorrection;
  }

  @Override
  public void run() {
    long startTime = System.currentTimeMillis();
    try {
      // Get JPEG bytes from image buffer
      long bufferStartTime = System.currentTimeMillis();
      ByteBuffer buffer = image.getPlanes()[0].getBuffer();
      byte[] jpegBytes = new byte[buffer.remaining()];
      buffer.get(jpegBytes);
      android.util.Log.d("ImageMemoryProcessor", "Buffer extraction took: " + (System.currentTimeMillis() - bufferStartTime) + "ms");

      // Read EXIF orientation to check if rotation is needed
      long exifStartTime = System.currentTimeMillis();
      int orientation = getExifOrientation(jpegBytes);
      android.util.Log.d("ImageMemoryProcessor", "EXIF reading took: " + (System.currentTimeMillis() - exifStartTime) + "ms");
      
      int imageWidth = image.getWidth();
      int imageHeight = image.getHeight();
      byte[] finalBytes = jpegBytes;

      // Only decode/rotate if orientation correction is needed and not skipped
      if (!skipOrientationCorrection 
          && orientation != ExifInterface.ORIENTATION_NORMAL
          && orientation != ExifInterface.ORIENTATION_UNDEFINED) {
        long rotateStartTime = System.currentTimeMillis();
        android.util.Log.d("ImageMemoryProcessor", "Orientation needs correction: " + orientation);
        
        // Decode JPEG to Bitmap with optimized settings
        long decodeStartTime = System.currentTimeMillis();
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inMutable = true; // Allow in-place operations
        options.inPreferredConfig = Bitmap.Config.ARGB_8888;
        options.inTempStorage = new byte[32 * 1024]; // 32KB temp buffer for faster decoding
        options.inScaled = false; // Don't scale during decode
        
        Bitmap bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.length, options);
        if (bitmap == null) {
          callback.onError("decodeError", "Failed to decode image");
          return;
        }
        android.util.Log.d("ImageMemoryProcessor", "Decode took: " + (System.currentTimeMillis() - decodeStartTime) + "ms, size: " + bitmap.getWidth() + "x" + bitmap.getHeight());

        // Rotate bitmap based on EXIF orientation
        long rotateOnlyStartTime = System.currentTimeMillis();
        Bitmap orientedBitmap = rotateBitmap(bitmap, orientation);
        if (orientedBitmap != bitmap) {
          bitmap.recycle();
        }
        android.util.Log.d("ImageMemoryProcessor", "Rotate only took: " + (System.currentTimeMillis() - rotateOnlyStartTime) + "ms");

        // Update dimensions after rotation
        imageWidth = orientedBitmap.getWidth();
        imageHeight = orientedBitmap.getHeight();

        // Re-compress to JPEG with optimized quality and buffer sizing
        long compressStartTime = System.currentTimeMillis();
        // Estimate capacity: rotated images typically compress similarly
        int estimatedCapacity = Math.max(jpegBytes.length, orientedBitmap.getWidth() * orientedBitmap.getHeight() / 10);
        ByteArrayOutputStream outputStream = new ByteArrayOutputStream(estimatedCapacity);
    boolean compressed = orientedBitmap.compress(Bitmap.CompressFormat.JPEG, 82, outputStream);
        finalBytes = outputStream.toByteArray();
        orientedBitmap.recycle();
        android.util.Log.d("ImageMemoryProcessor", "Compress took: " + (System.currentTimeMillis() - compressStartTime) + "ms, success: " + compressed + ", output size: " + finalBytes.length);
        
        android.util.Log.d("ImageMemoryProcessor", "Total rotation took: " + (System.currentTimeMillis() - rotateStartTime) + "ms");
      }

      // Return byte[] directly - much faster than converting to List<Long>
      android.util.Log.d("ImageMemoryProcessor", "Total processing took: " + (System.currentTimeMillis() - startTime) + "ms");
      callback.onComplete(finalBytes, imageWidth, imageHeight);
    } catch (Exception e) {
      callback.onError("processError", e.getMessage());
    } finally {
      image.close();
    }
  }

  private int getExifOrientation(byte[] jpegBytes) {
    try {
      ExifInterface exif = new ExifInterface(new ByteArrayInputStream(jpegBytes));
      int orientation = exif.getAttributeInt(
          ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
      return orientation;
    } catch (IOException e) {
      // If EXIF cannot be read, assume normal orientation
      return ExifInterface.ORIENTATION_NORMAL;
    }
  }

  private Bitmap rotateBitmap(Bitmap bitmap, int orientation) {
    if (orientation == ExifInterface.ORIENTATION_NORMAL
        || orientation == ExifInterface.ORIENTATION_UNDEFINED) {
      return bitmap;
    }

      Matrix matrix = new Matrix();
      switch (orientation) {
        case ExifInterface.ORIENTATION_ROTATE_90:
          matrix.postRotate(90);
          break;
        case ExifInterface.ORIENTATION_ROTATE_180:
          matrix.postRotate(180);
          break;
        case ExifInterface.ORIENTATION_ROTATE_270:
          matrix.postRotate(270);
          break;
        case ExifInterface.ORIENTATION_FLIP_HORIZONTAL:
          matrix.postScale(-1, 1);
          break;
        case ExifInterface.ORIENTATION_FLIP_VERTICAL:
          matrix.postScale(1, -1);
          break;
        case ExifInterface.ORIENTATION_TRANSPOSE:
          matrix.postRotate(90);
          matrix.postScale(-1, 1);
          break;
        case ExifInterface.ORIENTATION_TRANSVERSE:
          matrix.postRotate(270);
          matrix.postScale(-1, 1);
          break;
        default:
          return bitmap;
      }

      try {
        // Use filter=false for faster rotation without bilinear filtering
        Bitmap rotatedBitmap = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, false);
        return rotatedBitmap;
      } catch (OutOfMemoryError e) {
        android.util.Log.e("ImageMemoryProcessor", "Out of memory during rotation", e);
        return bitmap;
      }
  }

  /**
   * The interface for the callback that is passed to ImageMemoryProcessor, for detecting completion
   * or failure of the image processing task.
   */
  public interface Callback {
    /**
     * Called when the image has been processed successfully.
     *
     * @param bytes - The processed image bytes as byte array.
     * @param width - The width of the processed image in pixels.
     * @param height - The height of the processed image in pixels.
     */
    void onComplete(@NonNull byte[] bytes, int width, int height);

    /**
     * Called when an error is encountered while processing the image.
     *
     * @param errorCode - The error code.
     * @param errorMessage - The human readable error message.
     */
    void onError(@NonNull String errorCode, @NonNull String errorMessage);
  }
}

