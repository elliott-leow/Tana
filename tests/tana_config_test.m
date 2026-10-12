#import <Cocoa/Cocoa.h>
#import <assert.h>
#import "../src/tana_config.h"

static NSString *test_path(void) { NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo].globallyUniqueString stringByAppendingString:@".tana-config"]]; return [directory stringByAppendingPathComponent:@"config.json"]; }
static void write_text(NSString *path, NSString *text) { assert([[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL]); assert([text dataUsingEncoding:NSUTF8StringEncoding]); assert([[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]); }
static NSDictionary *defaults(void) { return @{ @"toggle-strip": @"ctrl+alt+t", @"focus-left": @"ctrl+alt+left", @"focus-right": @"ctrl+alt+right" }; }
static void test_defaults(void) { NSString *path=test_path(); TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]); TanaConfigSnapshot *s=[config copySnapshot]; assert(s.motionStrength==1 && !s.showStripMap && s.autofocusMode==TanaAutofocusPointerMovement && [s.stripWidths count]==4); assert([[s actionForKeyCode:17 modifiers:(NSEventModifierFlagControl|NSEventModifierFlagOption)] isEqual:@"toggle-strip"]); [s release]; }
static void test_malformed_is_atomic(void) { NSString *path=test_path(); write_text(path,@"{\"settings\":{\"motionStrength\":0.2}}"); TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]); write_text(path,@"{ bad json"); NSError *error=nil; assert(![config reload:&error] && error); TanaConfigSnapshot *s=[config copySnapshot]; assert(s.motionStrength==.2); [s release]; [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; }
static void test_duplicates_and_invalid_numbers(void) { NSString *path=test_path(); write_text(path,@"{\"settings\":{\"motionStrength\":2,\"stripWidths\":[0,-1,1.2]},\"shortcuts\":{\"focus-left\":\"ctrl+alt+t\"}}"); TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]); TanaConfigSnapshot *s=[config copySnapshot]; assert(s.motionStrength==1 && [s.stripWidths count]==4); assert([[s.shortcutConflicts objectAtIndex:0] isEqual:@"toggle-strip"]); assert([[s actionForKeyCode:17 modifiers:(NSEventModifierFlagControl|NSEventModifierFlagOption)] isEqual:@"focus-left"]); [s release]; [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; }
static void test_wrong_types_are_ignored(void) { NSString *path=test_path(); write_text(path,@"{\"settings\":{\"motionStrength\":true,\"autofocus\":5,\"showStripMap\":\"yes\",\"stripWidths\":\"bad\"},\"shortcuts\":{\"x\":\"keycode:garbage\",\"y\":\"keycode:128\"},\"appRules\":{\"com.example.App\":{\"floating\":true}}}"); TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]); TanaConfigSnapshot *s=[config copySnapshot]; assert(s.motionStrength==1 && !s.showStripMap && s.autofocusMode==TanaAutofocusPointerMovement && [s.stripWidths count]==4); assert(![s.shortcuts objectForKey:@"x"] && ![s.shortcuts objectForKey:@"y"]); TanaAppRule *rule=[s ruleForBundleIdentifier:@"com.example.App"]; assert(rule && rule.width==0 && rule.floating); [s release]; [[NSFileManager defaultManager] removeItemAtPath:[path stringByDeletingLastPathComponent] error:NULL]; }
static void test_persistence(void) { NSString *path=test_path(); TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config rememberRuleForBundleIdentifier:@"com.example.App" width:720 floating:YES openBesideCurrent:NO error:NULL]); NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL]; assert(([attrs filePosixPermissions] & 0777)==0600); NSDictionary *dirAttrs=[[NSFileManager defaultManager] attributesOfItemAtPath:[path stringByDeletingLastPathComponent] error:NULL]; assert(([dirAttrs filePosixPermissions] & 0777)==0700); TanaConfig *again=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([again reload:NULL]); TanaConfigSnapshot *s=[again copySnapshot]; TanaAppRule *rule=[s ruleForBundleIdentifier:@"com.example.App"]; assert(rule && rule.width==720 && !rule.widthIsFraction && rule.floating && !rule.openBesideCurrent); [s release]; assert([again rememberRuleForBundleIdentifier:@"com.example.Floating" width:0 floating:YES openBesideCurrent:YES error:NULL]); s=[again copySnapshot]; rule=[s ruleForBundleIdentifier:@"com.example.Floating"]; assert(rule && rule.width==0 && rule.floating); [s release]; [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; [[NSFileManager defaultManager] removeItemAtPath:[path stringByDeletingLastPathComponent] error:NULL]; }
static void test_extended_settings(void) {
    NSString *path=test_path();
    write_text(path,@"{\"settings\":{\"mod\":\"ctrl+alt\",\"gaps\":{\"inner\":20,\"top\":\"x\"},\"border\":{\"enabled\":true,\"active\":\"#ff8800\"},\"snap\":\"none\"},\"shortcuts\":{\"focus-left\":\"mod+h\",\"focus-right\":\"mod+nonsense\"},\"exec\":{\"mod+e\":\"open -a Finder\",\"bad+key\":\"true\",\"mod+x\":5}}");
    TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]);
    TanaConfigSnapshot *s=[config copySnapshot]; NSUInteger mod=NSEventModifierFlagControl|NSEventModifierFlagOption;
    assert([[s actionForKeyCode:4 modifiers:mod] isEqual:@"focus-left"]);
    /* An unreadable override keeps the default binding and is reported. */
    assert([[s actionForKeyCode:124 modifiers:mod] isEqual:@"focus-right"]);
    assert([[s actionForKeyCode:14 modifiers:mod] isEqual:@"exec:open -a Finder"]);
    assert([s.diagnostics count]==3);
    assert([s numberAt:@"gaps.inner" fallback:12 minimum:0 maximum:200]==20);
    assert([s numberAt:@"gaps.top" fallback:14 minimum:0 maximum:200]==14);
    assert([s numberAt:@"gaps.inner" fallback:12 minimum:0 maximum:10]==12);
    assert([s boolAt:@"border.enabled" fallback:NO] && ![s hasValueAt:@"border.width"] && [s hasValueAt:@"border.enabled"]);
    assert([[s stringAt:@"snap" fallback:@"column"] isEqual:@"none"] && [[s stringAt:@"missing.key" fallback:@"d"] isEqual:@"d"]);
    double c[4]={9,9,9,9};
    assert(TanaParseColor([s stringAt:@"border.active" fallback:nil],c) && c[0]==1 && fabs(c[1]-136/255.0)<1e-9 && c[2]==0 && c[3]==1);
    assert(TanaParseColor(@"#0f08",c) && c[1]==1 && fabs(c[3]-8/15.0)<1e-9);
    assert(!TanaParseColor(@"red",c) && !TanaParseColor(@"#12345",c) && !TanaParseColor(@"#gggggg",c));
    assert([TanaBindingDescription([s.shortcuts objectForKey:@"focus-left"]) isEqual:@"⌃⌥H"]);
    [s release]; [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}
