// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@import AVFoundation;
@import Flutter;
@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// The completion handler block for capture to memory operations.
/// Can be called from either main queue or IO queue.
/// If success, `error` will be nil and `data`, `width`, `height` will be present. Otherwise, `error` will be present and other params will be nil/0.
/// @param data the JPEG image data captured directly to memory.
/// @param width the width of the captured image in pixels.
/// @param height the height of the captured image in pixels.
/// @param error photo capture error or processing error.
typedef void (^FLTCaptureToMemoryDelegateCompletionHandler)(NSData *_Nullable data,
                                                           int width,
                                                           int height,
                                                           NSError *_Nullable error);

/// Delegate object that handles photo capture results directly to memory.
@interface FLTCaptureToMemoryDelegate : NSObject <AVCapturePhotoCaptureDelegate>

/// Initialize a photo capture delegate for memory capture.
/// @param ioQueue the queue on which captured photos are processed.
/// @param completionHandler The completion handler block for capture to memory operations. Can
/// be called from either main queue or IO queue.
- (instancetype)initWithIOQueue:(dispatch_queue_t)ioQueue
               completionHandler:(FLTCaptureToMemoryDelegateCompletionHandler)completionHandler;
@end

NS_ASSUME_NONNULL_END

