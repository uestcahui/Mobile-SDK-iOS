//
//  VideoPreviewerSDKAdapter.m
//  VideoPreviewer
//
//  Copyright © 2016 DJI. All rights reserved.
//

#import "VideoPreviewerSDKAdapter.h"
#import <VideoPreviewer/VideoPreviewer.h>

#import <DJISDK/DJISDK.h>

#define weakSelf(__TARGET__) __weak typeof(self) __TARGET__=self
#define weakReturn(__TARGET__) if(__TARGET__==nil)return;

const static NSTimeInterval REFRESH_INTERVAL = 1.0;

/**
 *  Information needed by VideoPreviewer includes: 
 *  1. Product names.
 *  2. (Osmo only) Is digital zoom supported. 
 *  3. (Marvik only) Is in portrait mode.
 *  4. Photo Ratio.
 *  5. Camera Mode. 
 */
@interface VideoPreviewerSDKAdapter ()

@property (nonatomic) NSTimer *refreshTimer;

@property (nonatomic) NSString *productName;
@property (nonatomic) NSString *cameraName;
@property (nonatomic) BOOL isAircraft;
@property (nonatomic) DJICameraMode cameraMode;
@property (nonatomic) DJICameraPhotoAspectRatio photoRatio;

@end


@implementation VideoPreviewerSDKAdapter

+(instancetype)adapterWithVideoPreviewer:(VideoPreviewer *)videoPreviewer {
    VideoPreviewerSDKAdapter *adapter = [VideoPreviewerSDKAdapter new];
    adapter.videoPreviewer = videoPreviewer;

    return adapter;
}

-(instancetype)init {
    if (self = [super init]) {
        _cameraMode = DJICameraModeUnknown;
        _photoRatio = DJICameraPhotoAspectRatioUnknown;

        if (g_loadPrebuildIframeOverrideFunc == NULL) {
            g_loadPrebuildIframeOverrideFunc = loadPrebuildIframePrivate;
        }
    }
    return self;
}

-(void)start {
    [self startRefreshTimer];
}

-(void)stop {
    [self stopRefreshTimer];
}

-(void)startRefreshTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.refreshTimer) {
            self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:REFRESH_INTERVAL
                                                                 target:self
                                                               selector:@selector(updateInformation)
                                                               userInfo:nil
                                                                repeats:YES];
        }
    });
}

-(void)stopRefreshTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.refreshTimer) {
            [self.refreshTimer invalidate];
            self.refreshTimer = nil;
        }
    });
}

-(void) updateInformation {
    if (!self.videoPreviewer) {
        return;
    }

    // 1. check if the product is still connecting
    DJIBaseProduct *product = [DJISDKManager product];
    if (product == nil || !product.isConnected) {
        return;
    }

    // 2. Get product names and camera names
    self.productName = product.model;
    if (!self.productName) {
        [self setDefaultConfiguration];
        return;
    }
    self.isAircraft = [product isKindOfClass:[DJIAircraft class]];
    self.cameraName = [[self class] camera].displayName;

    // Set decode type
    [self updateEncodeType];

    // 3. Get camera work mode
    DJICamera *camera = [[self class] camera];
    if (camera) {
        weakSelf(target);
        [camera getCameraModeWithCompletion:^(DJICameraMode mode, NSError * _Nullable error) {
            weakReturn(target);
            if (error == nil) {
                target.cameraMode = mode;
                [target updateContentRect];
            }
        }];
        [camera getPhotoRatioWithCompletion:^(DJICameraPhotoAspectRatio ratio, NSError * _Nullable error) {
            weakReturn(target);
            if (error == nil) {
                target.photoRatio = ratio;
                [target updateContentRect];
            }
        }];
        [self updateContentRect];
    }

    if ([camera.displayName isEqual:DJICameraDisplayNameMavicProCamera]) {
        [camera getOrientationWithCompletion:^(DJICameraOrientation orientation, NSError * _Nullable error) {
            if (error == nil) {
                if (orientation == DJICameraOrientationLandscape) {
                    [VideoPreviewer instance].rotation = VideoStreamRotationDefault;
                }
                else {
                    [VideoPreviewer instance].rotation = VideoStreamRotationCW90;
                }
            }
        }];
    }
}

-(void)setDefaultConfiguration {
    [self.videoPreviewer setEncoderType:H264EncoderType_unknown];
    self.videoPreviewer.rotation = VideoStreamRotationDefault;
    self.videoPreviewer.contentClipRect = CGRectMake(0, 0, 1, 1);
}

-(void)updateEncodeType {
    // Check if Lightbridge 2
    if ([[self class] isUsingLightbridge2WithProductName:self.productName
                                              isAircraft:self.isAircraft
                                              cameraName:self.cameraName]) {
        [self.videoPreviewer setEncoderType:H264EncoderType_LightBridge2];
        return;
    }

    H264EncoderType encodeType = [[self class] getDataSourceWithCameraName:self.cameraName
                                                             andIsAircraft:self.isAircraft];
    if (encodeType == H264EncoderType_unknown) {
        [self setDefaultConfiguration];
        return;
    }

    [self.videoPreviewer setEncoderType:encodeType];
}

