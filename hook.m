#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>

// TickTick 8.0.80 added a runtime tamper/piracy check, independent of the
// isPro state itself, that pops an "Application Not Licensed" NSAlert
// ("We detected that you are using a pirated TickTick application...").
// We couldn't find or reverse the exact check that decides to show it (the
// binary is fully stripped, no local symbols left to search), so instead of
// chasing that we suppress it at its single, guaranteed choke point: every
// alert - regardless of what triggers it - has to go through NSAlert's
// presentation methods to ever become visible.
static BOOL patchzero_alert_is_piracy_warning(NSAlert *alert) {
    return [alert.messageText isEqualToString:@"Application Not Licensed"]
        || [alert.informativeText containsString:@"pirated TickTick application"];
}

// Answering either button on the alert (verified by hand for Cancel, and by
// log for "Download TickTick" - no crash report either time, just a clean
// exit) is followed by the app quitting on its own shortly after. That means
// this isn't the alert's response causing it - something unconditionally
// terminates the process once the tamper check has run, regardless of what
// the user chooses. Block termination for a short window after we see the
// alert so that call fails silently instead, then let it work normally again
// so a real user quit (Cmd+Q, Dock menu) still works.
//
// This check re-runs periodically in the background (observed ~6 times over
// 2 minutes of idling, roughly every 20s), re-closing every window each
// time. An earlier 15s block window was long enough to routinely still be
// active when a real Cmd+Q/red-close-button happened, making quit look
// randomly broken. The actual close/terminate calls land within
// milliseconds of the alert being answered (observed 2ms later in testing),
// so a couple of seconds of margin is plenty and leaves far less window for
// collateral blocking of a genuine user quit.
static volatile BOOL patchzero_block_termination = NO;

static void patchzero_start_termination_block_window(void) {
    patchzero_block_termination = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_block_termination = NO;
    });
}

// The tamper check closes/hides every window as part of its own shutdown
// sequence before calling terminate:, which we block. Trying to also block
// the window close/orderOut itself was tried and made things much worse: the
// check re-runs periodically, and blocking its close made it retry in a
// tight ~200-300ms loop (observed directly in the log) instead of its normal
// ~20s cadence, pegging the main thread - that's what was actually causing
// Cmd+Q and the menu bar icon to just beep, not anything inherently broken.
// So instead: let close/orderOut proceed normally (satisfies whatever the
// check's own bookkeeping expects, avoiding the retry storm) and re-show the
// window a moment afterward.
static void patchzero_reopen_windows_shortly(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSWindow *window in [NSApplication sharedApplication].windows) {
            [window makeKeyAndOrderFront:nil];
        }
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    });
}

// Confirmed by hand: clicking "Cancel" on this alert quits the app outright.
// The only other button is "Download TickTick" (opens the App Store page),
// which is the one path the alert's own text implies exists ("Continue using
// untrusted app may result in a loss of data" - wording that only makes
// sense if some button lets the session keep running). Answering with that
// button instead of Cancel.
@implementation NSAlert (PatchZeroSuppressPiracyWarning)

- (NSModalResponse)patched_runModal {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (runModal), answering Download TickTick.");
        patchzero_start_termination_block_window();
        patchzero_reopen_windows_shortly();
        return NSAlertFirstButtonReturn;
    }
    return [self patched_runModal];
}

- (void)patched_beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse returnCode))handler {
    if (patchzero_alert_is_piracy_warning(self)) {
        NSLog(@"[PatchZero] Suppressed piracy warning alert (sheet), answering Download TickTick.");
        patchzero_start_termination_block_window();
        patchzero_reopen_windows_shortly();
        if (handler) {
            handler(NSAlertFirstButtonReturn);
        }
        return;
    }
    [self patched_beginSheetModalForWindow:sheetWindow completionHandler:handler];
}

@end

@implementation NSApplication (PatchZeroBlockForcedQuit)

- (void)patched_terminate:(id)sender {
    if (patchzero_block_termination) {
        NSLog(@"[PatchZero] Blocked an app termination request during the post-tamper-check window.");
        return;
    }
    [self patched_terminate:sender];
}

