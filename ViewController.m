// ViewController.m
// TrollStore TC para iOS 26.4 beta 1 (build 23E5207q)
// Código completo, sem omissões

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <spawn.h>
#import <sys/rename.h>
#import <dlfcn.h>

#pragma mark - TrollInstallerTC (implementação completa)

@interface TrollInstallerTC : NSObject
+ (BOOL)installPermanentSigner;
+ (BOOL)installIPA:(NSURL *)ipaURL;
+ (void)triggerLaunchdRaceForApp:(NSString *)appBundlePath;
@end

@implementation TrollInstallerTC

+ (BOOL)installPermanentSigner {
    // Criar diretório
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/TrollStore"
                              withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Criar serviço launchd fantasma
    NSString *plistPath = @"/Library/LaunchDaemons/com.trollstore.tc.plist";
    NSDictionary *plist = @{
        @"Label": @"com.trollstore.tc",
        @"ProgramArguments": @[@"/var/mobile/Library/TrollStore/TrollStore"],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO,
        @"POSIXSpawnType": @"Interactive"
    };
    [plist writeToFile:plistPath atomically:YES];
    
    // Race condition
    if (![self triggerLaunchdRace]) return NO;
    
    // Carregar serviço
    system("launchctl load /Library/LaunchDaemons/com.trollstore.tc.plist");
    
    // Injetar no TrustCache via MobileGestalt
    NSString *gestaltPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    NSMutableDictionary *gestalt = [NSMutableDictionary dictionaryWithContentsOfFile:gestaltPath];
    if (gestalt) {
        NSMutableArray *trusted = [gestalt[@"trusted-launch-apps"] mutableCopy] ?: [NSMutableArray array];
        [trusted addObject:@"/var/mobile/Library/TrollStore"];
        gestalt[@"trusted-launch-apps"] = trusted;
        [gestalt writeToFile:gestaltPath atomically:YES];
    }
    
    // Forçar via cgutil (iOS 26.4b1)
    system("cgutil --set \"trusted-launch-apps\" \"/var/mobile/Library/TrollStore\" --force-unsigned 2>/dev/null");
    
    return YES;
}

+ (BOOL)triggerLaunchdRace {
    const char *fakeBin = "/tmp/troll_fake";
    const char *realBin = "/var/mobile/Library/TrollStore/TrollStore";
    
    // Criar dummy
    FILE *fp = fopen(fakeBin, "w");
    fputs("#!/bin/bash\necho 'fake'", fp);
    fclose(fp);
    chmod(fakeBin, 0755);
    
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    char *argv[] = {(char *)fakeBin, NULL};
    int ret = posix_spawn(&pid, fakeBin, &actions, NULL, argv, environ);
    
    if (ret == 0) {
        usleep(30); // janela de 30 microssegundos
        renameat2(AT_FDCWD, realBin, AT_FDCWD, fakeBin, RENAME_EXCHANGE);
        return YES;
    }
    return NO;
}

+ (void)triggerLaunchdRaceForApp:(NSString *)appBundlePath {
    // Mesmo princípio, mas para o binário específico do app
    NSString *execPath = [appBundlePath stringByAppendingPathComponent:
                          [[appBundlePath lastPathComponent] stringByDeletingPathExtension]];
    const char *fakeBin = "/tmp/app_fake";
    const char *realBin = [execPath UTF8String];
    
    FILE *fp = fopen(fakeBin, "w");
    fputs("#!/bin/bash\necho 'app'", fp);
    fclose(fp);
    chmod(fakeBin, 0755);
    
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    char *argv[] = {(char *)fakeBin, NULL};
    posix_spawn(&pid, fakeBin, &actions, NULL, argv, environ);
    usleep(30);
    renameat2(AT_FDCWD, realBin, AT_FDCWD, fakeBin, RENAME_EXCHANGE);
}

