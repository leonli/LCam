//
//  ViewController.m
//  LCam
//
//  Created by Leon Li on 4/4/14.
//  Copyright (c) 2014 ooo. All rights reserved.
//

#import "LCamViewController.h"
#import "LCamPreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>


static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;


@interface LCamViewController ()

@property (weak, nonatomic) IBOutlet LCamPreviewView *previewView;
@property (weak, nonatomic) IBOutlet UIImageView *imageView;
@property (weak, nonatomic) IBOutlet UIButton *takePhotoButton;
@property (weak, nonatomic) IBOutlet UIButton *switchCamButton;
@property (weak, nonatomic) IBOutlet UIButton *flashButton;
@property (strong, nonatomic) IBOutlet UIToolbar *bottomBar;


// Session management.
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue.
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;



// Utilities.
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic) id runtimeErrorHandlingObserver;

@property (nonatomic) AVCaptureFlashMode camFlashMode;

//
@property (nonatomic, strong, readonly) UITapGestureRecognizer *singleTap;
@property (nonatomic, strong) CALayer *focusBox;

@end

@implementation LCamViewController
@synthesize focusBox = _focusBox;

-(BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad
{
    [super viewDidLoad];
	
    // Create the AVCaptureSession
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	[self setSession:session];
    
    // Setup the preview view
	[[self previewView] setSession:session];
    
    // Check for device authorization
	[self checkDeviceAuthorizationStatus];
    
    // Start session queue
    dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
	[self setSessionQueue:sessionQueue];
    
    
    dispatch_async(sessionQueue, ^{
        [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
        
        NSError *error = nil;
        
        AVCaptureDevice *videoDevice = [LCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
        
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        
        if (error)
		{
			NSLog(@"%@", error);
		}
        
        if ([session canAddInput:videoDeviceInput]) {
            [session addInput:videoDeviceInput];
            
            [self setVideoDeviceInput:videoDeviceInput];
            
            
            dispatch_async(dispatch_get_main_queue(), ^{
				// Why are we dispatching this to the main queue?
				// Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                
				[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
			});
        }
        
        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ([session canAddOutput:stillImageOutput])
		{
			[stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
			[session addOutput:stillImageOutput];
			[self setStillImageOutput:stillImageOutput];
		}
        
    });
    
    //default flash mode.
    _camFlashMode = AVCaptureFlashModeAuto;
    [self createGesture];
    
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, self.view.frame.size.height - 90, 320, 90)];
    toolbar.barTintColor = [UIColor colorWithRed:100/255.0f green:168/255.0f blue:192/255.0f alpha:1];
    [self.view insertSubview:toolbar aboveSubview:self.previewView];
}

- (void)viewWillAppear:(BOOL)animated {
    
    [super viewWillAppear:animated];
    
    dispatch_async([self sessionQueue], ^{
        
        [self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
        
        [self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(subjectAreaDidChange:)
                                                     name:AVCaptureDeviceSubjectAreaDidChangeNotification
                                                   object:[[self videoDeviceInput] device]];
        
        __weak LCamViewController *weakSelf = self;
		[self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:[self session] queue:nil usingBlock:^(NSNotification *note) {
			LCamViewController *strongSelf = weakSelf;
			dispatch_async([strongSelf sessionQueue], ^{
				// Manually restarting the session since it must have been stopped due to an error.
				[[strongSelf session] startRunning];
			});
		}]];
        
        
        [[self session] startRunning];
    });
    
    // add by Damon
    if ( !_focusBox ) {
        _focusBox = [[CALayer alloc] init];
        [_focusBox setCornerRadius:45.0f];
        [_focusBox setBounds:CGRectMake(0.0f, 0.0f, 90, 90)];
        [_focusBox setBorderWidth:5.f];
        [_focusBox setBorderColor:[[UIColor colorWithRed:100/255.0f green:168/255.0f blue:192/255.0f alpha:1] CGColor]];
        [_focusBox setOpacity:0];
        [self.previewView.layer addSublayer:_focusBox];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(detectOrientation) name:@"UIDeviceOrientationDidChangeNotification" object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    
    dispatch_async([self sessionQueue], ^{
		[[self session] stopRunning];
		
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		[[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
		
		[self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
		[self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
	});
    
}

- (IBAction)switchCam:(id)sender {
    
    [self.takePhotoButton setEnabled:NO];
    [self.flashButton setEnabled:NO];
    [self.switchCamButton setEnabled:NO];
    
    
    dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
		AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition = [currentVideoDevice position];
		
		switch (currentPosition)
		{
			case AVCaptureDevicePositionUnspecified:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
			case AVCaptureDevicePositionBack:
				preferredPosition = AVCaptureDevicePositionFront;
				break;
			case AVCaptureDevicePositionFront:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
		}
        
        //run animation
        [self runSwitchCamAnimationWithPosion:currentPosition];
		
		AVCaptureDevice *videoDevice = [LCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
		
		[[self session] beginConfiguration];
		
		[[self session] removeInput:[self videoDeviceInput]];
		if ([[self session] canAddInput:videoDeviceInput])
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
			
			[LCamViewController setFlashMode:self.camFlashMode forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
			
			[[self session] addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
		}
		else
		{
			[[self session] addInput:[self videoDeviceInput]];
		}
		
		[[self session] commitConfiguration];
		
		dispatch_async(dispatch_get_main_queue(), ^{
            
            
            [self.takePhotoButton setEnabled:YES];
            [self.flashButton setEnabled:YES];
            [self.switchCamButton setEnabled:YES];
			
		});
	});
    
}

- (void) runSwitchCamAnimationWithPosion: (AVCaptureDevicePosition) position {
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGContextRef context = UIGraphicsGetCurrentContext();
        [LCamPreviewView beginAnimations:nil context:context];
        [LCamPreviewView setAnimationCurve:UIViewAnimationCurveEaseInOut];
        [[[self previewView] layer] setOpacity:0.2];
        [LCamPreviewView setAnimationDuration:0.5];
        switch (position) {
            case AVCaptureDevicePositionBack:
                [LCamPreviewView setAnimationTransition:UIViewAnimationTransitionFlipFromLeft forView:self.previewView cache:YES];
                break;
            case AVCaptureDevicePositionFront:
                [LCamPreviewView setAnimationTransition:UIViewAnimationTransitionFlipFromRight forView:self.previewView cache:YES];
                break;
                
            default:
                break;
        }
        [[[self previewView] layer] setOpacity:1.0];
        [UIView setAnimationDelegate:self];
        [LCamPreviewView commitAnimations];
    });
}


- (IBAction)changeFlash:(id)sender {
    
    
    switch (self.camFlashMode) {
        case AVCaptureFlashModeAuto:
            self.camFlashMode = AVCaptureFlashModeOff;
            [self.flashButton setTitle:@"关闭" forState:UIControlStateNormal];
            break;
            
        case AVCaptureFlashModeOff:
            self.camFlashMode = AVCaptureFlashModeOn;
            [self.flashButton setTitle:@"打开" forState:UIControlStateNormal];
            break;
            
        case AVCaptureFlashModeOn:
            self.camFlashMode = AVCaptureFlashModeAuto;
            [self.flashButton setTitle:@"自动" forState:UIControlStateNormal];
            break;
            
        default:
            break;
    }
    
    
}


- (IBAction)stillCaptureImage:(id)sender {
    
    // Update the orientation on the still image output video connection before capturing.
    [[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
    
    // Flash set to Auto for Still Capture
    [LCamViewController setFlashMode:self.camFlashMode forDevice:[[self videoDeviceInput] device]];
    
    // Capture a still image.
    [[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        
        if (imageDataSampleBuffer)
        {
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
            UIImage *image = [[UIImage alloc] initWithData:imageData];
            if (self.videoDeviceInput.device.position == AVCaptureDevicePositionFront) {
                image = [[UIImage alloc] initWithCGImage:image.CGImage scale:2.0 orientation:UIImageOrientationLeftMirrored];
            }
            
            self.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.imageView.clipsToBounds = YES;
            [self.imageView setImage:image];
            
        }
    }];
    
}


+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
	AVCaptureDevice *captureDevice = [devices firstObject];
	
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == position)
		{
			captureDevice = device;
			break;
		}
	}
	
	return captureDevice;
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
	if ([device hasFlash] && [device isFlashModeSupported:flashMode])
	{
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			[device setFlashMode:flashMode];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == CapturingStillImageContext)
	{
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
		
		if (isCapturingStillImage)
		{
			[self runStillImageCaptureAnimation];
		}
	}
    else if(context == SessionRunningAndDeviceAuthorizedContext) {
        BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isRunning)
			{
                [[self takePhotoButton] setEnabled:YES];
            }
            else
            {
                [[self takePhotoButton] setEnabled:NO];
            }
        });
    }
    
}

- (void)runStillImageCaptureAnimation
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[[self previewView] layer] setOpacity:0.0];
		[UIView animateWithDuration:.25 animations:^{
			[[[self previewView] layer] setOpacity:1.0];
		}];
	});
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
	CGPoint devicePoint = CGPointMake(.5, .5);
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
    
    BOOL adjusting = [self.videoDeviceInput.device isAdjustingFocus];
    if (!adjusting) {
        NSLog(@"I have focus");
    } else {
        NSLog(@"NOT");
    }
}

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *device = [[self videoDeviceInput] device];
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:focusMode])
			{
				[device setFocusMode:focusMode];
				[device setFocusPointOfInterest:point];
			}
			if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:exposureMode])
			{
				[device setExposureMode:exposureMode];
				[device setExposurePointOfInterest:point];
			}
			[device setSubjectAreaChangeMonitoringEnabled:monitorSubjectAreaChange];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	});
}

