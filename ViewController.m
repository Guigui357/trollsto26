// sto26_extract.m – Extrai IPA sem unzip (usando minizip embutido)
// Compilar: clang -arch arm64 -framework UIKit -framework Foundation -framework MobileCoreServices -lz -o sto26 sto26_extract.m

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <zlib.h>
#import <dlfcn.h>

extern char **environ;

// ============================================================
// MINIZIP EMBUTIDO (extração ZIP puro)
// ============================================================

typedef struct {
    void *stream;
    int total_in;
    int total_out;
} zlib_stream;

// Funções de extração ZIP (versão simplificada usando libz)
BOOL extractZip(const char *zipPath, const char *destDir) {
    // Abrir o arquivo ZIP
    FILE *file = fopen(zipPath, "rb");
    if (!file) return NO;
    
    // Localizar o diretório central (EOCD)
    fseek(file, -22, SEEK_END);
    uint32_t eocd = 0;
    fread(&eocd, 4, 1, file);
    if (eocd != 0x06054b50) { // EOCD signature
        fclose(file);
        return NO;
    }
    
    // Ler informações do EOCD
    uint16_t diskNum, diskStart, numEntries, totalEntries;
    uint32_t cdSize, cdOffset;
    uint16_t commentLen;
    fseek(file, -18, SEEK_CUR);
    fread(&diskNum, 2, 1, file);
    fread(&diskStart, 2, 1, file);
    fread(&numEntries, 2, 1, file);
    fread(&totalEntries, 2, 1, file);
    fread(&cdSize, 4, 1, file);
    fread(&cdOffset, 4, 1, file);
    fread(&commentLen, 2, 1, file);
    
    // Ir para o início do diretório central
    fseek(file, cdOffset, SEEK_SET);
    
    // Percorrer as entradas
    for (int i = 0; i < totalEntries; i++) {
        uint32_t sig;
        fread(&sig, 4, 1, file);
        if (sig != 0x02014b50) break; // Central directory signature
        
        uint16_t version, needVer, flags, compression, modTime, modDate;
        uint32_t crc32, compSize, uncompSize;
        uint16_t nameLen, extraLen, commentLen2, diskNum2, intAttr;
        uint32_t extAttr, localHeaderOffset;
        
        fseek(file, 2, SEEK_CUR); // skip version made by
        fread(&needVer, 2, 1, file);
        fread(&flags, 2, 1, file);
        fread(&compression, 2, 1, file);
        fread(&modTime, 2, 1, file);
        fread(&modDate, 2, 1, file);
        fread(&crc32, 4, 1, file);
        fread(&compSize, 4, 1, file);
        fread(&uncompSize, 4, 1, file);
        fread(&nameLen, 2, 1, file);
        fread(&extraLen, 2, 1, file);
        fread(&commentLen2, 2, 1, file);
        fseek(file, 4, SEEK_CUR); // skip disk number, internal attr
        fread(&extAttr, 4, 1, file);
        fread(&localHeaderOffset, 4, 1, file);
        
        // Ler nome do arquivo
        char *name = malloc(nameLen + 1);
        fread(name, 1, nameLen, file);
        name[nameLen] = 0;
        NSString *fileName = [NSString stringWithUTF8String:name];
        free(name);
        
        // Pular extra e comentário
        fseek(file, extraLen + commentLen2, SEEK_CUR);
        
        // Se for um arquivo (não diretório) e não começar com "__MACOSX" ou ".DS_Store"
        if (![fileName hasPrefix:@"__MACOSX"] && ![fileName hasPrefix:@".DS_Store"] && ![fileName hasSuffix:@"/"]) {
            // Ir para o local header
            fseek(file, localHeaderOffset, SEEK_SET);
            uint32_t localSig;
            fread(&localSig, 4, 1, file);
            if (localSig == 0x04034b50) {
                fseek(file, 16, SEEK_CUR); // skip version, flags, compression, etc.
                uint16_t localNameLen, localExtraLen;
                fread(&localNameLen, 2, 1, file);
                fread(&localExtraLen, 2, 1, file);
                fseek(file, localNameLen + localExtraLen, SEEK_CUR);
                
                // Ler dados do arquivo (se não estiver armazenado)
                uint8_t *data = malloc(compSize);
                fread(data, 1, compSize, file);
                
                // Descomprimir se necessário (apenas armazenado ou deflate)
                if (compression == 0) {
                    // Armazenado sem compressão
                    NSString *destPath = [NSString stringWithFormat:@"%s/%s", destDir, name];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[destPath stringByDeletingLastPathComponent]
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                    [[NSData dataWithBytes:data length:compSize] writeToFile:destPath atomically:YES];
                } else if (compression == 8) {
                    // Deflate - descomprimir com zlib
                    z_stream stream;
                    stream.zalloc = Z_NULL;
                    stream.zfree = Z_NULL;
                    stream.opaque = Z_NULL;
                    inflateInit2(&stream, -MAX_WBITS);
                    
                    stream.next_in = data;
                    stream.avail_in = compSize;
                    
                    uint8_t *out = malloc(uncompSize + 1);
                    stream.next_out = out;
                    stream.avail_out = uncompSize;
                    
                    inflate(&stream, Z_FINISH);
                    inflateEnd(&stream);
                    
                    NSString *destPath = [NSString stringWithFormat:@"%s/%s", destDir, name];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[destPath stringByDeletingLastPathComponent]
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                    [[NSData dataWithBytes:out length:uncompSize] writeToFile:destPath atomically:YES];
                    free(out);
                }
                free(data);
            }
        }
    }
    
    fclose(file);
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
    NSLog(@"[sto26] 📦 Instalando: %@", ipaPath);
    
    // 1. Diretório de extração
    NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extractDir = [docPath stringByAppendingPathComponent:@"ipa_extract"];
    [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    // 2. Extrair com minizip embutido
    BOOL ok = extractZip([ipaPath UTF8String], [extractDir UTF8String]);
    if (!ok) {
        // Fallback: tentar com NSData + zip (simples)
        NSData *zipData = [NSData dataWithContentsOfFile:ipaPath];
        if (!zipData) return NO;
        // Tentar ler usando NSFileManager diretamente (apenas para arquivos não comprimidos)
        // ...
        NSLog(@"[sto26] ❌ Falha na extração.");
        return NO;
    }
    NSLog(@"[sto26] ✅ Extração concluída.");
    
    // 3. Encontrar .app
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
        NSLog(@"[sto26] ❌ Nenhum .app encontrado.");
        return NO;
    }
    NSLog(@"[sto26] 📱 App: %@", appBundle.lastPathComponent);
    
    // 4. Instalar via LSApplicationWorkspace (ou copiar)
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        id ws = [cls performSelector:@selector(defaultWorkspace)];
        if (ws) {
            NSError *err = nil;
            NSURL *url = [NSURL fileURLWithPath:appBundle];
            if ([ws installApplication:url withOptions:@{@"AllowProvisioningDevice": @YES} error:&err]) {
                NSLog(@"[sto26] ✅ Instalado!");
                return YES;
            }
        }
    }
    
    // Fallback: copiar para /Applications/
    NSString *dest = [@"/Applications/" stringByAppendingPathComponent:appBundle.lastPathComponent];
    if ([[NSFileManager defaultManager] copyItemAtPath:appBundle toPath:dest error:nil]) {
        NSLog(@"[sto26] ✅ Copiado para /Applications/");
        return YES;
    }
    
    return NO;
}

@end

// ============================================================
// UI (simplificada)
// ============================================================
@interface ViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITextView *log;
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
    self.log = [[UITextView alloc] initWithFrame:CGRectMake(20, 170, self.view.bounds.size.width - 40, 400)];
    self.log.editable = NO;
    self.log.font = [UIFont systemFontOfSize:12];
    [self.view addSubview:self.log];
}

- (void)logMsg:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [self.log.text stringByAppendingFormat:@"[%@] %@\n",
                         [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle],
                         msg];
        [self.log scrollRangeToVisible:NSMakeRange(self.log.text.length - 1, 1)];
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
    [self logMsg:[NSString stringWithFormat:@"📦 %@", url.lastPathComponent]];
    BOOL ok = [STO26 install:url.path];
    [self logMsg:ok ? @"✅ OK" : @"❌ Falha"];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self logMsg:@"Cancelado"];
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
