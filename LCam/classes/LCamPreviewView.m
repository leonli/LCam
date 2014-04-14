//
//  LCamPreviewView.m
//  LCam
//
//  Created by Leon Li on 4/4/14.
//  Copyright (c) 2014 ooo. All rights reserved.
//

#import "LCamPreviewView.h"
#import <AVFoundation/AVFoundation.h>

@implementation LCamPreviewView

+ (Class)layerClass
{
	return [AVCaptureVideoPreviewLayer class];
}

- (AVCaptureSession *)session
{
	return [(AVCaptureVideoPreviewLayer *)[self layer] session];
}


- (void)setSession:(AVCaptureSession *)session
{
	[(AVCaptureVideoPreviewLayer *)[self layer] setSession:session];
}


@end
