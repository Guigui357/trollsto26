// sto26_simple.m – Extrai IPA sem libz, sem unzip
// Compilar: clang -arch arm64 -framework UIKit -framework Foundation -framework MobileCoreServices -o sto26 sto26_simple.m

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <spawn.h>
#import <sys/stat.h>

extern char **environ;

// ============================================================
// EXTRAÇÃO SIMPLES (usa NSFileManager + NSData)
// ============================================================
@interface STO26 : NSObject
+ (BOOL)install:(NSString *)ipaPath;
+ (BOOL)extractIPA:(NSString *)ipaPath toDir:(NSString *)destDir;
@end

@implementation STO26

+ (BOOL)extractIPA:(NSString *)ipaPath toDir:(NSString *)destDir {
    // Método 1: Tentar renomear para .zip e extrair (se o sistema tiver unzip)
    NSString *zipPath = [destDir stringByAppendingPathComponent:@"temp.zip"];
    [[NSFileManager defaultManager] copyItemAtPath:ipaPath toPath:zipPath error:nil];
    
    pid_t pid;
    char *argv[] = {
        "/usr/bin/unzip",
        "-q",
        (char *)[zipPath UTF8String],
        "-d",
        (char *)[destDir UTF8String],
        NULL
    };
    int status = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    if (status == 0) {
        waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
            return YES;
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    
    // Método 2: Tentar extrair manualmente (apenas para arquivos não comprimidos)
    // Lê o IPA como NSData e procura o cabeçalho ZIP
    NSData *data = [NSData dataWithContentsOfFile:ipaPath];
    if (!data) return NO;
    
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    
    // Procurar assinatura de diretório central (EOCD: 0x06054b50)
    NSUInteger eocdPos = 0;
    for (NSUInteger i = length - 22; i > 0; i--) {
        if (i + 4 > length) continue;
        if (bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
            eocdPos = i;
            break;
        }
    }
    if (eocdPos == 0) {
        NSLog(@"[sto26] ❌ EOCD não encontrado.");
        return NO;
    }
    
    // Ler offset do diretório central
    uint32_t cdOffset = 0;
    memcpy(&cdOffset, bytes + eocdPos + 16, 4);
    
    // Percorrer diretório central
    NSUInteger pos = cdOffset;
    while (pos < length) {
        if (pos + 4 > length) break;
        uint32_t sig;
        memcpy(&sig, bytes + pos, 4);
        if (sig != 0x02014b50) break;
        
        uint16_t nameLen, extraLen, commentLen;
        uint32_t compSize, uncompSize, localHeaderOffset;
        uint16_t compression;
        
        memcpy(&compression, bytes + pos + 10, 2);
        memcpy(&compSize, bytes + pos + 20, 4);
        memcpy(&uncompSize, bytes + pos + 24, 4);
        memcpy(&nameLen, bytes + pos + 28, 2);
        memcpy(&extraLen, bytes + pos + 30, 2);
        memcpy(&commentLen, bytes + pos + 32, 2);
        memcpy(&localHeaderOffset, bytes + pos + 42, 4);
        
        char *name = malloc(nameLen + 1);
        memcpy(name, bytes + pos + 46, nameLen);
        name[nameLen] = 0;
        NSString *fileName = [NSString stringWithUTF8String:name];
        free(name);
        
        pos += 46 + nameLen + extraLen + commentLen;
        
        if ([fileName hasSuffix:@"/"]) continue;
        if ([fileName hasPrefix:@"__MACOSX"]) continue;
        if ([fileName hasPrefix:@".DS_Store"]) continue;
        
        // Ir para o local header
        NSUInteger localPos = localHeaderOffset;
        uint32_t localSig;
        memcpy(&localSig, bytes + localPos, 4);
        if (localSig != 0x04034b50) continue;
        
        uint16_t localNameLen, localExtraLen;
        memcpy(&localNameLen, bytes + localPos + 26, 2);
        memcpy(&localExtraLen, bytes + localPos + 28, 2);
        localPos += 30 + localNameLen + localExtraLen;
        
        // Se não for comprimido (compression == 0), copiar diretamente
        if (compression == 0 && compSize > 0) {
            NSString *destPath = [destDir stringByAppendingPathComponent:fileName];
            NSString *parentDir = [destPath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSData *fileData = [NSData dataWithBytes:bytes + localPos length:compSize];
            [fileData writeToFile:destPath atomically:YES];
        }
    }
    
    return YES;
}

+ (BOOL)install:(NSString *)ipaPath {
    NSLog(@"[sto26] 📦 %@", ipaPath.lastPathComponent);
    
    // Diretório de extração
    NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extractDir = [docPath stringByAppendingPathComponent:@"ipa_extract"];
    [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Extrair
    if (![self extractIPA:ipaPath toDir:extractDir]) {
        NSLog(@"[sto26] ❌ Falha");
        return NO;
    }
    
    // Encontrar .app
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
        NSLog(@"[sto26] ❌ Nenhum .app");
        return NO;
    }
    
    // Tentar instalar
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        id ws = [cls performSelector:@selector(defaultWorkspace)];
        if (ws) {
            NSError *err = nil;
            if ([ws installApplication:[NSURL fileURLWithPath:appBundle] withOptions:@{@"AllowProvisioningDevice": @YES} error:&err]) {
                NSLog(@"[sto26] ✅ OK");
                return YES;
            }
        }
    }
    
    // Fallback
    NSString *dest = [@"/Applications/" stringByAppendingPathComponent:appBundle.lastPathComponent];
    if ([[NSFileManager defaultManager] copyItemAtPath:appBundle toPath:dest error:nil]) {
        NSLog(@"[sto26] ✅ OK (fallback)");
        return YES;
    }
    
    NSLog(@"[sto26] ❌ Falha");
    return NO;
}

@end

// ============================================================
// UI
// ============================================================
@interface ViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITextView *logView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"sto26";
    
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"📁 Selecionar IPA" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(pickIPA) forControlEvents:UIControlEventTouchUpInside];
    btn.frame = CGRectMake(20, 100, self.view.bounds.size.width - 40, 50);
    [self.view addSubview:btn];
    
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 170, self.view.bounds.size.width - 40, 400)];
    self.logView.editable = NO;
    self.logView.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:self.logView];
    [self log:@"Pronto"];
}

- (void)log:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        self.logView.text = [self.logView.text stringByAppendingFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    });
}

- (void)pickIPA {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[(NSString *)kUTTypeItem]
        inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [self log:[NSString stringWithFormat:@"📦 %@", url.lastPathComponent]];
    BOOL ok = [STO26 install:url.path];
    [self log:ok ? @"✅ OK" : @"❌ Falha"];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self log:@"Cancelado"];
}

@end

// ============================================================
// APP DELEGATE
// ============================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[ViewController alloc] init]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