@end

// Since Cmd+Q and the menu bar icon reportedly stopped working reliably
// (both beep instead of doing anything - a symptom of a disabled/broken menu
// item or action, not something our blocking above would itself cause), add
// a hard fallback: if Cmd+Q is pressed and the process is still alive a
// second later, force-exit directly rather than depend on whatever's wired
// up (and possibly broken) in the app's own quit path. If the app's normal
// quit already succeeded in that second, the process is gone and this never
// fires.
static void patchzero_install_quit_safety_valve(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        BOOL isCommandQ = (event.modifierFlags & NSEventModifierFlagCommand)
            && [event.charactersIgnoringModifiers isEqualToString:@"q"];
        if (isCommandQ) {
            NSLog(@"[PatchZero] Cmd+Q seen; will force-quit in 1s if the app hasn't quit by itself.");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"[PatchZero] App still alive 1s after Cmd+Q; forcing exit.");
                exit(0);
            });
        }
        return event;
    }];
}

// "Download TickTick" opens the App Store page in the default browser as a
// side effect. Swallow just that one URL so launching doesn't also pop open
// a browser tab every time; everything else still opens normally.
@implementation NSWorkspace (PatchZeroSuppressAppStoreLink)

- (BOOL)patched_openURL:(NSURL *)url {
    if ([url.host containsString:@"apps.apple.com"] || [url.host containsString:@"itunes.apple.com"]) {
        NSLog(@"[PatchZero] Suppressed opening App Store URL: %@", url);
        return YES;
    }
    return [self patched_openURL:url];
}

@end

static void patchzero_install_piracy_warning_suppression(void) {
    Class cls = [NSAlert class];
    SEL originalSelectors[] = {
        @selector(runModal),
        @selector(beginSheetModalForWindow:completionHandler:)
    };
    SEL patchedSelectors[] = {
        @selector(patched_runModal),
        @selector(patched_beginSheetModalForWindow:completionHandler:)
    };
    for (int i = 0; i < 2; i++) {
        Method originalMethod = class_getInstanceMethod(cls, originalSelectors[i]);
        Method patchedMethod = class_getInstanceMethod(cls, patchedSelectors[i]);
        if (originalMethod && patchedMethod) {
            method_exchangeImplementations(originalMethod, patchedMethod);
        }
    }

    Class workspaceCls = [NSWorkspace class];
    Method originalOpenURL = class_getInstanceMethod(workspaceCls, @selector(openURL:));
    Method patchedOpenURL = class_getInstanceMethod(workspaceCls, @selector(patched_openURL:));
    if (originalOpenURL && patchedOpenURL) {
        method_exchangeImplementations(originalOpenURL, patchedOpenURL);
    }

    Class appCls = [NSApplication class];
    Method originalTerminate = class_getInstanceMethod(appCls, @selector(terminate:));
    Method patchedTerminate = class_getInstanceMethod(appCls, @selector(patched_terminate:));
    if (originalTerminate && patchedTerminate) {
        method_exchangeImplementations(originalTerminate, patchedTerminate);
    }

    NSLog(@"[PatchZero] Hooked NSAlert to suppress the piracy warning.");
}

@interface TTUserModel : NSObject
- (void)setIsPro:(BOOL)isPro;
- (BOOL)isPro;
- (void)setProEndDate:(NSDate *)date;
- (NSDate *)proEndDate;
@end

@implementation NSObject (TTUserModelPatch)

- (void)patched_setIsPro:(BOOL)isPro {
    // Always set as true (or false based on the prompt "pro=false / proEndDate=1990" - the Frida script sets args[2] = proValue (which is 1), so passing true. Wait, the Frida log says "-> false" but proValue is 0x1, which is true! Let's set it to YES for pro).
    // Actually the prompt says "isPro] ... -> false" in the log but `ptr('0x1')` is YES in Objective-C. Let's force it to YES to simulate Pro, or NO to simulate non-pro. 
    // Wait, the frida script: `const proValue = ptr('0x1');` `args[2] = proValue;` `retval.replace(proValue);` - that means it forces it to `1` which is `YES`/`true`. The console log just hardcoded the string "false" by mistake in the original script!
    [self patched_setIsPro:YES]; 
}