- (void)createGesture
{
    _singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector( tapToFocus: )];
    [_singleTap setDelaysTouchesEnded:NO];
    [_singleTap setNumberOfTapsRequired:1];
    [_singleTap setNumberOfTouchesRequired:1];
    [self.previewView addGestureRecognizer:_singleTap];
}

- (void)tapToFocus:(UIGestureRecognizer *)recognizer
{
    CGPoint tempPoint = (CGPoint)[recognizer locationInView:self.previewView];
    NSLog(@"tap point %@", NSStringFromCGPoint(tempPoint));
    if ( [self respondsToSelector:@selector(cameraView:focusAtPoint:)] && CGRectContainsPoint(self.previewView.frame, tempPoint) )
        [self cameraView:self.previewView focusAtPoint:(CGPoint){ tempPoint.x, tempPoint.y - CGRectGetMinY(self.previewView.frame)}];
}

- (void)cameraView:(UIView *)camera focusAtPoint:(CGPoint)point
{
    if ( self.videoDeviceInput.device.isFocusPointOfInterestSupported ) {
        CGPoint focusPoint = [self convertToPointOfInterestFrom:self.previewView.layer.frame coordinates:point layer:(AVCaptureVideoPreviewLayer *)(self.previewView.layer)];
        NSLog(@"focus point %@", NSStringFromCGPoint(focusPoint));
        [self focusAtPoint:focusPoint];
        [self drawFocusBoxAtPointOfInterest:point andRemove:YES];
    }
}

