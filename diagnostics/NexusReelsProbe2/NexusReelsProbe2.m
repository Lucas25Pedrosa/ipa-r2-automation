#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* NexusReelsProbe 2.0
 * Targeted passive observer for Facebook 579 Reels scrubber.
 * No swizzling, no IMP replacement, no UI/player mutation.
 */

static NSString *gLogPath;
static __weak UIView *gLastScrubber;
static __weak UISlider *gLastSlider;
static BOOL gLastScrubberHidden;
static CGFloat gLastScrubberAlpha = -1;
static BOOL gLastSliderHidden;
static CGFloat gLastSliderAlpha = -1;
static CGRect gLastScrubberFrame;
static CGRect gLastSliderFrame;
static float gLastSliderValue = -1000.0f;
static NSUInteger gTick = 0;
static const NSUInteger kMaxTicks = 1800; // 15 min @ 0.5s

static void Log(NSString *s) {
    if (!s.length) return;
    @try {
        if (!gLogPath) {
            NSString *base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
            gLogPath = [base stringByAppendingPathComponent:@"NexusReelsProbe2.txt"];
        }
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], s];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:gLogPath])
            [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
        NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    } @catch (__unused NSException *e) {}
}

static BOOL IsMainFacebook(void) {
    @try {
        NSString *ext = NSBundle.mainBundle.bundleURL.pathExtension.lowercaseString;
        NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
        return [ext isEqualToString:@"app"] && [bid containsString:@"facebook"];
    } @catch (__unused NSException *e) { return NO; }
}

static UIWindow *ActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive && ws.activationState != UISceneActivationStateForegroundInactive) continue;
        UIWindow *fallback = nil;
        for (UIWindow *w in ws.windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.isKeyWindow) return w;
            if (!fallback && w.windowLevel == UIWindowLevelNormal) fallback = w;
        }
        if (fallback) return fallback;
    }
    return nil;
}

static NSString *ClassName(id o) { return o ? NSStringFromClass([o class]) : @"(nil)"; }

static BOOL IsScrubber(UIView *v) {
    NSString *n = ClassName(v);
    return [n containsString:@"FBShortsSwiftPersistentScrubberView"];
}
static BOOL IsSlider(UIView *v) {
    NSString *n = ClassName(v);
    return [v isKindOfClass:UISlider.class] && [n containsString:@"FBShortsScrubberCustomSlider"];
}

static NSString *Ancestry(UIView *v) {
    NSMutableArray *a = [NSMutableArray array];
    UIView *x = v;
    for (int i=0; x && i<8; i++, x=x.superview) [a addObject:ClassName(x)];
    return [a componentsJoinedByString:@" <- "];
}

static void DumpMethods(Class c) {
    if (!c) return;
    @try {
        unsigned int count=0; Method *m=class_copyMethodList(c,&count);
        NSMutableArray *out=[NSMutableArray array];
        for (unsigned int i=0;i<count && out.count<120;i++) {
            SEL s=method_getName(m[i]); const char *cn=s?sel_getName(s):NULL;
            if (!cn) continue;
            NSString *n=[NSString stringWithUTF8String:cn]; NSString *l=n.lowercaseString;
            if ([l containsString:@"progress"] || [l containsString:@"duration"] || [l containsString:@"hidden"] || [l containsString:@"alpha"] || [l containsString:@"scrub"] || [l containsString:@"layout"] || [l containsString:@"control"] || [l containsString:@"play"] || [l containsString:@"reel"] || [l containsString:@"idle"]) {
                const char *types=method_getTypeEncoding(m[i]);
                [out addObject:[NSString stringWithFormat:@"%@ [%s]",n,types?:"?"]];
            }
        }
        if (m) free(m);
        Log([NSString stringWithFormat:@"METHODS %@ => %@",NSStringFromClass(c),[out componentsJoinedByString:@" | "]]);
    } @catch (__unused NSException *e) {}
}

static void LogScrubberState(UIView *s, UISlider *slider, NSString *reason) {
    @try {
        UIWindow *w=s.window;
        CGRect wf = w ? [s convertRect:s.bounds toView:w] : CGRectZero;
        CGRect sf=s.frame;
        NSString *state=[NSString stringWithFormat:@"%@ scrubber=%p class=%@ hidden=%d alpha=%.3f frame=(%.1f,%.1f %.1fx%.1f) windowFrame=(%.1f,%.1f %.1fx%.1f) userInteraction=%d superHidden=%d superAlpha=%.3f ancestry=%@",
                         reason,s,ClassName(s),s.hidden,s.alpha,sf.origin.x,sf.origin.y,sf.size.width,sf.size.height,wf.origin.x,wf.origin.y,wf.size.width,wf.size.height,s.userInteractionEnabled,s.superview.hidden,s.superview.alpha,Ancestry(s)];
        Log(state);
        if (slider) {
            CGRect f=slider.frame; CGRect ww=w?[slider convertRect:slider.bounds toView:w]:CGRectZero;
            Log([NSString stringWithFormat:@"SLIDER object=%p hidden=%d alpha=%.3f enabled=%d value=%.6f min=%.6f max=%.6f frame=(%.1f,%.1f %.1fx%.1f) windowFrame=(%.1f,%.1f %.1fx%.1f)",slider,slider.hidden,slider.alpha,slider.enabled,slider.value,slider.minimumValue,slider.maximumValue,f.origin.x,f.origin.y,f.size.width,f.size.height,ww.origin.x,ww.origin.y,ww.size.width,ww.size.height]);
        }
    } @catch (__unused NSException *e) {}
}

