#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

typedef BOOL (*IQFSettingsVisibleFunction)(void);
typedef void (*IQFPresentSettingsFunction)(void);
typedef void (*MSHookMessageExType)(Class, SEL, IMP, IMP *);

static BOOL gIconHookInstalled = NO;
static BOOL gTabHookInstalled = NO;
static BOOL gSettingsLayoutHookInstalled = NO;
static BOOL gSettingsAppearHookInstalled = NO;
static void (*gOriginalTabLayout)(id, SEL) = NULL;
static void (*gOriginalSettingsLayout)(id, SEL) = NULL;
static void (*gOriginalSettingsAppear)(id, SEL, BOOL) = NULL;
static NSTimeInterval gLastPresentation = 0;
static const void *kIQFContextMenuKey = &kIQFContextMenuKey;

static void *IQFFindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) return symbol;

    char underscored[128] = {0};
    if (strlen(name) + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }
    return symbol;
}

static NSDictionary<NSString *, NSString *> *IQFPortugueseUIStrings(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"iQFace Settings": @"Ajustes do iQFace",
            @"Back": @"Voltar",
            @"Language": @"Idioma",
            @"Follow system": @"Seguir idioma do sistema",
            @"Features": @"Recursos",
            @"Block ads": @"Bloquear anúncios",
            @"Download videos": @"Baixar vídeos",
            @"Anonymous stories": @"Stories anônimos",
            @"Feed": @"Feed",
            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Hide group suggestions": @"Ocultar sugestões de grupos",
            @"Hide \"People You May Know\"": @"Ocultar \"Pessoas que você talvez conheça\"",
            @"Confirmations": @"Confirmações",
            @"Tools": @"Ferramentas",
            @"Developer": @"Desenvolvedor",
            @"Join Telegram channel": @"Entrar no canal do Telegram",
            @"About": @"Sobre",
            @"English": @"Inglês",
            @"Confirm friend requests": @"Confirmar solicitações de amizade",
            @"Confirm follow and join": @"Confirmar ações de seguir e entrar",
            @"Confirm sending a message": @"Confirmar envio de mensagens",
            @"Confirm likes": @"Confirmar curtidas",
            @"Confirm sharing": @"Confirmar compartilhamento",
            @"Confirm publishing": @"Confirmar publicação",
            @"Confirm reporting": @"Confirmar denúncia",
            @"Asks before an action that is easy to tap by accident. Everything here is off until you turn it on.": @"Pede confirmação antes de ações que podem ser tocadas por engano. Todas ficam desativadas até você ativá-las.",
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-la."
        };
    });
    return map;
}

static NSString *IQFTranslateUIString(NSString *text) {
    if (text.length == 0) return text;
    NSString *translated = IQFPortugueseUIStrings()[text];
    return translated ?: text;
}

static void IQFTranslateBarButtonItem(UIBarButtonItem *item) {
    if (item == nil || item.title.length == 0) return;
    NSString *translated = IQFTranslateUIString(item.title);
    if (![translated isEqualToString:item.title]) item.title = translated;
}

static void IQFTranslateViewTree(UIView *view) {
    if (view == nil) return;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        for (NSNumber *stateNumber in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled), @(UIControlStateSelected)]) {
            UIControlState state = stateNumber.unsignedIntegerValue;
            NSString *title = [button titleForState:state];
            if (title.length == 0) continue;
            NSString *translated = IQFTranslateUIString(title);
            if (![translated isEqualToString:title]) [button setTitle:translated forState:state];
        }
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQFTranslateUIString(textView.text);
        if (![translated isEqualToString:textView.text]) textView.text = translated;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQFTranslateUIString(field.text);
        if (![translated isEqualToString:field.text]) field.text = translated;
        NSString *placeholder = field.placeholder;
        NSString *translatedPlaceholder = IQFTranslateUIString(placeholder);
        if (![translatedPlaceholder isEqualToString:placeholder]) field.placeholder = translatedPlaceholder;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < segmented.numberOfSegments; index++) {
            NSString *title = [segmented titleForSegmentAtIndex:index];
            if (title.length == 0) continue;
            NSString *translated = IQFTranslateUIString(title);
            if (![translated isEqualToString:title]) [segmented setTitle:translated forSegmentAtIndex:index];
        }
    }

    for (UIView *subview in view.subviews.copy) {
        IQFTranslateViewTree(subview);
    }
}