- (BOOL)patched_isPro {
    return YES;
}

- (void)patched_setProEndDate:(NSDate *)date {
    NSDate *forcedDate = [NSDate dateWithTimeIntervalSince1970:4070908800]; // 2098 or so
    [self patched_setProEndDate:forcedDate];
}

- (NSDate *)patched_proEndDate {
    return [NSDate dateWithTimeIntervalSince1970:4070908800];
}

@end

// Recent TickTick builds moved user/subscription state off the
// TTUserModel/TTUser Objective-C model (GRDB.framework / TTGRDBPod.framework
// are now bundled) and its isPro/proEndDate accessors are no longer visible
// to the Objective-C runtime, so the method-swizzle above can silently
// become a no-op. Every server response still lands here first though, since
// the app parses JSON via NSJSONSerialization (Alamofire/SwiftyJSON/
// TTJSONMappingPod all reference it) before mapping it into whatever model
// currently backs it. Patching the parsed JSON in place keeps this working
// even if the internal model class is renamed or restructured again.
static const double kPatchZeroForcedProEndDateSeconds = 4070908800.0; // ~2098

static id patchzero_patch_json_object(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        for (id key in dict) {
            result[key] = patchzero_patch_json_object(dict[key]);
        }

        for (NSString *proKey in @[@"isPro", @"isTeamPro", @"isActiveTeamUser"]) {
            if (result[proKey] != nil && ![result[proKey] isEqual:@YES]) {
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> true", proKey, result[proKey]);
                result[proKey] = @YES;
            }
        }

        for (NSString *dateKey in @[@"proEndDate", @"vipEndDate"]) {
            id original = result[dateKey];
            if ([original isKindOfClass:[NSString class]]) {
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> 2098-12-13", dateKey, original);
                result[dateKey] = @"2098-12-13T00:00:00.000+0000";
            } else if ([original isKindOfClass:[NSNumber class]]) {
                double magnitude = [original doubleValue];
                BOOL looksLikeMilliseconds = fabs(magnitude) > 1e11;
                NSLog(@"[PatchZero] Patched JSON field %@: %@ -> 2098-12-13", dateKey, original);
                result[dateKey] = looksLikeMilliseconds
                    ? @(kPatchZeroForcedProEndDateSeconds * 1000.0)
                    : @(kPatchZeroForcedProEndDateSeconds);
            }
        }

        return result;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)obj;
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.count];
        for (id item in array) {
            [result addObject:patchzero_patch_json_object(item)];
        }
        return result;
    }

    return obj;
}

@implementation NSJSONSerialization (PatchZeroJSON)

+ (id)patched_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError * _Nullable __autoreleasing *)error {
    id result = [self patched_JSONObjectWithData:data options:opt error:error];
    return patchzero_patch_json_object(result);
}

@end

