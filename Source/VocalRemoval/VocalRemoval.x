#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "VocalRemoval.h"
#import "InstrumentalStream.h"
#import "../Headers/Localization.h"

@interface YTMPlayerHeaderView : UIView
@property (nonatomic, readonly) UIView *collapseButton;
@property (nonatomic, readonly) UIView *audioVideoSwitch;
@property (nonatomic, readonly) UIView *actionButton;
@property (nonatomic, readonly) UIView *castButton;
@property (nonatomic, readonly) UIView *askMusicButtonView;
@end

@interface YTMPlayerHeaderViewController : UIViewController
@property (nonatomic, readonly) YTMPlayerHeaderView *headerView;
@end

static NSHashTable<UIButton *> *controls;
static NSTimer *statusTimer;
static BOOL loading;
static NSUInteger requestID;
static NSString *statusOverride;

static UIViewController *PresentingController(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController *controller = (UIViewController *)responder;
            while (controller.presentedViewController) controller = controller.presentedViewController;
            return controller;
        }
    }
    return nil;
}

static NSString *EffectStatus(void) {
    if (loading) return LOC(@"VOCAL_LOADING");
    if (statusOverride) return statusOverride;
    switch (YTMUInstrumentalStatus()) {
        case 1: return LOC(@"VOCAL_BUFFERING");
        case 2: return LOC(@"VOCAL_ACTIVE");
        case 3: return LOC(@"VOCAL_ORIGINAL");
        case 4: return LOC(@"VOCAL_UNAVAILABLE");
        default: return LOC(@"VOCAL_OFF");
    }
}

static void UpdateVocalControls(void) {
    BOOL on = loading || YTMUInstrumentalIsEnabled();
    for (UIButton *button in controls) {
        button.selected = on;
        button.accessibilityValue = EffectStatus();
        button.tintColor = on ? UIColor.systemTealColor : UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:on ? 0.67 : 0.42];
    }
}

static NSURL *BundledModel(void) {
    return [NSBundle.ytmu_defaultBundle URLForResource:@"InstHQ4" withExtension:@"mlmodelc"] ?:
           [NSBundle.mainBundle URLForResource:@"InstHQ4" withExtension:@"mlmodelc"];
}

static void ToggleVocalRemoval(UIView *anchor) {
    ++requestID;
    statusOverride = nil;
    if (loading || YTMUInstrumentalIsEnabled()) {
        loading = NO;
        YTMUStopVocalRemoval();
        [statusTimer invalidate];
        statusTimer = nil;
        UpdateVocalControls();
        return;
    }

    NSURL *model = BundledModel();
    if (!model) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"VOCAL_TITLE")
            message:LOC(@"VOCAL_MODEL_MISSING") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"VOCAL_OK") style:UIAlertActionStyleDefault handler:nil]];
        [PresentingController(anchor) presentViewController:alert animated:YES completion:nil];
        return;
    }

    loading = YES;
    NSUInteger started = requestID;
    UpdateVocalControls();
    __weak UIView *weakAnchor = anchor;
    YTMUStartVocalRemoval(model.fileSystemRepresentation, ^(bool success) {
        if (requestID != started) return;
        loading = NO;
        if (!success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"VOCAL_TITLE")
                message:LOC(@"VOCAL_MODEL_ERROR") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOC(@"VOCAL_OK") style:UIAlertActionStyleDefault handler:nil]];
            [PresentingController(weakAnchor) presentViewController:alert animated:YES completion:nil];
        } else {
            CFTimeInterval enabledAt = CACurrentMediaTime();
            statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                if (!YTMUInstrumentalCurrentStream().generation &&
                    CACurrentMediaTime() - enabledAt > 12 && YTMUInstrumentalStatus() == 1) {
                    statusOverride = LOC(@"VOCAL_NO_STREAM");
                } else {
                    statusOverride = nil;
                }
                UpdateVocalControls();
            }];
        }
        UpdateVocalControls();
        if (UIAccessibilityIsVoiceOverRunning()) {
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, EffectStatus());
        }
    });
}