static void IQFTranslateControllerTree(UIViewController *controller, BOOL insideIQF) {
    if (controller == nil) return;
    BOOL isIQF = insideIQF || [NSStringFromClass(controller.class) isEqualToString:@"IQFSettingsViewController"];

    if (isIQF) {
        NSString *title = controller.title;
        NSString *translatedTitle = IQFTranslateUIString(title);
        if (![translatedTitle isEqualToString:title]) controller.title = translatedTitle;

        UINavigationItem *navigationItem = controller.navigationItem;
        NSString *navigationTitle = navigationItem.title;
        NSString *translatedNavigationTitle = IQFTranslateUIString(navigationTitle);
        if (![translatedNavigationTitle isEqualToString:navigationTitle]) navigationItem.title = translatedNavigationTitle;
        IQFTranslateBarButtonItem(navigationItem.leftBarButtonItem);
        IQFTranslateBarButtonItem(navigationItem.rightBarButtonItem);
        for (UIBarButtonItem *item in navigationItem.leftBarButtonItems) IQFTranslateBarButtonItem(item);
        for (UIBarButtonItem *item in navigationItem.rightBarButtonItems) IQFTranslateBarButtonItem(item);

        if (controller.isViewLoaded) IQFTranslateViewTree(controller.view);
    }

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQFTranslateControllerTree(child, isIQF);
    }
    if (controller.presentedViewController != nil) {
        IQFTranslateControllerTree(controller.presentedViewController, isIQF);
    }
}

static void IQFTranslateVisibleSettings(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIViewController *root = window.rootViewController;
        if (root != nil) IQFTranslateControllerTree(root, NO);
    }
}

static void IQFScheduleTranslationPasses(void) {
    const NSTimeInterval delays[] = {0.03, 0.12, 0.35, 0.75, 1.25};
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFTranslateVisibleSettings();
        });
    }
}

static BOOL IQFSettingsVisible(void) {
    IQFSettingsVisibleFunction visible = (IQFSettingsVisibleFunction)IQFFindSymbol("IQFSettingsVisible");
    return visible != NULL && visible();
}

static void IQFOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - gLastPresentation < 0.9 || IQFSettingsVisible()) return;

    IQFPresentSettingsFunction present = (IQFPresentSettingsFunction)IQFFindSymbol("IQFPresentSettings");
    if (present == NULL) return;

    gLastPresentation = now;
    present();
    IQFScheduleTranslationPasses();
}

static void IQFCallVoid(id object, SEL selector) {
    if (object == nil || selector == NULL || ![object respondsToSelector:selector]) return;
    IMP imp = [object methodForSelector:selector];
    if (imp != NULL) ((void (*)(id, SEL))imp)(object, selector);
}

static void IQFDropButton(id navigationBar) {
    IQFCallVoid(navigationBar, NSSelectorFromString(@"iqf_dropButton"));
}

static void IQFBlockedInstallButton(id self, SEL command) {
    (void)command;
    IQFDropButton(self);
}

static void IQFDropRecursively(UIView *view, Class navigationBarClass) {
    if (view == nil) return;
    if (navigationBarClass != Nil && [view isKindOfClass:navigationBarClass]) IQFDropButton(view);
    for (UIView *subview in view.subviews.copy) IQFDropRecursively(subview, navigationBarClass);
}

static void IQFRemoveExistingButtons(void) {
    Class cls = NSClassFromString(@"FBNavigationBar");
    if (cls == Nil) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) IQFDropRecursively(window, cls);
}

static BOOL IQFInstallIconHook(void) {
    if (gIconHookInstalled) return YES;
    Class cls = NSClassFromString(@"FBNavigationBar");
    SEL selector = NSSelectorFromString(@"iqf_installButton");
    if (cls == Nil || selector == NULL) return NO;

    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NO;
    method_setImplementation(method, (IMP)&IQFBlockedInstallButton);
    gIconHookInstalled = YES;
    IQFRemoveExistingButtons();
    return YES;
}

@interface IQFContextMenuDelegate : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)shared;
@end

@implementation IQFContextMenuDelegate
+ (instancetype)shared {
    static IQFContextMenuDelegate *delegate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ delegate = [IQFContextMenuDelegate new]; });
    return delegate;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
    (void)interaction;
    (void)location;
    return [UIContextMenuConfiguration
        configurationWithIdentifier:@"com.7md.iqface.enhancer.settings"
                     previewProvider:nil
                      actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggested) {
        (void)suggested;
        UIImage *image = [UIImage systemImageNamed:@"gearshape"];
        UIAction *action = [UIAction
            actionWithTitle:@"Ajustes do iQFace"
                     image:image
                identifier:@"com.7md.iqface.enhancer.open-settings"
                   handler:^(__kindof UIAction * _Nonnull actionObject) {
            (void)actionObject;
            dispatch_async(dispatch_get_main_queue(), ^{ IQFOpenSettings(); });
        }];
        return [UIMenu menuWithTitle:@"" children:@[action]];
    }];
}
@end