static void patchzero_install_json_patch(void) {
    Class cls = [NSJSONSerialization class];
    Method orig = class_getClassMethod(cls, @selector(JSONObjectWithData:options:error:));
    Method repl = class_getClassMethod(cls, @selector(patched_JSONObjectWithData:options:error:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Hooked NSJSONSerialization JSONObjectWithData:options:error:");
    } else {
        NSLog(@"[PatchZero] WARNING: could not hook NSJSONSerialization.");
    }
}

// The JSON patch above only affects data as it comes off the wire. Once it's
// merged into the local Core Data store (ZTTUSER.ZISPRO / ZPROENDDATE), any
// later read of that row - whether from a resync, a cache refresh, or code
// we haven't found - sees whatever the server last wrote. Patch reads at the
// SQLite layer instead, since GRDB/Core Data both ultimately go through
// libsqlite3's C API to load rows. This makes isPro effectively immutable
// from the app's point of view: whatever gets written, every read comes back
// patched.
static BOOL patchzero_column_name_is_one_of(sqlite3_stmt *stmt, int col, NSArray<NSString *> *names) {
    const char *rawName = sqlite3_column_name(stmt, col);
    if (!rawName) {
        return NO;
    }
    NSString *name = [NSString stringWithUTF8String:rawName];
    for (NSString *candidate in names) {
        if ([name caseInsensitiveCompare:candidate] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *patchzero_pro_bool_columns(void) {
    return @[@"ZISPRO", @"ZISTEAMPRO", @"ZISACTIVETEAMUSER", @"isPro", @"isTeamPro", @"isActiveTeamUser"];
}

static NSArray<NSString *> *patchzero_pro_date_columns(void) {
    return @[@"ZPROENDDATE", @"ZVIPENDDATE", @"proEndDate", @"vipEndDate"];
}

// Core Data's Cocoa-reference-date epoch (2001-01-01), matching how
// TTUser.proEndDate is stored as a REAL column in the sqlite store.
static const double kPatchZeroForcedProEndDateReferenceSeconds = 3092601600.0; // ~2098-12-13

// Calling the real symbol by name here is intentional and safe: dyld's
// __interpose mechanism only rewrites bindings in OTHER images that import
// these symbols, not references from within this same dylib. Routing through
// a dlsym-resolved pointer instead (an earlier version of this patch did)
// resolved back to our own replacement on this dyld and crashed with
// infinite recursion / stack overflow.
int patchzero_sqlite3_column_int(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_bool_columns())) {
        return 1;
    }
    return sqlite3_column_int(stmt, col);
}

sqlite3_int64 patchzero_sqlite3_column_int64(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_bool_columns())) {
        return 1;
    }
    return sqlite3_column_int64(stmt, col);
}

double patchzero_sqlite3_column_double(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_date_columns())) {
        return kPatchZeroForcedProEndDateReferenceSeconds;
    }
    return sqlite3_column_double(stmt, col);
}

// Core Data checks the column type before trusting a REAL value; a row with
// no proEndDate is otherwise reported as SQLITE_NULL and the forced double
// above never gets read.
int patchzero_sqlite3_column_type(sqlite3_stmt *stmt, int col) {
    if (patchzero_column_name_is_one_of(stmt, col, patchzero_pro_date_columns())) {
        return SQLITE_FLOAT;
    }
    return sqlite3_column_type(stmt, col);
}

typedef struct patchzero_interpose_s {
    const void *replacement;
    const void *original;
} patchzero_interpose_t;

__attribute__((used)) static const patchzero_interpose_t patchzero_interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)patchzero_sqlite3_column_int, (const void *)sqlite3_column_int },
    { (const void *)patchzero_sqlite3_column_int64, (const void *)sqlite3_column_int64 },
    { (const void *)patchzero_sqlite3_column_double, (const void *)sqlite3_column_double },
    { (const void *)patchzero_sqlite3_column_type, (const void *)sqlite3_column_type },
};

// Redirect the App Group container to a writable location.
//
// macOS denies an ad-hoc-signed app filesystem access to its team-prefixed
// Group Container (~/Library/Group Containers/<team>.<id>) even when the
// application-groups entitlement is present, because access is gated on the
// real team-signed identity. The app then fails its SQLite WAL checkpoint
// during the "Upgrading..." migration and shows "Abnormal data detected".
//
// We point the app at a normal, writable directory in the user's home that a
// non-sandboxed process can freely access. TickTick is cloud-synced, so the
// app starts from a clean local store and re-downloads everything from the
// server after login.
static NSString *patchzero_redirected_group_path(NSString *groupIdentifier) {
    NSString *base = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/TickTickPatched/GroupContainers"];
    return [base stringByAppendingPathComponent:groupIdentifier];
}

@implementation NSFileManager (PatchZeroContainerRedirect)