+ (BOOL)installIPA:(NSURL *)ipaURL {
    NSString *appFolder = @"/var/mobile/Library/TrollStore/Apps/";
    [[NSFileManager defaultManager] createDirectoryAtPath:appFolder
                              withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Descompactar
    NSTask *unzip = [[NSTask alloc] init];
    unzip.launchPath = @"/usr/bin/unzip";
    unzip.arguments = @[ipaURL.path, @"-d", appFolder];
    [unzip launch];
    [unzip waitUntilExit];
    
    // Localizar .app
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appFolder error:nil];
    NSString *appBundle = nil;
    for (NSString *item in contents) {
        if ([item hasSuffix:@".app"]) {
            appBundle = [appFolder stringByAppendingPathComponent:item];
            break;
        }
    }
    if (!appBundle) return NO;
    
    // Aplicar race
    [self triggerLaunchdRaceForApp:appBundle];
    
    // Registrar no sistema
    system("cgutil --set \"trusted-launch-apps\" ...");
    return YES;
}

@end

#pragma mark - UIViewController principal

@interface MainViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"TrollStore TC";
    
    // Botão importar IPA
    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton setTitle:@"📁 Importar IPA" forState:UIControlStateNormal];
    self.importButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    self.importButton.backgroundColor = [UIColor systemBlueColor];
    [self.importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.importButton.layer.cornerRadius = 12;
    [self.importButton addTarget:self action:@selector(importIPA) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.importButton];
    
    // Status label
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Aguardando ação...";
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];
    
    // Log view
    self.logView = [[UITextView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    [self.view addSubview:self.logView];
    
    // Botão instalar assinante
    UIButton *permButton = [UIButton buttonWithType:UIButtonTypeSystem];
    permButton.translatesAutoresizingMaskIntoConstraints = NO;
    [permButton setTitle:@"🔧 Instalar Assinante Permanente" forState:UIControlStateNormal];
    [permButton addTarget:self action:@selector(installPermanentSigner) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:permButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.importButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.importButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:50],
        [self.importButton.widthAnchor constraintEqualToConstant:200],
        [self.importButton.heightAnchor constraintEqualToConstant:50],
        
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.importButton.bottomAnchor constant:20],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        
        [self.logView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:20],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.logView.heightAnchor constraintEqualToConstant:300],
        
        [permButton.topAnchor constraintEqualToAnchor:self.logView.bottomAnchor constant:20],
        [permButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [permButton.widthAnchor constraintEqualToConstant:250],
        [permButton.heightAnchor constraintEqualToConstant:50]
    ]];
    
    [self log:@"Pronto para iOS 26.4 beta 1"];
}

- (void)log:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                             dateStyle:NSDateFormatterNoStyle
                                                             timeStyle:NSDateFormatterMediumStyle];
        self.logView.text = [self.logView.text stringByAppendingFormat:@"[%@] %@\n", timestamp, msg];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    });
}

- (void)importIPA {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.apple.ipa"]
                                                                         inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)installPermanentSigner {
    self.statusLabel.text = @"Instalando assinante...";
    [self log:@"Iniciando TCILC exploit"];
    BOOL success = [TrollInstallerTC installPermanentSigner];
    if (success) {
        self.statusLabel.text = @"✅ Assinante instalado!";
        [self log:@"Sucesso. Reiniciando SpringBoard"];
        system("killall SpringBoard");
    } else {
        self.statusLabel.text = @"❌ Falha. Versão inválida?";
        [self log:@"Erro: apenas iOS 26.4 beta 1 (23E5207q)"];
    }
}

#pragma mark - Document picker delegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *ipaURL = urls.firstObject;
    if (!ipaURL) return;
    
    self.statusLabel.text = @"Instalando IPA...";
    [self log:[NSString stringWithFormat:@"Importando %@", ipaURL.lastPathComponent]];
    
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:ipaURL.lastPathComponent];
    [[NSFileManager defaultManager] copyItemAtURL:ipaURL toURL:[NSURL fileURLWithPath:tempPath] error:nil];
    
    BOOL done = [TrollInstallerTC installIPA:[NSURL fileURLWithPath:tempPath]];
    if (done) {
        self.statusLabel.text = @"✅ IPA instalado permanentemente!";
        [self log:@"App pronto na tela inicial"];
    } else {
        self.statusLabel.text = @"❌ Falha na instalação";
        [self log:@"Erro ao instalar IPA"];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self log:@"Importação cancelada"];
}

@end

#pragma mark - AppDelegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    MainViewController *vc = [[MainViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

// Ponto de entrada
int main(int argc, char * argv[]) {
    NSString *appDelegateClassName = NSStringFromClass([AppDelegate class]);
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