static void IQFAttachContextMenu(UIView *view) {
    if (view == nil || objc_getAssociatedObject(view, kIQFContextMenuKey) != nil) return;
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:IQFContextMenuDelegate.shared];
    [view addInteraction:interaction];
    objc_setAssociatedObject(view, kIQFContextMenuKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFTabLayout(id self, SEL command) {
    if (gOriginalTabLayout != NULL) gOriginalTabLayout(self, command);
    if ([self isKindOfClass:UIView.class]) IQFAttachContextMenu((UIView *)self);
}

static void IQFTranslateSettingsController(UIViewController *controller) {
    if (controller == nil) return;

    NSString *title = controller.title;
    NSString *translatedTitle = IQFTranslateUIString(title);
    if (![translatedTitle isEqualToString:title]) controller.title = translatedTitle;

    UINavigationItem *navigationItem = controller.navigationItem;
    NSString *navigationTitle = navigationItem.title;
    NSString *translatedNavigationTitle = IQFTranslateUIString(navigationTitle);
    if (![translatedNavigationTitle isEqualToString:navigationTitle]) navigationItem.title = translatedNavigationTitle;
    IQFTranslateBarButtonItem(navigationItem.leftBarButtonItem);
    IQFTranslateBarButtonItem(navigationItem.rightBarButtonItem);
    for (UIBarButtonItem *item in navigationItem.leftBarButtonItems) IQFTranslateBarButtonItem(item);
    for (UIBarButtonItem *item in navigationItem.rightBarButtonItems) IQFTranslateBarButtonItem(item);

    if (controller.isViewLoaded) IQFTranslateViewTree(controller.view);

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQFTranslateSettingsController(child);
    }
}

static void IQFSettingsViewDidLayoutSubviews(id self, SEL command) {
    if (gOriginalSettingsLayout != NULL) gOriginalSettingsLayout(self, command);
    if ([self isKindOfClass:UIViewController.class]) {
        IQFTranslateSettingsController((UIViewController *)self);
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTranslateSettingsController((UIViewController *)self);
        });
    }
}

static void IQFSettingsViewDidAppear(id self, SEL command, BOOL animated) {
    if (gOriginalSettingsAppear != NULL) gOriginalSettingsAppear(self, command, animated);
    if ([self isKindOfClass:UIViewController.class]) {
        IQFTranslateSettingsController((UIViewController *)self);
        IQFScheduleTranslationPasses();
    }
}

static BOOL IQFInstallSettingsRefreshHooks(void) {
    Class cls = NSClassFromString(@"IQFSettingsViewController");
    MSHookMessageExType hook = (MSHookMessageExType)IQFFindSymbol("MSHookMessageEx");
    if (cls == Nil || hook == NULL) return NO;

    if (!gSettingsLayoutHookInstalled) {
        SEL selector = @selector(viewDidLayoutSubviews);
        if (class_getInstanceMethod(cls, selector) != NULL) {
            hook(cls, selector, (IMP)&IQFSettingsViewDidLayoutSubviews, (IMP *)&gOriginalSettingsLayout);
            if (gOriginalSettingsLayout != NULL) gSettingsLayoutHookInstalled = YES;
        }
    }

    if (!gSettingsAppearHookInstalled) {
        SEL selector = @selector(viewDidAppear:);
        if (class_getInstanceMethod(cls, selector) != NULL) {
            hook(cls, selector, (IMP)&IQFSettingsViewDidAppear, (IMP *)&gOriginalSettingsAppear);
            if (gOriginalSettingsAppear != NULL) gSettingsAppearHookInstalled = YES;
        }
    }

    return gSettingsLayoutHookInstalled && gSettingsAppearHookInstalled;
}

static BOOL IQFInstallGlowStyleTabHook(void) {
    if (gTabHookInstalled) return YES;
    Class cls = NSClassFromString(@"FBTabBarItemDefaultView");
    MSHookMessageExType hook = (MSHookMessageExType)IQFFindSymbol("MSHookMessageEx");
    if (cls == Nil || hook == NULL || class_getInstanceMethod(cls, @selector(layoutSubviews)) == NULL) return NO;

    hook(cls, @selector(layoutSubviews), (IMP)&IQFTabLayout, (IMP *)&gOriginalTabLayout);
    if (gOriginalTabLayout == NULL) return NO;
    gTabHookInstalled = YES;
    return YES;
}

static void IQFTryInstall(NSUInteger attempt) {
    BOOL icon = IQFInstallIconHook();
    BOOL tab = IQFInstallGlowStyleTabHook();
    BOOL settings = IQFInstallSettingsRefreshHooks();
    if ((!icon || !tab || !settings) && attempt < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFTryInstall(attempt + 1);
        });
    }
}

__attribute__((constructor))
static void IQFEnhancerInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            (void)note;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                IQFInstallIconHook();
                IQFRemoveExistingButtons();
            });
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTryInstall(0);
            IQFRemoveExistingButtons();
        });
    }
}
