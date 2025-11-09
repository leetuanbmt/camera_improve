// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/camera_avfoundation/FLTCaptureToMemoryDelegate.h"
@import UIKit;
@import ImageIO;
@import CoreGraphics;

@interface FLTCaptureToMemoryDelegate ()
/// The queue on which captured photos are processed.
@property(readonly, nonatomic) dispatch_queue_t ioQueue;
/// The completion handler block for capture to memory operations.
@property(readonly, nonatomic) FLTCaptureToMemoryDelegateCompletionHandler completionHandler;
@end

@implementation FLTCaptureToMemoryDelegate

- (instancetype)initWithIOQueue:(dispatch_queue_t)ioQueue
               completionHandler:(FLTCaptureToMemoryDelegateCompletionHandler)completionHandler {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _ioQueue = ioQueue;
  _completionHandler = completionHandler;
  return self;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
  if (error) {
    self.completionHandler(nil, 0, 0, error);
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(self.ioQueue, ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;

    // Get image data from the photo (already JPEG format)
    NSData *jpegData = [photo fileDataRepresentation];
    if (!jpegData) {
      NSError *dataError = [NSError errorWithDomain:@"FLTCaptureToMemory"
                                               code:-1
                                           userInfo:@{NSLocalizedDescriptionKey : @"Failed to get image data from photo"}];
      strongSelf.completionHandler(nil, 0, 0, dataError);
      return;
    }

    // Fast path: Read EXIF metadata to check orientation and dimensions without decoding image
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!imageSource) {
      NSError *sourceError = [NSError errorWithDomain:@"FLTCaptureToMemory"
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey : @"Failed to create image source"}];
      strongSelf.completionHandler(nil, 0, 0, sourceError);
      return;
    }

    NSDictionary *options = @{(NSString *)kCGImageSourceShouldCache : @NO};
    CFDictionaryRef imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
    
    int imageWidth = 0;
    int imageHeight = 0;
    BOOL needsOrientationFix = NO;
    NSData *finalJpegData = jpegData;
    
    if (imageProperties) {
      // Read dimensions
      NSNumber *width = (NSNumber *)CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelWidth);
      NSNumber *height = (NSNumber *)CFDictionaryGetValue(imageProperties, kCGImagePropertyPixelHeight);
      if (width && height) {
        imageWidth = [width intValue];
        imageHeight = [height intValue];
      }
      
      // Check EXIF orientation - try multiple sources
      NSNumber *orientationValue = nil;
      
      // First try direct orientation property (most common)
      orientationValue = (NSNumber *)CFDictionaryGetValue(imageProperties, kCGImagePropertyOrientation);
      
      // If not found, try EXIF dictionary
      if (!orientationValue) {
        CFDictionaryRef exifDict = (CFDictionaryRef)CFDictionaryGetValue(imageProperties, kCGImagePropertyExifDictionary);
        if (exifDict) {
          orientationValue = (NSNumber *)CFDictionaryGetValue(exifDict, kCGImagePropertyOrientation);
        }
      }
      
      // If still not found, try TIFF dictionary
      if (!orientationValue) {
        CFDictionaryRef tiffDict = (CFDictionaryRef)CFDictionaryGetValue(imageProperties, kCGImagePropertyTIFFDictionary);
        if (tiffDict) {
          orientationValue = (NSNumber *)CFDictionaryGetValue(tiffDict, kCGImagePropertyOrientation);
        }
      }
      
      if (orientationValue) {
        int exifOrientation = [orientationValue intValue];
        // EXIF orientation 1 is normal (Up), others need fixing
        needsOrientationFix = (exifOrientation != 1);
      }
      CFRelease(imageProperties);
    }
    CFRelease(imageSource);
    
    // Only decode/fix/re-encode if orientation needs fixing (slower path)
    if (needsOrientationFix) {
      UIImage *image = [UIImage imageWithData:jpegData];
      if (!image) {
        NSError *imageError = [NSError errorWithDomain:@"FLTCaptureToMemory"
                                                  code:-2
                                              userInfo:@{NSLocalizedDescriptionKey : @"Failed to create image from data"}];
        strongSelf.completionHandler(nil, 0, 0, imageError);
        return;
      }

      // Fix orientation before processing
      UIImage *orientedImage = [self fixImageOrientation:image];
      
      // Get image size after orientation fix
      imageWidth = (int)orientedImage.size.width;
      imageHeight = (int)orientedImage.size.height;

      // Re-encode to JPEG with compression (quality 0.9 for good quality)
      finalJpegData = UIImageJPEGRepresentation(orientedImage, 0.9);
      if (!finalJpegData) {
        NSError *jpegError = [NSError errorWithDomain:@"FLTCaptureToMemory"
                                                  code:-4
                                              userInfo:@{NSLocalizedDescriptionKey : @"Failed to convert image to JPEG"}];
        strongSelf.completionHandler(nil, 0, 0, jpegError);
        return;
      }
    } else {
      // Fast path: Use JPEG data directly
      // Dimensions already read from EXIF above
      // Fallback: If dimensions weren't read, decode just to get size (minimal overhead)
      if (imageWidth == 0 || imageHeight == 0) {
        UIImage *image = [UIImage imageWithData:jpegData];
        if (image) {
          imageWidth = (int)image.size.width;
          imageHeight = (int)image.size.height;
        }
      }
    }

    strongSelf.completionHandler(finalJpegData, imageWidth, imageHeight, nil);
  });
}

- (UIImage *)fixImageOrientation:(UIImage *)image {
  // If image orientation is already up, no fix needed
  if (image.imageOrientation == UIImageOrientationUp) {
    return image;
  }

  // Create a graphics context to draw the image with correct orientation
  // Use image.scale to maintain quality
  UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
  [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
  UIImage *fixedImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  
  return fixedImage ?: image;
}


@end