static void Walk(UIView *v, UIView **scrubber, UISlider **slider, NSUInteger depth, NSUInteger *count) {
    if (!v || depth>28 || *count>700) return; (*count)++;
    if (!*scrubber && IsScrubber(v)) *scrubber=v;
    if (!*slider && IsSlider(v)) *slider=(UISlider *)v;
    for (UIView *sub in v.subviews) {
        if (*count>700) break;
        Walk(sub,scrubber,slider,depth+1,count);
    }
}

static void Tick(void);
static void Schedule(void) {
    if (gTick>=kMaxTicks) { Log(@"STOP 15 minute diagnostic limit reached"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ Tick(); });
}
static void Tick(void) {
    @autoreleasepool {
        @try {
            gTick++;
            if (UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) { Schedule(); return; }
            UIWindow *w=ActiveWindow(); if (!w) { Schedule(); return; }
            UIView *s=nil; UISlider *slider=nil; NSUInteger count=0; Walk(w,&s,&slider,0,&count);
            if (s && s!=gLastScrubber) {
                gLastScrubber=s; gLastSlider=slider;
                gLastScrubberHidden=s.hidden; gLastScrubberAlpha=s.alpha; gLastScrubberFrame=s.frame;
                if (slider) { gLastSliderHidden=slider.hidden; gLastSliderAlpha=slider.alpha; gLastSliderFrame=slider.frame; gLastSliderValue=slider.value; }
                LogScrubberState(s,slider,@"SCRUBBER_FOUND_OR_REUSED");
                DumpMethods(s.class); if (slider) DumpMethods(slider.class);
                Class sup=class_getSuperclass(s.class); if (sup) DumpMethods(sup);
            } else if (s) {
                BOOL changed = s.hidden!=gLastScrubberHidden || fabs(s.alpha-gLastScrubberAlpha)>0.001 || !CGRectEqualToRect(s.frame,gLastScrubberFrame);
                BOOL sliderChanged = slider && (slider.hidden!=gLastSliderHidden || fabs(slider.alpha-gLastSliderAlpha)>0.001 || !CGRectEqualToRect(slider.frame,gLastSliderFrame));
                BOOL valueMilestone = slider && fabs(slider.value-gLastSliderValue)>=0.05f;
                if (changed || sliderChanged) LogScrubberState(s,slider,@"VISIBILITY_OR_LAYOUT_CHANGED");
                if (valueMilestone) Log([NSString stringWithFormat:@"PROGRESS_SAMPLE slider=%p value=%.6f min=%.6f max=%.6f",slider,slider.value,slider.minimumValue,slider.maximumValue]);
                gLastScrubberHidden=s.hidden; gLastScrubberAlpha=s.alpha; gLastScrubberFrame=s.frame;
                if (slider) { gLastSliderHidden=slider.hidden; gLastSliderAlpha=slider.alpha; gLastSliderFrame=slider.frame; if(valueMilestone)gLastSliderValue=slider.value; }
            } else if (gLastScrubber) {
                Log(@"SCRUBBER_REMOVED_FROM_ACTIVE_WINDOW"); gLastScrubber=nil; gLastSlider=nil;
            }
            if (gTick==1 || gTick%120==0) Log([NSString stringWithFormat:@"HEARTBEAT tick=%lu scannedViews=%lu scrubber=%@ slider=%@",(unsigned long)gTick,(unsigned long)count,s?@"yes":@"no",slider?@"yes":@"no"]);
        } @catch (NSException *e) { Log([NSString stringWithFormat:@"EXCEPTION %@: %@",e.name,e.reason]); }
    }
    Schedule();
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        if (!IsMainFacebook()) return;
        NSString *base=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject?:NSTemporaryDirectory();
        gLogPath=[base stringByAppendingPathComponent:@"NexusReelsProbe2.txt"];
        [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
        Log([NSString stringWithFormat:@"NexusReelsProbe 2.0 loaded | Facebook=%@ | log=%@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"?",gLogPath]);
        Log(@"MODE targeted passive observer; no hooks/swizzles/UI mutation");
        Log(@"TARGET FBShortsSwiftPersistentScrubberView + FBShortsScrubberCustomSlider");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ Tick(); });
    }
}

__attribute__((visibility("default"))) int NexusReelsProbe2Marker(void) { return 120; }
