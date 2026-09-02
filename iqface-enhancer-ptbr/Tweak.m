#import <Foundation/Foundation.h>

/* iQFaceEnhancer 0.3.0 — known-good Glow-style activation + pt-BR IQFLoc hook. */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

typedef NSString *(*IQFLocFunction)(NSString *key);
typedef BOOL (*IQFSettingsVisibleFunction)(void);
typedef void (*IQFPresentSettingsFunction)(void);
typedef void (*MSHookFunctionType)(void *symbol, void *replacement, void **original);
typedef void (*MSHookMessageExType)(Class cls, SEL selector, IMP replacement, IMP *original);

static IQFLocFunction IQFOriginalLoc = NULL;
static BOOL IQFLocalizationInstalled = NO;
static NSInteger IQFInstallAttempt = 0;
static NSTimeInterval IQFLastPresentationTime = 0;

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

static BOOL IQFShouldUsePortuguese(void) {
    id forcedValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"IQFEnhancerForcePortuguese"];
    if (forcedValue != nil) return [forcedValue boolValue];
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQFPortugueseTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            @"%lu downloads": @"%lu downloads",
            @"Downloading…": @"Baixando…",
            @"Cancel": @"Cancelar",
            @"Cancelling…": @"Cancelando…",
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
            @"Cancelled": @"Cancelado",
            @"Could not write the file": @"Não foi possível salvar o arquivo",
            @"Download ended with no file": @"O download terminou sem gerar um arquivo",
            @"The downloaded video has no readable video track": @"O vídeo baixado não possui uma faixa de vídeo legível",
            @"This video cannot be exported on this device": @"Este vídeo não pode ser exportado neste dispositivo",
            @"Merging failed": @"Falha ao combinar os arquivos",
            @"Nothing to save": @"Não há nada para salvar",
            @"This quality cannot be converted on this device (%@)": @"Esta qualidade não pode ser convertida neste dispositivo (%@)",
            @"Nothing to download": @"Não há nada para baixar",
            @"Facebook returned an unreadable stream for this quality": @"O Facebook retornou um fluxo ilegível para esta qualidade",
            @"Could not combine the video and audio": @"Não foi possível combinar o vídeo e o áudio",
            @"Confirm posting a comment": @"Confirmar publicação do comentário",
            @"Post this comment?": @"Publicar este comentário?",
            @"Confirm": @"Confirmar",
            @"Yes": @"Sim",
            @"Confirm friend requests": @"Confirmar solicitações de amizade",
            @"Confirm follow and join": @"Confirmar ações de seguir e entrar",
            @"Confirm sending a message": @"Confirmar envio de mensagens",
            @"Confirm likes": @"Confirmar curtidas",
            @"Confirm sharing": @"Confirmar compartilhamento",
            @"Confirm publishing": @"Confirmar publicação",
            @"Confirm reporting": @"Confirmar denúncia",
            @"Send or cancel this friend request?": @"Enviar ou cancelar esta solicitação de amizade?",
            @"Follow, unfollow or join?": @"Seguir, deixar de seguir ou entrar?",
            @"Send this message?": @"Enviar esta mensagem?",
            @"Send this like?": @"Enviar esta curtida?",
            @"Remove this like?": @"Remover esta curtida?",
            @"Share this?": @"Compartilhar isto?",
            @"Publish this?": @"Publicar isto?",
            @"Send this report?": @"Enviar esta denúncia?",
            @"Asks before an action that is easy to tap by accident. Everything here is off until you turn it on.": @"Pede confirmação antes de ações que podem ser tocadas por engano. Todas ficam desativadas até você ativá-las.",
            @"Nothing to download here.": @"Não há nada para baixar aqui.",
            @"Marked as seen": @"Marcado como visto",
            @"Already marked as seen": @"Já estava marcado como visto",
            @"They can already see you": @"Essa pessoa já pode ver que você assistiu",
            @"Nothing to send for this story": @"Não há nada para enviar neste story",
            @"Downloading": @"Baixando",
            @"Converting": @"Convertendo",
            @"Merging": @"Combinando",
            @"Saving…": @"Salvando…",
            @"This video cannot be downloaded.": @"Este vídeo não pode ser baixado.",
            @"No video found here.": @"Nenhum vídeo foi encontrado aqui.",
            @"Photos access is denied for Facebook.": @"O acesso do Facebook ao app Fotos foi negado.",
            @"Download": @"Baixar",
            @"Auto-advance": @"Avanço automático",
            @"Hide video buttons": @"Ocultar botões do vídeo",
            @"Show video buttons": @"Mostrar botões do vídeo",
            @"Auto-advance on": @"Avanço automático ativado",
            @"Auto-advance off": @"Avanço automático desativado",
            @"Copy caption": @"Copiar legenda",
            @"Caption copied": @"Legenda copiada",
            @"Nothing to copy": @"Não há nada para copiar",
            @"Saved to Photos": @"Salvo no app Fotos",
            @"Download failed": @"Falha no download",
            @"Photos refused the file.": @"O app Fotos recusou o arquivo.",
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-la.",
            @"OK": @"OK"
        };
    });
    return translations;
}