static CGRect VocalButtonFrame(YTMPlayerHeaderView *header, UIButton *button) {
    CGRect area = UIEdgeInsetsInsetRect(header.bounds, header.safeAreaInsets);
    const CGFloat size = 44;
    if (CGRectGetHeight(area) < size) return CGRectNull;

    // Try the leading gap first so the audio/video switch and trailing menu stay tappable.
    CGFloat y = CGRectGetMidY(area) - size / 2;
    for (CGFloat x = CGRectGetMinX(area) + 4; x + size <= CGRectGetMaxX(area) - 4; x += 2) {
        CGRect frame = CGRectMake(x, y, size, size);
        BOOL fits = YES;
        for (UIView *view in header.subviews) {
            if (view == button || view.hidden || view.alpha < 0.05 || !view.userInteractionEnabled) continue;
            if (CGRectIntersectsRect(frame, CGRectInset(view.frame, -3, 0))) {
                fits = NO;
                break;
            }
        }
        if (fits) return frame;
    }
    return CGRectNull;
}

static char buttonKey;

%hook YTMPlayerHeaderView

- (void)layoutSubviews {
    %orig;
    if (@available(iOS 16.0, *)) {
        UIButton *button = objc_getAssociatedObject(self, &buttonKey);
        if (!button) {
            button = [UIButton buttonWithType:UIButtonTypeCustom];
            UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:20
                weight:UIImageSymbolWeightSemibold];
            [button setImage:[UIImage systemImageNamed:@"mic.slash" withConfiguration:symbol] forState:UIControlStateNormal];
            [button setImage:[UIImage systemImageNamed:@"mic.slash.fill" withConfiguration:symbol] forState:UIControlStateSelected];
            button.accessibilityLabel = LOC(@"VOCAL_TITLE");
            button.accessibilityIdentifier = @"YTMusicUltimate.VocalRemoval";
            button.layer.cornerRadius = 22;
            [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                ToggleVocalRemoval((UIView *)action.sender);
            }] forControlEvents:UIControlEventTouchUpInside];
            if (!controls) controls = [NSHashTable weakObjectsHashTable];
            [controls addObject:button];
            objc_setAssociatedObject(self, &buttonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self addSubview:button];
            UpdateVocalControls();
        }
        CGRect frame = VocalButtonFrame(self, button);
        button.hidden = CGRectIsNull(frame);
        if (!button.hidden) {
            button.frame = frame;
            [self bringSubviewToFront:button];
        }
    }
}

%end

%hook YTMPlayerHeaderViewController

- (void)didTapActionButton:(id)sender {
    if (@available(iOS 16.0, *)) {
        UIButton *button = objc_getAssociatedObject(self.headerView, &buttonKey);
        if (button && button.hidden) {
            UIAlertController *menu = [UIAlertController alertControllerWithTitle:LOC(@"VOCAL_TITLE")
                message:EffectStatus() preferredStyle:UIAlertControllerStyleActionSheet];
            BOOL on = loading || YTMUInstrumentalIsEnabled();
            __weak typeof(self) weakSelf = self;
            [menu addAction:[UIAlertAction actionWithTitle:LOC(on ? @"VOCAL_TURN_OFF" : @"VOCAL_TURN_ON")
                style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    ToggleVocalRemoval(weakSelf.headerView);
                }]];
            [menu addAction:[UIAlertAction actionWithTitle:LOC(@"VOCAL_MORE") style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    [weakSelf dismissViewControllerAnimated:YES completion:^{ %orig(sender); }];
                }]];
            [menu addAction:[UIAlertAction actionWithTitle:LOC(@"VOCAL_CANCEL")
                style:UIAlertActionStyleCancel handler:nil]];
            UIView *source = [sender isKindOfClass:UIView.class] ? sender : self.headerView;
            menu.popoverPresentationController.sourceView = source;
            menu.popoverPresentationController.sourceRect = source.bounds;
            [self presentViewController:menu animated:YES completion:nil];
            return;
        }
    }
    %orig;
}
%end
