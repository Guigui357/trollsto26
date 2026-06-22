p// sto26_debug.m – Extração ZIP com logs detalhados
// Compilar: clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -framework UIKit -framework Foundation -framework MobileCoreServices -lz -o sto26 sto26_debug.m

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <zlib.h>
#import <spawn.h>
#import <sys/stat.h>

extern char **environ;

// ============================================================
// LSApplicationWorkspace (API privada)
// ============================================================
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)bundleURL withOptions:(NSDictionary *)options error:(NSError **)error;
@end

// ============================================================
// EXTRAÇÃO ZIP MANUAL (com logs)
// ============================================================
BOOL extractZipManual(NSString *zipPath, NSString *destDir) {
    NSLog(@"[sto26] 🔍 Lendo arquivo: %@", zipPath);
    NSData *data = [NSData dataWithContentsOfFile:zipPath];
    if (!data) {
        NSLog(@"[sto26] ❌ Não foi possível ler o arquivo");
        return NO;
    }
    NSLog(@"[sto26] 📏 Tamanho: %lu bytes", (unsigned long)data.length);
    
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    
    // Procurar EOCD
    NSUInteger eocdPos = 0;
    for (NSUInteger i = len - 22; i > 0; i--) {
        if (i + 4 > len) continue;
        if (bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
            eocdPos = i;
            break;
        }
    }
    if (eocdPos == 0) {
        NSLog(@"[sto26] ❌ EOCD não encontrado (arquivo não é um ZIP válido)");
        return NO;
    }
    NSLog(@"[sto26] ✅ EOCD encontrado em offset %lu", (unsigned long)eocdPos);
    
    uint32_t cdOffset = 0;
    memcpy(&cdOffset, bytes + eocdPos + 16, 4);
    NSLog(@"[sto26] 📂 Diretório central em offset %u", cdOffset);
    
    NSUInteger pos = cdOffset;
    int fileCount = 0;
    while (pos < len) {
        if (pos + 4 > len) break;
        uint32_t sig;
        memcpy(&sig, bytes + pos, 4);
        if (sig != 0x02014b50) break;
        
        uint16_t compression, nameLen, extraLen, commentLen;
        uint32_t compSize, uncompSize, localOffset;
        memcpy(&compression, bytes + pos + 10, 2);
        memcpy(&compSize, bytes + pos + 20, 4);
        memcpy(&uncompSize, bytes + pos + 24, 4);
        memcpy(&nameLen, bytes + pos + 28, 2);
        memcpy(&extraLen, bytes + pos + 30, 2);
        memcpy(&commentLen, bytes + pos + 32, 2);
        memcpy(&localOffset, bytes + pos + 42, 4);
        
        char *name = malloc(nameLen + 1);
        memcpy(name, bytes + pos + 46, nameLen);
        name[nameLen] = 0;
        NSString *fileName = [NSString stringWithUTF8String:name];
        free(name);
        
        pos += 46 + nameLen + extraLen + commentLen;
        
        // Pular arquivos indesejados
        if ([fileName hasSuffix:@"/"]) continue;
        if ([fileName hasPrefix:@"__MACOSX"]) continue;
        if ([fileName hasPrefix:@".DS_Store"]) continue;
        if ([fileName containsString:@".DS_Store"]) continue;
        
        fileCount++;
        if (fileCount % 100 == 0) {
            NSLog(@"[sto26] 📄 Processando %d arquivos...", fileCount);
        }
        
        // Ir para o local header
        NSUInteger localPos = localOffset;
        uint32_t localSig;
        memcpy(&localSig, bytes + localPos, 4);
        if (localSig != 0x04034b50) continue;
        
        uint16_t localNameLen, localExtraLen;
        memcpy(&localNameLen, bytes + localPos + 26, 2);
        memcpy(&localExtraLen, bytes + localPos + 28, 2);
        localPos += 30 + localNameLen + localExtraLen;
        
        NSString *destPath = [destDir stringByAppendingPathComponent:fileName];
        NSString *parentDir = [destPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        if (compression == 0) {
            // Store (sem compressão)
            if (compSize > 0) {
                NSData *fileData = [NSData dataWithBytes:bytes + localPos length:compSize];
                [fileData writeToFile:destPath atomically:YES];
            }
        } else if (compression == 8) {
            // Deflate
            if (uncompSize > 0 && compSize > 0) {
                z_stream stream;
                stream.zalloc = Z_NULL;
                stream.zfree = Z_NULL;
                stream.opaque = Z_NULL;
                inflateInit2(&stream, -MAX_WBITS);
                stream.next_in = (Bytef *)(bytes + localPos);
                stream.avail_in = compSize;
                uint8_t *out = malloc(uncompSize);
                stream.next_out = out;
                stream.avail_out = uncompSize;
                int ret = inflate(&stream, Z_FINISH);
                inflateEnd(&stream);
                if (ret == Z_STREAM_END) {
                    [[NSData dataWithBytes:out length:uncompSize] writeToFile:destPath atomically:YES];
                }
                free(out);
            }
        } else {
            NSLog(@"[sto26] ⚠️ Compressão não suportada: %u para %@", compression, fileName);
        }
    }
    NSLog(@"[sto26] ✅ Extração concluída (%d arquivos processados)", fileCount);
    return YES;
}

// ============================================================
// INSTALADOR
// ============================================================
@interface STO26 : NSObject
+ (BOOL)install:(NSString *)ipaPath;
@end

@implementation STO26

+ (BOOL)install:(NSString *)ipaPath {
    NSLog(@"[sto26] 📦 %@", ipaPath.lastPathComponent);
    
    NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extractDir = [docPath stringByAppendingPathComponent:@"ipa_extract"];
    [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Método 1: extração manual
    if (!extractZipManual(ipaPath, extractDir)) {
        // Método 2: unzip do sistema (fallback)
        NSLog(@"[sto26] 🔧 Tentando unzip do sistema...");
        pid_t pid;
        char *argv[] = {
            "/usr/bin/unzip",
            "-q",
            (char *)[ipaPath UTF8String],
            "-d",
            (char *)[extractDir UTF8String],
            NULL
        };
        int status = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
        if (status == 0) {
            waitpid(pid, &status, 0);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                NSLog(@"[sto26] ✅ unzip bem-sucedido");
            } else {
                NSLog(@"[sto26] ❌ unzip falhou com código %d", WEXITSTATUS(status));
                return NO;
            }
        } else {
            NSLog(@"[sto26] ❌ posix_spawn falhou: %d", status);
            return NO;
        }
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
        NSLog(@"[sto26] ❌ Nenhum .app encontrado em %@", payloadDir);
        return NO;
    }
    NSLog(@"[sto26] 📱 App: %@", appBundle.lastPathComponent);
    
    // Instalar via LSApplicationWorkspace (usando NSInvocation)
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        id ws = [cls performSelector:@selector(defaultWorkspace)];
        if (ws) {
            NSError *err = nil;
            NSURL *url = [NSURL fileURLWithPath:appBundle];
            NSDictionary *opts = @{@"AllowProvisioningDevice": @YES};
            SEL sel = NSSelectorFromString(@"installApplication:withOptions:error:");
            if ([ws respondsToSelector:sel]) {
                NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:ws];
                [inv setSelector:sel];
                [inv setArgument:&url atIndex:2];
                [inv setArgument:&opts atIndex:3];
                [inv setArgument:&err atIndex:4];
                [inv invoke];
                BOOL result = NO;
                [inv getReturnValue:&result];
                if (result) {
                    NSLog(@"[sto26] ✅ OK");
                    return YES;
                }
            }
        }
    }
    
    // Fallback: copiar para /Applications/
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
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[(NSString *)kUTTypeItem] asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
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
