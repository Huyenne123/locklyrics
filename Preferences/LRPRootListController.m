#import "LRPRootListController.h"
#import "LRPLockScreenPreviewCell.h"
#import <notify.h>
#import <dirent.h>
#import <unistd.h>
#import <string.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#if __has_include(<roothide/roothide.h>)
#import <roothide/roothide.h>
#endif

static void loadAltListFramework(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"ATLApplicationListMultiSelectionController")) {
            return;
        }

        const char *candidates[] = {
#if __has_include(<roothide/roothide.h>)
            jbroot("/Library/Frameworks/AltList.framework/AltList"),
            jbroot("/usr/lib/AltList.dylib"),
            jbroot("/Library/PreferenceBundles/AltList.bundle/AltList"),
#endif
            "/var/jb/Library/Frameworks/AltList.framework/AltList",
            "/Library/Frameworks/AltList.framework/AltList",
            "/var/jb/usr/lib/AltList.dylib",
            "/usr/lib/AltList.dylib",
            "/var/jb/Library/PreferenceBundles/AltList.bundle/AltList",
            "/Library/PreferenceBundles/AltList.bundle/AltList"
        };

        for (size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
            const char *p = candidates[i];
            if (p && access(p, F_OK) == 0) {
                dlopen(p, RTLD_NOW | RTLD_GLOBAL);
                if (NSClassFromString(@"ATLApplicationListMultiSelectionController")) {
                    return;
                }
            }
        }

        // Also search NSBundle in case installed as a bundle/framework
        for (NSBundle *bundle in [NSBundle allFrameworks]) {
            if ([bundle.bundleIdentifier isEqualToString:@"com.opa334.altlist"]) {
                [bundle load];
                break;
            }
        }
    });
}

static void clearLyricsCacheFiles(void) {
    const char *dirPath = "/var/mobile/Library/LockLyrics/Lyrics";
    DIR *d = opendir(dirPath);
    if (!d) return;
    struct dirent *dir;
    while ((dir = readdir(d)) != NULL) {
        if (strcmp(dir->d_name, ".") == 0 || strcmp(dir->d_name, "..") == 0) continue;
        char filePath[512];
        snprintf(filePath, sizeof(filePath), "%s/%s", dirPath, dir->d_name);
        unlink(filePath);
    }
    closedir(d);
}

@interface LRPRootListController () <LRPLockScreenPreviewCellDelegate>
@property (nonatomic, weak) LRPLockScreenPreviewCell *previewCell;
@end

@implementation LRPRootListController

+ (void)initialize {
    if (self == [LRPRootListController class]) {
        loadAltListFramework();
    }
}

- (void)viewDidLoad {
    loadAltListFramework();
    [super viewDidLoad];
}

- (void)previewCellDidChangePosition:(LRPLockScreenPreviewCell *)cell {
    [self reloadSpecifierID:[NSString stringWithUTF8String:"alignmentPreset"] animated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    loadAltListFramework();
    [super viewWillAppear:animated];
    [self.previewCell refreshFromPreferencesAnimated:NO];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        loadAltListFramework();
        NSMutableArray *loadedSpecifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];

        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.locklyrics.preferences");
        CFPropertyListRef modeVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"appFilterMode", (__bridge CFStringRef)@"com.locklyrics.preferences");
        NSInteger mode = 0;
        if (modeVal && CFGetTypeID(modeVal) == CFNumberGetTypeID()) {
            mode = [(__bridge NSNumber *)modeVal integerValue];
            CFRelease(modeVal);
        }

        NSString *specifierToRemove = (mode == 0) ? @"customBlacklistApps" : @"customWhitelistApps";
        for (PSSpecifier *spec in [loadedSpecifiers copy]) {
            NSString *specId = [spec propertyForKey:@"id"];
            if ([specId isEqualToString:specifierToRemove]) {
                [loadedSpecifiers removeObject:spec];
            }
        }

        // Ensure detailControllerClass is attached to the AltList specifiers
        Class altClass = NSClassFromString(@"ATLApplicationListMultiSelectionController");
        if (altClass) {
            for (PSSpecifier *spec in loadedSpecifiers) {
                NSString *detail = [spec propertyForKey:@"detail"];
                if ([detail isEqualToString:@"ATLApplicationListMultiSelectionController"]) {
                    spec.detailControllerClass = altClass;
                }
            }
        }

        _specifiers = [loadedSpecifiers copy];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"appFilterMode"]) {
        [self reloadSpecifiers];
    } else if ([key isEqualToString:@"alignmentPreset"] ||
               [key isEqualToString:@"visibleLinesCount"] ||
               [key isEqualToString:@"fontSize"] ||
               [key isEqualToString:@"autoFontSize"]) {
        [self.previewCell refreshFromPreferencesAnimated:YES];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[LRPLockScreenPreviewCell class]]) {
        LRPLockScreenPreviewCell *preview = (LRPLockScreenPreviewCell *)cell;
        preview.delegate = self;
        self.previewCell = preview;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (specifier) {
        NSString *specId = [specifier propertyForKey:@"id"];
        if ([specId isEqualToString:@"lockScreenPreviewCell"]) {
            return 444.0;
        }
    }
    return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (specifier) {
        NSString *detail = [specifier propertyForKey:@"detail"];
        if ([detail isEqualToString:@"ATLApplicationListMultiSelectionController"] ||
            [NSStringFromClass(specifier.detailControllerClass) isEqualToString:@"ATLApplicationListMultiSelectionController"]) {
            loadAltListFramework();
            Class altClass = NSClassFromString(@"ATLApplicationListMultiSelectionController");
            if (!altClass) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AltList Required"
                                                                               message:@"Please install 'AltList' from your package manager (Sileo / Zebra) to select apps."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            } else {
                specifier.detailControllerClass = altClass;
            }
        }
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)resetPosition {
    CFPreferencesSetAppValue((__bridge CFStringRef)@"customCenterX", (__bridge CFNumberRef)@(-1.0), (__bridge CFStringRef)@"com.locklyrics.preferences");
    CFPreferencesSetAppValue((__bridge CFStringRef)@"customCenterY", (__bridge CFNumberRef)@(-1.0), (__bridge CFStringRef)@"com.locklyrics.preferences");
    CFPreferencesSetAppValue((__bridge CFStringRef)@"alignmentPreset", (__bridge CFNumberRef)@(0), (__bridge CFStringRef)@"com.locklyrics.preferences");
    CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.locklyrics.preferences");

    notify_post("com.locklyrics.preferences.changed");

    [self reloadSpecifierID:[NSString stringWithUTF8String:"alignmentPreset"] animated:NO];
    [self.previewCell refreshFromPreferencesAnimated:YES];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Position"
                                                                   message:@"Lyrics position has been reset to default."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLyricsCache {
    clearLyricsCacheFiles();
    notify_post("com.locklyrics.preferences.changed");

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lyrics Cache"
                                                                   message:@"Offline lyrics cache has been cleared."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