static void test_rules_and_jump(void) {
    NSString *path=test_path();
    write_text(path,@"{\"appRules\":{\"com.a\":{\"width\":0.5},\"com.b\":{\"width\":\"auto\",\"opacity\":5,\"strip\":\"web\"}},"
        "\"windowRules\":[{\"app\":\"com.a\",\"title\":\"^Mini\",\"floating\":true,\"sticky\":true,\"corner\":\"bottom-right\"},"
        "{\"title\":\"Inspector$\",\"tabbed\":true,\"strip\":2},{\"title\":\"(\"},{\"floating\":true}],"
        "\"jump\":{\"ctrl+alt+b\":\"org.mozilla.firefox\",\"ctrl+alt+g\":{\"app\":\"com.g\",\"launch\":\"open -na G\"},\"ctrl+alt+x\":7}}");
    TanaConfig *config=[[[TanaConfig alloc] initWithPath:path defaultShortcuts:defaults()] autorelease]; assert([config reload:NULL]);
    TanaConfigSnapshot *s=[config copySnapshot]; NSUInteger mod=NSEventModifierFlagControl|NSEventModifierFlagOption;
    assert(s.hasTitleRules);
    /* An application rule alone: the two properties it has always decided are filled in. */
    NSDictionary *plain=[s propertiesForBundleIdentifier:@"com.a" title:@"Document"];
    assert([plain[@"width"] doubleValue]==.5 && ![plain[@"floating"] boolValue] && [plain[@"openBesideCurrent"] boolValue] && !plain[@"titleMatched"]);
    /* The first matching window rule overlays it. */
    NSDictionary *mini=[s propertiesForBundleIdentifier:@"com.a" title:@"Mini Player"];
    assert([mini[@"floating"] boolValue] && [mini[@"sticky"] boolValue] && [mini[@"corner"] isEqual:@"bottom-right"] && [mini[@"width"] doubleValue]==.5 && [mini[@"titleMatched"] boolValue]);
    /* A rule with no "app" applies to any application; strip numbers are one-based in the file. */
    NSDictionary *inspector=[s propertiesForBundleIdentifier:@"com.z" title:@"Web Inspector"];
    assert([inspector[@"tabbed"] boolValue] && [inspector[@"strip"] intValue]==1);
    assert(![s propertiesForBundleIdentifier:@"com.z" title:@"Other"] && ![s propertiesForBundleIdentifier:@"com.z" title:nil]);
    NSDictionary *named=[s propertiesForBundleIdentifier:@"com.b" title:nil];
    assert([named[@"autoWidth"] boolValue] && [named[@"strip"] isEqual:@"web"] && !named[@"opacity"]);
    assert([[s actionForKeyCode:11 modifiers:mod] isEqual:@"jump:org.mozilla.firefox\t"]);
    assert([[s actionForKeyCode:5 modifiers:mod] isEqual:@"jump:com.g\topen -na G"]);
    /* Bad opacity, bad pattern, a rule naming nothing, and a jump with no application. */
    assert([s.diagnostics count]==4);
    [s release]; [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}
/* The example in the repository is what people copy: it must load without a complaint. */
static void test_example_is_clean(void) {
    /* No defaults: this test's stand-in ones would collide with the example's own bindings. */
    TanaConfig *config=[[[TanaConfig alloc] initWithPath:@"config.example.json" defaultShortcuts:@{}] autorelease]; assert([config reload:NULL]);
    TanaConfigSnapshot *s=[config copySnapshot];
    if([s.diagnostics count]) NSLog(@"%@",s.diagnostics);
    assert([s.diagnostics count]==0 && s.hasTitleRules && [[s propertiesForBundleIdentifier:@"com.apple.Safari" title:nil][@"strip"] isEqual:@"web"]);
    [s release];
}
int main(void) { @autoreleasepool { test_rules_and_jump(); test_example_is_clean(); test_defaults(); test_malformed_is_atomic(); test_duplicates_and_invalid_numbers(); test_wrong_types_are_ignored(); test_persistence(); test_extended_settings(); puts("tana_config_test: OK"); } return 0; }