- (CGPoint)convertToPointOfInterestFrom:(CGRect)frame coordinates:(CGPoint)viewCoordinates layer:(AVCaptureVideoPreviewLayer *)layer
{
    CGPoint pointOfInterest = (CGPoint){ 0.5f, 0.5f };
    CGSize frameSize = frame.size;
    
    AVCaptureVideoPreviewLayer *videoPreviewLayer = layer;
    
    if ( [[videoPreviewLayer videoGravity] isEqualToString:AVLayerVideoGravityResize] )
        pointOfInterest = (CGPoint){ viewCoordinates.y / frameSize.height, 1.0f - (viewCoordinates.x / frameSize.width) };
    else {
        CGRect cleanAperture;
        for (AVCaptureInputPort *port in self.videoDeviceInput.ports) {
            if ([port mediaType] == AVMediaTypeVideo) {
                cleanAperture = CMVideoFormatDescriptionGetCleanAperture([port formatDescription], YES);
                CGSize apertureSize = cleanAperture.size;
                CGPoint point = viewCoordinates;
                
                CGFloat apertureRatio = apertureSize.height / apertureSize.width;
                CGFloat viewRatio = frameSize.width / frameSize.height;
                CGFloat xc = 0.5f;
                CGFloat yc = 0.5f;
                
                if ( [[videoPreviewLayer videoGravity] isEqualToString:AVLayerVideoGravityResizeAspect] ) {
                    if (viewRatio > apertureRatio) {
                        CGFloat y2 = frameSize.height;
                        CGFloat x2 = frameSize.height * apertureRatio;
                        CGFloat x1 = frameSize.width;
                        CGFloat blackBar = (x1 - x2) / 2;
                        if (point.x >= blackBar && point.x <= blackBar + x2) {
                            xc = point.y / y2;
                            yc = 1.0f - ((point.x - blackBar) / x2);
                        }
                    } else {
                        CGFloat y2 = frameSize.width / apertureRatio;
                        CGFloat y1 = frameSize.height;
                        CGFloat x2 = frameSize.width;
                        CGFloat blackBar = (y1 - y2) / 2;
                        if (point.y >= blackBar && point.y <= blackBar + y2) {
                            xc = ((point.y - blackBar) / y2);
                            yc = 1.0f - (point.x / x2);
                        }
                    }
                } else if ([[videoPreviewLayer videoGravity] isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
                    if (viewRatio > apertureRatio) {
                        CGFloat y2 = apertureSize.width * (frameSize.width / apertureSize.height);
                        xc = (point.y + ((y2 - frameSize.height) / 2.0f)) / y2;
                        yc = (frameSize.width - point.x) / frameSize.width;
                    } else {
                        CGFloat x2 = apertureSize.height * (frameSize.height / apertureSize.width);
                        yc = 1.0f - ((point.x + ((x2 - frameSize.width) / 2)) / x2);
                        xc = point.y / frameSize.height;
                    }
                }
                
                pointOfInterest = (CGPoint){ xc, yc };
                break;
            }
        }
    }
    
    return pointOfInterest;
}

- (void)focusAtPoint:(CGPoint)point
{
    AVCaptureDevice *device = self.videoDeviceInput.device;
    if ( device.isFocusPointOfInterestSupported && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus] ) {
        NSError *error;
        if ( [device lockForConfiguration:&error] ) {
            device.focusPointOfInterest = point;
            device.focusMode = AVCaptureFocusModeAutoFocus;
            device.exposurePointOfInterest = point;
            device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            [device unlockForConfiguration];
        } else {
            NSLog(@"focus error %@", error);
        }
    }
}