static NSString *IQFLocalizedPortuguese(NSString *key) {
    if (key.length == 0 || !IQFShouldUsePortuguese()) return nil;
    return IQFPortugueseTranslations()[key];
}

static NSString *IQFLocReplacement(NSString *key) {
    NSString *translation = IQFLocalizedPortuguese(key);
    if (translation != nil) return translation;
    return IQFOriginalLoc != NULL ? IQFOriginalLoc(key) : key;
}

static BOOL IQFInstallLocalizationHook(void) {
    if (IQFLocalizationInstalled) return YES;
    void *locSymbol = IQFFindSymbol("IQFLoc");
    MSHookFunctionType hookFunction = (MSHookFunctionType)IQFFindSymbol("MSHookFunction");
    if (locSymbol == NULL || hookFunction == NULL) return NO;
    hookFunction(locSymbol, (void *)&IQFLocReplacement, (void **)&IQFOriginalLoc);
    IQFLocalizationInstalled = IQFOriginalLoc != NULL;
    return IQFLocalizationInstalled;
}

static BOOL IQFIconSuppressionInstalled = NO;

static void IQFInvokeVoidSelector(id object, SEL selector) {
    if (object == nil || selector == NULL || ![object respondsToSelector:selector]) return;
    IMP implementation = [object methodForSelector:selector];
    if (implementation != NULL) ((void (*)(id, SEL))implementation)(object, selector);
}

static void IQFDropSettingsButtonFromNavigationBar(id navigationBar) {
    IQFInvokeVoidSelector(navigationBar, NSSelectorFromString(@"iqf_dropButton"));
}

static void IQFBlockedInstallButton(id self, SEL command) {
    (void)command;
    IQFDropSettingsButtonFromNavigationBar(self);
}

static void IQFDropButtonRecursively(UIView *view, Class navigationBarClass) {
    if (view == nil) return;
    if (navigationBarClass != Nil && [view isKindOfClass:navigationBarClass]) IQFDropSettingsButtonFromNavigationBar(view);
    for (UIView *subview in view.subviews.copy) IQFDropButtonRecursively(subview, navigationBarClass);
}

static void IQFRemoveExistingSettingsButtons(void) {
    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");
    if (navigationBarClass == Nil) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) IQFDropButtonRecursively(window, navigationBarClass);
}

static BOOL IQFInstallIconSuppressionHook(void) {
    if (IQFIconSuppressionInstalled) return YES;
    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");
    SEL installSelector = NSSelectorFromString(@"iqf_installButton");
    if (navigationBarClass == Nil || installSelector == NULL) return NO;
    Method installMethod = class_getInstanceMethod(navigationBarClass, installSelector);
    if (installMethod == NULL) return NO;
    IMP current = method_getImplementation(installMethod);
    if (current != (IMP)&IQFBlockedInstallButton) method_setImplementation(installMethod, (IMP)&IQFBlockedInstallButton);
    IQFIconSuppressionInstalled = YES;
    IQFRemoveExistingSettingsButtons();
    return YES;
}

static BOOL IQFSettingsAreVisible(void) {
    IQFSettingsVisibleFunction visible = (IQFSettingsVisibleFunction)IQFFindSymbol("IQFSettingsVisible");
    return visible != NULL && visible();
}

