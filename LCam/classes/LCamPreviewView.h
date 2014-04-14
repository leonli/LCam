//
//  LCamPreviewView.h
//  LCam
//
//  Created by Leon Li on 4/4/14.
//  Copyright (c) 2014 ooo. All rights reserved.
//

#import <UIKit/UIKit.h>

@class AVCaptureSession;

@interface LCamPreviewView : UIView

@property (nonatomic) AVCaptureSession *session;

@end