-(void)updateContentRect {
    if ([self.cameraName isEqual:DJICameraDisplayNameXT]) {
        [self updateContentRectForXT];
        return;
    }

    if (self.cameraMode == DJICameraModeShootPhoto) {
        [self updateContentRectInPhotoMode];
    }
    else {
        [self setDefaultContentRect];
    }
}

-(void)updateContentRectForXT {
    // Workaround: when M100 is setup with XT, there are 8 useless pixels on
    // the left and right hand sides.
    if ([self. productName isEqual:DJIAircraftModelNameMatrice100]) {
        self.videoPreviewer.contentClipRect = CGRectMake(0.010869565217391, 0
                                                         , 0.978260869565217, 1);
    }
}

-(void)updateContentRectInPhotoMode {
    CGRect area = CGRectMake(0, 0, 1, 1);
    BOOL needFitToRate = NO;

    if ([self.cameraName isEqualToString:DJICameraDisplayNameX3] ||
        [self.cameraName isEqualToString:DJICameraDisplayNameX5] ||
        [self.cameraName isEqualToString:DJICameraDisplayNameX5R] ||
        [self.cameraName isEqualToString:DJICameraDisplayNamePhantom3ProfessionalCamera] ||
        [self.cameraName isEqualToString:DJICameraDisplayNamePhantom4Camera] ||
        [self.cameraName isEqualToString:DJICameraDisplayNameMavicProCamera]) {
        needFitToRate = YES;
    }

    if (needFitToRate && self.photoRatio != DJICameraPhotoAspectRatioUnknown) {
        CGRect streamRect = CGRectMake(0, 0, 16, 9);
        CGRect destRect = streamRect;
        CGSize rateSize = CGSizeMake(16, 9);

        switch (self.photoRatio) {
            case DJICameraPhotoAspectRatio3_2:
                rateSize = CGSizeMake(3, 2);
                break;
            case DJICameraPhotoAspectRatio4_3:
                rateSize = CGSizeMake(4, 3);
                break;
            default:
                break;
        }

        destRect = [DJIVideoPresentViewAdjustHelper aspectFitWithFrame:streamRect size:rateSize];
        area = [DJIVideoPresentViewAdjustHelper normalizeFrame:destRect withIdentityRect:streamRect];
    }

    self.videoPreviewer.contentClipRect = area;
}

-(void)setDefaultContentRect {
    self.videoPreviewer.contentClipRect = CGRectMake(0, 0, 1, 1);
}

#pragma mark Helper Methods
+(DJICamera *)camera {
    DJIBaseProduct *product = [DJISDKManager product];
    if (product == nil) {
        return nil;
    }

    if ([product isKindOfClass:[DJIAircraft class]]) {
        DJIAircraft *aircraft = (DJIAircraft *)product;
        return aircraft.camera;
    }
    else if ([product isKindOfClass:[DJIHandheld class]]) {
        DJIHandheld *handheld = (DJIHandheld *)product;
        return handheld.camera;
    }

    return nil;
}

+(BOOL) isUsingLightbridge2WithProductName:(NSString *)productName
                                isAircraft:(BOOL)isAircraft
                                cameraName:(NSString *)cameraName {
    if (!isAircraft) {
        return NO;
    }

    if ([productName isEqual:DJIAircraftModelNameA3] ||
        [productName isEqual:DJIAircraftModelNameMatrice600]) {
        return YES;
    }

    // Special case: can be stand-alone Lightbridge 2
    if ([productName isEqual:DJIAircraftModelNameUnknownAircraft]) {
        if (cameraName == nil) {
            return YES;
        }
    }

    return NO;
}

+ (H264EncoderType) getDataSourceWithCameraName:(NSString *)cameraName andIsAircraft:(BOOL)isAircraft {
    if ([cameraName isEqualToString:DJICameraDisplayNameX3] ||
        [cameraName isEqualToString:DJICameraDisplayNameZ3]) {
        DJICamera *camera = [VideoPreviewerSDKAdapter camera];
        /**
         *  Osmo's video encoding solution is changed since a firmware version.
         *  X3 also began to support digital zoom since that version. Therefore, 
         *  `isDigitalZoomScaleSupported` is used to determine the correct
         *  encode type.
         */
        if (!isAircraft && [camera isDigitalZoomScaleSupported]) {
            return H264EncoderType_A9_OSMO_NO_368;
        }
        else {
            return H264EncoderType_DM368_inspire;
        }
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNameX5] ||
             [cameraName isEqualToString:DJICameraDisplayNameX5R]) {
        return H264EncoderType_DM368_inspire;
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNamePhantom3ProfessionalCamera]) {
        return H264EncoderType_DM365_phamtom3x;
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNamePhantom3AdvancedCamera]) {
        return H264EncoderType_A9_phantom3s;
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNamePhantom3StandardCamera]) {
        return H264EncoderType_A9_phantom3c;
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNamePhantom4Camera]) {
        return H264EncoderType_1860_phantom4x;
    }
    else if ([cameraName isEqualToString:DJICameraDisplayNameMavicProCamera]) {
        DJIAircraft *product = (DJIAircraft *)[DJISDKManager product];
        if (product.airLink.wifiLink) {
            return H264EncoderType_1860_phantom4x;
        }
        else {
            return H264EncoderType_unknown;
        }
    }

    return H264EncoderType_unknown;
}

@end