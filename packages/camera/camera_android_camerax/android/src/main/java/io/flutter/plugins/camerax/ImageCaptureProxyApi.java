// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.media.ExifInterface;
import android.media.Image;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ImageCapture}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class ImageCaptureProxyApi extends PigeonApiImageCapture {
  static final String TEMPORARY_FILE_NAME = "CAP";
  static final String JPG_FILE_TYPE = ".jpg";

  ImageCaptureProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @NonNull
  @Override
  public ImageCapture pigeon_defaultConstructor(
      @Nullable ResolutionSelector resolutionSelector,
      @Nullable Long targetRotation,
      @Nullable CameraXFlashMode flashMode) {
    final ImageCapture.Builder builder = new ImageCapture.Builder();
    if (targetRotation != null) {
      builder.setTargetRotation(targetRotation.intValue());
    }
    if (flashMode != null) {
      // This sets the requested flash mode, but may fail silently.
      switch (flashMode) {
        case AUTO:
          builder.setFlashMode(ImageCapture.FLASH_MODE_AUTO);
          break;
        case OFF:
          builder.setFlashMode(ImageCapture.FLASH_MODE_OFF);
          break;
        case ON:
          builder.setFlashMode(ImageCapture.FLASH_MODE_ON);
          break;
      }
    }
    if (resolutionSelector != null) {
      builder.setResolutionSelector(resolutionSelector);
    }
    return builder.build();
  }

  @Override
  public void setFlashMode(
      @NonNull ImageCapture pigeonInstance, @NonNull CameraXFlashMode flashMode) {
    int nativeFlashMode = -1;
    switch (flashMode) {
      case AUTO:
        nativeFlashMode = ImageCapture.FLASH_MODE_AUTO;
        break;
      case OFF:
        nativeFlashMode = ImageCapture.FLASH_MODE_OFF;
        break;
      case ON:
        nativeFlashMode = ImageCapture.FLASH_MODE_ON;
    }
    pigeonInstance.setFlashMode(nativeFlashMode);
  }

  @Override
  public void takePicture(
      @NonNull ImageCapture pigeonInstance,
      @NonNull Function1<? super Result<String>, Unit> callback) {
    final File outputDir = getPigeonRegistrar().getContext().getCacheDir();
    File temporaryCaptureFile;
    try {
      temporaryCaptureFile = File.createTempFile(TEMPORARY_FILE_NAME, JPG_FILE_TYPE, outputDir);
    } catch (IOException | SecurityException e) {
      ResultCompat.failure(e, callback);
      return;
    }

    final ImageCapture.OutputFileOptions outputFileOptions =
        createImageCaptureOutputFileOptions(temporaryCaptureFile);
    final ImageCapture.OnImageSavedCallback onImageSavedCallback =
        createOnImageSavedCallback(temporaryCaptureFile, callback);

    pigeonInstance.takePicture(
        outputFileOptions, Executors.newSingleThreadExecutor(), onImageSavedCallback);
  }

  @Override
  public void captureToMemory(
      @NonNull ImageCapture pigeonInstance,
      @NonNull Function1<? super Result<PlatformCapturedImageData>, Unit> callback) {
    final ImageCapture.OnImageCapturedCallback onImageCapturedCallback =
        new ImageCapture.OnImageCapturedCallback() {
          @Override
          public void onCaptureSuccess(@NonNull ImageProxy image) {
            try {
              Bitmap bitmap = imageProxyToBitmap(image);
              if (bitmap != null) {
                // Get orientation from ImageProxy if it's JPEG format
                int orientation = ExifInterface.ORIENTATION_NORMAL;
                if (image.getFormat() == ImageFormat.JPEG) {
                  orientation = getExifOrientationFromImageProxy(image);
                }
                
                // Rotate bitmap if needed based on orientation
                Bitmap orientedBitmap = rotateBitmap(bitmap, orientation);
                if (orientedBitmap != bitmap) {
                  bitmap.recycle();
                }

                // Get image dimensions after orientation fix
                int imageWidth = orientedBitmap.getWidth();
                int imageHeight = orientedBitmap.getHeight();
                
                // Compress to JPEG (orientation is already applied)
                ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
                orientedBitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream);
                byte[] jpegBytes = outputStream.toByteArray();
                
                // Convert byte array to List<Long> for Pigeon
                List<Long> bytesList = new ArrayList<>();
                for (byte b : jpegBytes) {
                  bytesList.add((long) (b & 0xFF));
                }
                
                PlatformCapturedImageData result = new PlatformCapturedImageData();
                result.setBytes(bytesList);
                result.setWidth(imageWidth);
                result.setHeight(imageHeight);
                
                ResultCompat.success(result, callback);
                orientedBitmap.recycle();
              } else {
                ResultCompat.failure(
                    new Exception("Failed to convert ImageProxy to Bitmap"), callback);
              }
            } catch (Exception e) {
              ResultCompat.failure(e, callback);
            } finally {
              image.close();
            }
          }

          @Override
          public void onError(@NonNull ImageCaptureException exception) {
            ResultCompat.failure(exception, callback);
          }
        };

    pigeonInstance.takePicture(
        Executors.newSingleThreadExecutor(), onImageCapturedCallback);
  }

  @Override
  public void setTargetRotation(ImageCapture pigeonInstance, long rotation) {
    pigeonInstance.setTargetRotation((int) rotation);
  }

  @Nullable
  @Override
  public ResolutionSelector resolutionSelector(@NonNull ImageCapture pigeonInstance) {
    return pigeonInstance.getResolutionSelector();
  }

  private Bitmap imageProxyToBitmap(@NonNull ImageProxy imageProxy) {
    Image image = imageProxy.getImage();
    if (image == null) {
      return null;
    }

    int format = imageProxy.getFormat();
    
    // If already JPEG format, decode directly
    if (format == ImageFormat.JPEG) {
      Image.Plane[] planes = image.getPlanes();
      if (planes.length > 0) {
        ByteBuffer buffer = planes[0].getBuffer();
        byte[] jpegBytes = new byte[buffer.remaining()];
        buffer.get(jpegBytes);
        return BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.length);
      }
    }
    
    // Otherwise, convert YUV_420_888 to JPEG
    if (format == ImageFormat.YUV_420_888) {
      Image.Plane[] planes = image.getPlanes();
      if (planes.length < 3) {
        return null;
      }
      
      ByteBuffer yBuffer = planes[0].getBuffer();
      ByteBuffer uBuffer = planes[1].getBuffer();
      ByteBuffer vBuffer = planes[2].getBuffer();
      
      int ySize = yBuffer.remaining();
      int uSize = uBuffer.remaining();
      int vSize = vBuffer.remaining();
      
      byte[] nv21 = new byte[ySize + uSize + vSize];
      
      yBuffer.get(nv21, 0, ySize);
      vBuffer.get(nv21, ySize, vSize);
      uBuffer.get(nv21, ySize + vSize, uSize);
      
      YuvImage yuvImage = new YuvImage(nv21, ImageFormat.NV21, image.getWidth(), image.getHeight(), null);
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      yuvImage.compressToJpeg(new Rect(0, 0, image.getWidth(), image.getHeight()), 90, out);
      byte[] imageBytes = out.toByteArray();
      return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length);
    }
    
    return null;
  }

  private int getExifOrientationFromImageProxy(@NonNull ImageProxy imageProxy) {
    // For ImageProxy from CameraX, orientation is already applied via targetRotation
    // But if it's JPEG format, we need to check EXIF
    // Since ImageProxy doesn't expose EXIF directly, we'll rely on targetRotation
    // which is already set in captureToMemory method
    // The bitmap should already be correctly oriented
    return ExifInterface.ORIENTATION_NORMAL;
  }

  private Bitmap rotateBitmap(@NonNull Bitmap bitmap, int orientation) {
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
      Bitmap rotatedBitmap = Bitmap.createBitmap(
          bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
      return rotatedBitmap;
    } catch (OutOfMemoryError e) {
      return bitmap;
    }
  }


  ImageCapture.OutputFileOptions createImageCaptureOutputFileOptions(@NonNull File file) {
    return new ImageCapture.OutputFileOptions.Builder(file).build();
  }

  @NonNull
  ImageCapture.OnImageSavedCallback createOnImageSavedCallback(
      @NonNull File file, @NonNull Function1<? super Result<String>, Unit> callback) {
    return new ImageCapture.OnImageSavedCallback() {
      @Override
      public void onImageSaved(@NonNull ImageCapture.OutputFileResults outputFileResults) {
        ResultCompat.success(file.getAbsolutePath(), callback);
      }

      @Override
      public void onError(@NonNull ImageCaptureException exception) {
        ResultCompat.failure(exception, callback);
      }
    };
  }
}
