// ViewController.m – Instalador com UI, forward declarations e logs
#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>  // Para kUTTypeItem
#import <spawn.h>
#import <dlfcn.h>

extern char **environ;  // <-- CORREÇÃO 1: declaração de environ

// ============================================================
// FORWARD DECLARATIONS (API privada)
// ============================================================
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)bundleURL withOptions:(NSDictionary *)options error:(NSError **)error;
@end

// ============================================================
// UIViewController
// ============================================================
@interface ViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *selectButton;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"sto26 Installer";
    
    // Botão
    self.selectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.selectButton setTitle:@"📁 Selecionar IPA e instalar" forState:UIControlStateNormal];
    [self.selectButton addTarget:self action:@selector(pickIPA) forControlEvents:UIControlEventTouchUpInside];
    self.selectButton.frame = CGRectMake(20, 100, self.view.bounds.size.width - 40, 50);
    [self.view addSubview:self.selectButton];
    
    // TextView para logs
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 170, self.view.bounds.size.width - 40, 400)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    self.logView.layer.cornerRadius = 8;
    [self.view addSubview:self.logView];
    
    [self log:@"Pronto. Selecione um IPA."];
}

- (void)log:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        NSString *ts = [df stringFromDate:[NSDate date]];
        self.logView.text = [self.logView.text stringByAppendingFormat:@"[%@] %@\n", ts, msg];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
        NSLog(@"%@", msg);
    });
}

// ============================================================
// Selecionar IPA
// ============================================================
- (void)pickIPA {
    // CORREÇÃO 2: usar kUTTypeItem (importado de MobileCoreServices)
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[(NSString *)kUTTypeItem]
        inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *ipaURL = urls.firstObject;
    if (!ipaURL) return;
    [self log:[NSString stringWithFormat:@"📦 Selecionado: %@", ipaURL.lastPathComponent]];
    [self installIPA:ipaURL.path];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self log:@"Cancelado."];
}

// ============================================================
// Extrair e instalar (usando Documents)
// ============================================================
- (void)installIPA:(NSString *)ipaPath {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self log:@"🔧 Extraindo IPA..."];
        
        NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *extractDir = [docPath stringByAppendingPathComponent:@"ipa_extract"];
        
        // Limpa extração anterior
        [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        // Extrai com unzip via posix_spawn
        pid_t pid;
        char *argv[] = {"/usr/bin/unzip", "-q", (char *)[ipaPath UTF8String], "-d", (char *)[extractDir UTF8String], NULL};
        int status = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
        if (status != 0 || waitpid(pid, &status, 0) != pid) {
            [self log:@"❌ Falha ao extrair IPA."];
            [self showAlert:@"Erro" message:@"Falha ao extrair o arquivo IPA."];
            return;
        }
        [self log:@"✅ Extração concluída."];
        
        // Localiza o .app
        NSString *payloadDir = [extractDir stringByAppendingPathComponent:@"Payload"];
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDir error:nil];
        NSString *appBundle = nil;
        for (NSString *item in contents) {
            if ([item hasSuffix:@".app"]) {
                appBundle = [payloadDir stringByAppendingPathComponent:item];
                break;
            }
        }
        if (!appBundle) {
            [self log:@"❌ Nenhum .app encontrado."];
            [self showAlert:@"Erro" message:@"O IPA não contém um aplicativo válido."];
            return;
        }
        [self log:[NSString stringWithFormat:@"📱 App encontrado: %@", appBundle.lastPathComponent]];
        
        // Tenta instalar via LSApplicationWorkspace
        [self log:@"🔧 Tentando instalar via LSApplicationWorkspace..."];
        BOOL installed = [self installViaWorkspace:appBundle];
        
        if (installed) {
            [self log:@"✅ INSTALADO COM SUCESSO!"];
            [self showAlert:@"Sucesso" message:@"Aplicativo instalado permanentemente!"];
        } else {
            [self log:@"❌ Falha na instalação. Tente reiniciar o dispositivo."];
            [self showAlert:@"Erro" message:@"Falha ao instalar. Verifique os logs."];
        }
    });
}

// ============================================================
// Instalação via LSApplicationWorkspace
// ============================================================
- (BOOL)installViaWorkspace:(NSString *)appPath {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) {
        [self log:@"❌ LSApplicationWorkspace não disponível."];
        return NO;
    }
    
    id workspace = [cls performSelector:@selector(defaultWorkspace)];
    if (!workspace) {
        [self log:@"❌ defaultWorkspace falhou."];
        return NO;
    }
    
    NSURL *bundleURL = [NSURL fileURLWithPath:appPath];
    NSDictionary *options = @{
        @"AllowProvisioningDevice": @YES,
        @"InstallType": @"System"
    };
    
    NSError *error = nil;
    BOOL result = [workspace installApplication:bundleURL withOptions:options error:&error];
    
    if (result) {
        [self log:@"✅ Instalado com sucesso!"];
        return YES;
    } else {
        [self log:[NSString stringWithFormat:@"❌ Erro: %@", error.localizedDescription ?: @"desconhecido"]];
        return NO;
    }
}

// ============================================================
// Alerta
// ============================================================
- (void)showAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