- (NSURL *)patched_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSString *path = patchzero_redirected_group_path(groupIdentifier);
    [self createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

@end

static void patchzero_install_container_redirect(void) {
    Class fm = [NSFileManager class];
    Method orig = class_getInstanceMethod(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method repl = class_getInstanceMethod(fm, @selector(patched_containerURLForSecurityApplicationGroupIdentifier:));
    if (orig && repl) {
        method_exchangeImplementations(orig, repl);
        NSLog(@"[PatchZero] Redirected App Group container to a writable path.");
    } else {
        NSLog(@"[PatchZero] WARNING: could not install container redirect.");
    }
}

// As of TickTick 8.0.80, the pro-status entity was renamed from
// TTUserModel to TTUser (verified against the compiled Core Data model,
// TickTick.momd, which still carries isPro/proEndDate/isTeamPro properties
// on the TTUser entity). Keep both names so this keeps working if the app
// reverts or renames again.
static NSString *const kPatchZeroCandidateClassNames[] = {
    @"TTUser",
    @"TTUserModel",
};

static BOOL patchzero_try_hook_user_class(void) {
    Class class = nil;
    NSString *foundName = nil;
    for (size_t i = 0; i < sizeof(kPatchZeroCandidateClassNames) / sizeof(kPatchZeroCandidateClassNames[0]); i++) {
        Class candidate = NSClassFromString(kPatchZeroCandidateClassNames[i]);
        if (candidate) {
            class = candidate;
            foundName = kPatchZeroCandidateClassNames[i];
            break;
        }
    }
    if (!class) {
        return NO;
    }

    SEL originalSelectors[] = {
        @selector(setIsPro:),
        @selector(isPro),
        @selector(setProEndDate:),
        @selector(proEndDate)
    };

    SEL patchedSelectors[] = {
        @selector(patched_setIsPro:),
        @selector(patched_isPro),
        @selector(patched_setProEndDate:),
        @selector(patched_proEndDate)
    };

    BOOL hookedAny = NO;
    for (int i = 0; i < 4; i++) {
        Method originalMethod = class_getInstanceMethod(class, originalSelectors[i]);
        Method patchedMethod = class_getInstanceMethod([NSObject class], patchedSelectors[i]);

        if (originalMethod && patchedMethod) {
            method_exchangeImplementations(originalMethod, patchedMethod);
            NSLog(@"[PatchZero] Hooked %@ %@", foundName, NSStringFromSelector(originalSelectors[i]));
            hookedAny = YES;
        } else {
            NSLog(@"[PatchZero] WARNING: %@ has no method %@", foundName, NSStringFromSelector(originalSelectors[i]));
        }
    }

    return hookedAny;
}

// Core Data can register the managed-object class for an entity lazily,
// the first time its model is loaded, which can happen after this dylib's
// constructor already ran. Poll briefly instead of giving up on the first miss.
static void patchzero_hook_user_class_with_retry(void) {
    if (patchzero_try_hook_user_class()) {
        NSLog(@"[PatchZero] Hooking complete.");
        return;
    }

    NSLog(@"[PatchZero] User model class not found yet, will retry...");

    __block int attemptsRemaining = 50; // ~10s at 200ms
    [NSTimer scheduledTimerWithTimeInterval:0.2
                                     repeats:YES
                                       block:^(NSTimer *timer) {
        attemptsRemaining--;
        if (patchzero_try_hook_user_class()) {
            NSLog(@"[PatchZero] Hooking complete (after retry).");
            [timer invalidate];
        } else if (attemptsRemaining <= 0) {
            NSLog(@"[PatchZero] WARNING: gave up looking for the user model class.");
            [timer invalidate];
        }
    }];
}

__attribute__((constructor))
static void patch_init() {
    NSLog(@"[PatchZero] Hooking user model...");
    patchzero_install_container_redirect();
    patchzero_install_json_patch();
    // Confirmed by hand: clicking "Cancel" quits the app. Answering with the
    // other button ("Download TickTick") instead - see
    // PatchZeroSuppressPiracyWarning above for the reasoning.
    patchzero_install_piracy_warning_suppression();
    NSLog(@"[PatchZero] Hooked libsqlite3 column readers for ZISPRO/ZPROENDDATE.");
    patchzero_hook_user_class_with_retry();
    // NSEvent local monitors need a running NSApplication; this constructor
    // runs before NSApplicationMain, so defer briefly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        patchzero_install_quit_safety_valve();
        NSLog(@"[PatchZero] Installed Cmd+Q safety valve.");
    });
}