- (void)drawFocusBoxAtPointOfInterest:(CGPoint)point andRemove:(BOOL)remove
{
    if ( remove )
        [_focusBox removeAllAnimations];
    
    if ( [_focusBox animationForKey:@"transform.scale"] == nil && [_focusBox animationForKey:@"opacity"] == nil ) {
        [CATransaction begin];
        [CATransaction setValue: (id) kCFBooleanTrue forKey: kCATransactionDisableActions];
        [_focusBox setPosition:point];
        [CATransaction commit];
        
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        [scale setFromValue:[NSNumber numberWithFloat:1]];
        [scale setToValue:[NSNumber numberWithFloat:0.5]];
        [scale setDuration:0.8];
        [scale setRemovedOnCompletion:YES];
        
        CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
        [opacity setFromValue:[NSNumber numberWithFloat:1]];
        [opacity setToValue:[NSNumber numberWithFloat:0]];
        [opacity setDuration:0.8];
        [opacity setRemovedOnCompletion:YES];
        
        [_focusBox addAnimation:scale forKey:@"transform.scale"];
        [_focusBox addAnimation:opacity forKey:@"opacity"];
    }
}

- (void)checkDeviceAuthorizationStatus
{
	NSString *mediaType = AVMediaTypeVideo;
	
    
	[AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
		if (granted)
		{
			//Granted access to mediaType
			[self setDeviceAuthorized:YES];
		}
		else
		{
			//Not granted access to mediaType
			dispatch_async(dispatch_get_main_queue(), ^{
				[[[UIAlertView alloc] initWithTitle:@"温馨提示:"
											message:@"程序无法使用相机功能，请在设置中修改允许程序使用相机功能."
										   delegate:self
								  cancelButtonTitle:@"好"
								  otherButtonTitles:nil] show];
				[self setDeviceAuthorized:NO];
			});
		}
	}];
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)detectOrientation
{
    if ([[UIDevice currentDevice] orientation] == UIDeviceOrientationLandscapeLeft) {
        [UIView animateWithDuration:0.25 delay:0.4 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            CGAffineTransform rotate = CGAffineTransformMakeRotation(M_PI/2);
            [self.flashButton setTransform:rotate];
            [self.switchCamButton setTransform:rotate];
        } completion:nil];
    } else if ([[UIDevice currentDevice] orientation] == UIDeviceOrientationLandscapeRight) {
        [UIView animateWithDuration:0.25 delay:0.4 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            CGAffineTransform rotate = CGAffineTransformMakeRotation(1.5*M_PI);
            [self.flashButton setTransform:rotate];
            [self.switchCamButton setTransform:rotate];
        } completion:nil];
    } else if ([[UIDevice currentDevice] orientation] == UIDeviceOrientationPortrait) {
        [UIView animateWithDuration:0.25 delay:0.4 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            CGAffineTransform rotate = CGAffineTransformMakeRotation(0);
            [self.flashButton setTransform:rotate];
            [self.switchCamButton setTransform:rotate];
        } completion:nil];
    } else {
        
    }
}

@end