static void IQFOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - IQFLastPresentationTime < 0.9 || IQFSettingsAreVisible()) return;
    IQFPresentSettingsFunction present = (IQFPresentSettingsFunction)IQFFindSymbol("IQFPresentSettings");
    if (present == NULL) return;
    IQFLastPresentationTime = now;
    present();
}

static BOOL IQFGlowStyleActivationInstalled = NO;
static void (*IQFOriginalTabItemLayoutSubviews)(id, SEL) = NULL;
static const void *IQFContextMenuAssociationKey = &IQFContextMenuAssociationKey;

@interface IQFEnhancerContextMenuDelegate : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)sharedDelegate;
@end

@implementation IQFEnhancerContextMenuDelegate
+ (instancetype)sharedDelegate {
    static IQFEnhancerContextMenuDelegate *delegate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ delegate = [IQFEnhancerContextMenuDelegate new]; });
    return delegate;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    (void)interaction; (void)location;
    return [UIContextMenuConfiguration configurationWithIdentifier:@"com.7md.iqface.enhancer.settings" previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggestedActions) {
        (void)suggestedActions;
        NSString *title = IQFLocalizedPortuguese(@"iQFace Settings") ?: @"iQFace Settings";
        UIImage *image = [UIImage systemImageNamed:@"gearshape"];
        UIAction *settingsAction = [UIAction actionWithTitle:title image:image identifier:@"com.7md.iqface.enhancer.open-settings" handler:^(__kindof UIAction * _Nonnull action) {
            (void)action;
            dispatch_async(dispatch_get_main_queue(), ^{ IQFOpenSettings(); });
        }];
        return [UIMenu menuWithTitle:@"" children:@[settingsAction]];
    }];
}
@end

static void IQFAttachGlowStyleContextMenu(UIView *view) {
    if (view == nil || objc_getAssociatedObject(view, IQFContextMenuAssociationKey) != nil) return;
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:IQFEnhancerContextMenuDelegate.sharedDelegate];
    [view addInteraction:interaction];
    objc_setAssociatedObject(view, IQFContextMenuAssociationKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFTabItemLayoutSubviews(id self, SEL command) {
    if (IQFOriginalTabItemLayoutSubviews != NULL) IQFOriginalTabItemLayoutSubviews(self, command);
    if ([self isKindOfClass:UIView.class]) IQFAttachGlowStyleContextMenu((UIView *)self);
}

static BOOL IQFInstallGlowStyleActivationHook(void) {
    if (IQFGlowStyleActivationInstalled) return YES;
    Class tabItemClass = NSClassFromString(@"FBTabBarItemDefaultView");
    MSHookMessageExType hookMessage = (MSHookMessageExType)IQFFindSymbol("MSHookMessageEx");
    if (tabItemClass == Nil || hookMessage == NULL || class_getInstanceMethod(tabItemClass, @selector(layoutSubviews)) == NULL) return NO;
    hookMessage(tabItemClass, @selector(layoutSubviews), (IMP)&IQFTabItemLayoutSubviews, (IMP *)&IQFOriginalTabItemLayoutSubviews);
    if (IQFOriginalTabItemLayoutSubviews == NULL) return NO;
    IQFGlowStyleActivationInstalled = YES;
    return YES;
}

static void IQFApplicationDidBecomeActive(NSNotification *notification) {
    (void)notification;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IQFInstallIconSuppressionHook();
        IQFRemoveExistingSettingsButtons();
    });
}

static void IQFTryInstallIQFaceHooks(void) {
    IQFInstallAttempt += 1;
    BOOL localizationReady = IQFInstallLocalizationHook();
    BOOL iconReady = IQFInstallIconSuppressionHook();
    BOOL activationReady = IQFInstallGlowStyleActivationHook();
    if ((!localizationReady || !iconReady || !activationReady) && IQFInstallAttempt < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ IQFTryInstallIQFaceHooks(); });
    }
}

__attribute__((constructor))
static void IQFEnhancerInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] || [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { IQFApplicationDidBecomeActive(notification); }];
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTryInstallIQFaceHooks();
            IQFRemoveExistingSettingsButtons();
        });
    }
}
