// sto26_fixed.m – Document picker corrigido (sem crash)
// Compilar: clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -framework UIKit -framework Foundation -framework MobileCoreServices -lz -o sto26 sto26_fixed.m

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
// EXTRAÇÃO ZIP MANUAL (simplificada)
// ============================================================
BOOL extractZipManual(NSString *zipPath, NSString *destDir) {
    NSData *data = [NSData dataWithContentsOfFile:zipPath];
    if (!data) return NO;
    
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
    if (eocdPos == 0) return NO;
    
    uint32_t cdOffset = 0;
    memcpy(&cdOffset, bytes + eocdPos + 16, 4);
    
    NSUInteger pos = cdOffset;
    while (pos < len) {
        if (pos + 4 > len) break;
        uint32_t sig;
        memcpy(&sig, bytes + pos, 4);
        if (sig != 0x02014b50) break;
        
        uint16_t compression, nameLen, extraLen, commentLen;
        uint32_t compSize, localOffset;
        memcpy(&compression, bytes + pos + 10, 2);
        memcpy(&compSize, bytes + pos + 20, 4);
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
        
        if ([fileName hasSuffix:@"/"]) continue;
        if ([fileName hasPrefix:@"__MACOSX"]) continue;
        if ([fileName hasPrefix:@".DS_Store"]) continue;
        if ([fileName containsString:@".DS_Store"]) continue;
        
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
        
        if (compression == 0 && compSize > 0) {
            NSData *fileData = [NSData dataWithBytes:bytes + localPos length:compSize];
            [fileData writeToFile:destPath atomically:YES];
        }
    }
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
    
    if (!extractZipManual(ipaPath, extractDir)) {
        NSLog(@"[sto26] ❌ Falha na extração");
        return NO;
    }
    
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
    NSLog(@"[sto26] 📱 %@", appBundle.lastPathComponent);
    
    // LSApplicationWorkspace
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
// UI (corrigida para evitar crash)
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
    @try {
        // Usar API mais simples e compatível
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initWithDocumentTypes:@[@"public.item"]
            inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        picker.modalPresentationStyle = UIModalPresentationFullScreen;
        // Apresentar com atraso para garantir que a view esteja pronta
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:picker animated:YES completion:nil];
        });
    } @catch (NSException *exception) {
        [self log:[NSString stringWithFormat:@"❌ Erro: %@", exception.reason]];
    }
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
