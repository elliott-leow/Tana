#import "tana_config.h"
#import <AppKit/AppKit.h>
#include <math.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static NSString * const TanaConfigErrorDomain = @"TanaConfigError";
static const NSUInteger TanaShortcutModifiers = (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagFunction);

static BOOL tana_number(id value, double *out) { if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)value)==CFBooleanGetTypeID()) return NO; double n=[value doubleValue]; if (!isfinite(n)) return NO; *out=n; return YES; }
static NSDictionary *tana_dictionary(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : nil; }
static BOOL tana_bool(id value, BOOL fallback) { return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)value)==CFBooleanGetTypeID() ? [value boolValue] : fallback; }
static NSString *tana_lower(id value) { return [value isKindOfClass:[NSString class]] ? [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] : nil; }

static NSDictionary *tana_key_codes(void)
{
    static NSDictionary *codes=nil;
    if (!codes) codes=[[NSDictionary alloc] initWithObjectsAndKeys:
        @0,@"a", @1,@"s", @2,@"d", @3,@"f", @4,@"h", @5,@"g", @6,@"z", @7,@"x", @8,@"c", @9,@"v", @11,@"b", @12,@"q", @13,@"w", @14,@"e", @15,@"r", @16,@"y", @17,@"t", @18,@"1", @19,@"2", @20,@"3", @21,@"4", @22,@"6", @23,@"5", @24,@"=", @25,@"9", @26,@"7", @27,@"-", @28,@"8", @29,@"0", @30,@"]", @31,@"o", @32,@"u", @33,@"[", @34,@"i", @35,@"p", @36,@"return", @36,@"enter", @37,@"l", @38,@"j", @39,@"'", @40,@"k", @41,@";", @42,@"\\", @43,@",", @44,@"/", @45,@"n", @46,@"m", @47,@".", @48,@"tab", @49,@"space", @51,@"delete", @53,@"escape", @53,@"esc", @123,@"left", @124,@"right", @125,@"down", @126,@"up", nil];
    return codes;
}

static NSUInteger tana_mod_mask=NSEventModifierFlagOption|NSEventModifierFlagCommand;
static NSUInteger tana_parse_modifiers(NSString *text)
{
    NSUInteger mods=0;
    for (NSString *raw in [text componentsSeparatedByString:@"+"]) { NSString *part=tana_lower(raw);
        if ([part isEqual:@"cmd"] || [part isEqual:@"command"]) mods|=NSEventModifierFlagCommand;
        else if ([part isEqual:@"ctrl"] || [part isEqual:@"control"]) mods|=NSEventModifierFlagControl;
        else if ([part isEqual:@"alt"] || [part isEqual:@"option"]) mods|=NSEventModifierFlagOption;
        else if ([part isEqual:@"shift"]) mods|=NSEventModifierFlagShift;
        else return 0;
    }
    return mods;
}

static TanaShortcutBinding *tana_parse_binding(NSString *text, NSString *action)
{
    if (![text isKindOfClass:[NSString class]] || ![action length]) return nil;
    NSArray *parts=[text componentsSeparatedByString:@"+"]; NSUInteger mods=0; NSNumber *code=nil;
    for (NSString *raw in parts) { NSString *part=tana_lower(raw); if (![part length]) return nil;
        if ([part isEqual:@"mod"]) mods|=tana_mod_mask;
        else if ([part isEqual:@"cmd"] || [part isEqual:@"command"]) mods|=NSEventModifierFlagCommand;
        else if ([part isEqual:@"ctrl"] || [part isEqual:@"control"]) mods|=NSEventModifierFlagControl;
        else if ([part isEqual:@"alt"] || [part isEqual:@"option"]) mods|=NSEventModifierFlagOption;
        else if ([part isEqual:@"shift"]) mods|=NSEventModifierFlagShift;
        else if ([part isEqual:@"fn"] || [part isEqual:@"function"]) mods|=NSEventModifierFlagFunction;
        else if (!code) { code=[tana_key_codes() objectForKey:part]; if (!code && [part hasPrefix:@"keycode:"]) { NSString *digits=[part substringFromIndex:8]; NSScanner *scanner=[NSScanner scannerWithString:digits]; unsigned long long n=0; if ([digits length] && [scanner scanUnsignedLongLong:&n] && [scanner isAtEnd] && n<=127) code=@(n); } }
        else return nil;
    }
    return code ? [[[TanaShortcutBinding alloc] initWithKeyCode:[code unsignedShortValue] modifiers:mods action:action] autorelease] : nil;
}

BOOL TanaParseColor(NSString *text, double rgba[4])
{
    NSString *hex=tana_lower(text); if (![hex hasPrefix:@"#"]) return NO;
    hex=[hex substringFromIndex:1]; NSUInteger length=[hex length];
    if (length!=3 && length!=4 && length!=6 && length!=8) return NO;
    double out[4]={0,0,0,1}; NSUInteger step=length<=4 ? 1 : 2;
    for (NSUInteger i=0; i<length/step; i++) {
        unsigned value=0; NSString *part=[hex substringWithRange:NSMakeRange(i*step,step)];
        for (NSUInteger j=0; j<step; j++) { unichar c=[part characterAtIndex:j]; if (!((c>='0'&&c<='9')||(c>='a'&&c<='f'))) return NO; }
        NSScanner *scanner=[NSScanner scannerWithString:part]; if (![scanner scanHexInt:&value]) return NO;
        out[i]=step==1 ? value/15.0 : value/255.0;
    }
    memcpy(rgba,out,sizeof(out)); return YES;
}

NSString *TanaBindingDescription(TanaShortcutBinding *binding)
{
    if (!binding) return @"";
    NSDictionary *symbols=@{@"left":@"←",@"right":@"→",@"up":@"↑",@"down":@"↓",@"return":@"↩",@"space":@"Space",@"tab":@"⇥",@"escape":@"⎋",@"delete":@"⌫"};
    NSString *key=[NSString stringWithFormat:@"keycode:%hu",[binding keyCode]];
    for (NSString *candidate in [[tana_key_codes() allKeys] sortedArrayUsingSelector:@selector(compare:)])
        if ([[tana_key_codes() objectForKey:candidate] unsignedShortValue]==[binding keyCode] && ![candidate isEqual:@"enter"] && ![candidate isEqual:@"esc"]) { key=[symbols objectForKey:candidate] ?: [candidate uppercaseString]; break; }
    NSUInteger m=[binding modifiers];
    return [NSString stringWithFormat:@"%@%@%@%@%@%@",m&NSEventModifierFlagFunction?@"fn ":@"",m&NSEventModifierFlagControl?@"⌃":@"",m&NSEventModifierFlagOption?@"⌥":@"",m&NSEventModifierFlagShift?@"⇧":@"",m&NSEventModifierFlagCommand?@"⌘":@"",key];
}

@implementation TanaShortcutBinding
@synthesize keyCode=_keyCode, modifiers=_modifiers, action=_action;
- (id)initWithKeyCode:(unsigned short)keyCode modifiers:(NSUInteger)modifiers action:(NSString *)action { if ((self=[super init])) { _keyCode=keyCode; _modifiers=modifiers&TanaShortcutModifiers; _action=[action copy]; } return self; }
- (id)copyWithZone:(NSZone *)zone { return [[TanaShortcutBinding allocWithZone:zone] initWithKeyCode:_keyCode modifiers:_modifiers action:_action]; }
- (void)dealloc { [_action release]; [super dealloc]; }
@end

@implementation TanaAppRule
@synthesize bundleIdentifier=_bundleIdentifier, width=_width, widthIsFraction=_widthIsFraction, floating=_floating, openBesideCurrent=_openBesideCurrent;
- (id)initWithBundleIdentifier:(NSString *)bundleIdentifier width:(double)width widthIsFraction:(BOOL)widthIsFraction floating:(BOOL)floating openBesideCurrent:(BOOL)openBesideCurrent { if ((self=[super init])) { _bundleIdentifier=[bundleIdentifier copy]; _width=width; _widthIsFraction=widthIsFraction; _floating=floating; _openBesideCurrent=openBesideCurrent; } return self; }
- (id)copyWithZone:(NSZone *)zone { return [[TanaAppRule allocWithZone:zone] initWithBundleIdentifier:_bundleIdentifier width:_width widthIsFraction:_widthIsFraction floating:_floating openBesideCurrent:_openBesideCurrent]; }
- (void)dealloc { [_bundleIdentifier release]; [super dealloc]; }
@end

@implementation TanaConfigSnapshot
@synthesize motionStrength=_motionStrength, autofocusMode=_autofocusMode, showStripMap=_showStripMap, stripWidths=_stripWidths, shortcuts=_shortcuts, shortcutConflicts=_shortcutConflicts, diagnostics=_diagnostics;
- (void)setSettings:(NSDictionary *)settings diagnostics:(NSArray *)diagnostics { [_settings release]; _settings=[settings copy]; [_diagnostics release]; _diagnostics=[diagnostics copy]; }
- (void)setRuleProperties:(NSDictionary *)properties windowRules:(NSArray *)windowRules { [_ruleProperties release]; _ruleProperties=[properties copy]; [_windowRules release]; _windowRules=[windowRules copy]; }
- (BOOL)hasTitleRules { for (NSDictionary *rule in _windowRules) if ([rule objectForKey:@"titleRegex"]) return YES; return NO; }
- (NSDictionary *)propertiesForBundleIdentifier:(NSString *)bundleIdentifier title:(NSString *)title
{
    NSMutableDictionary *out=nil; NSDictionary *base=bundleIdentifier ? [_ruleProperties objectForKey:bundleIdentifier] : nil;
    if (base) out=[NSMutableDictionary dictionaryWithDictionary:base];
    for (NSDictionary *rule in _windowRules) {
        NSString *app=[rule objectForKey:@"app"]; NSRegularExpression *regex=[rule objectForKey:@"titleRegex"];
        if (app && ![app isEqual:bundleIdentifier]) continue;
        if (regex && (!title || ![regex firstMatchInString:title options:0 range:NSMakeRange(0,[title length])])) continue;
        if (!out) out=[NSMutableDictionary dictionary];
        for (NSString *key in rule) if (![key isEqual:@"app"] && ![key isEqual:@"titleRegex"]) [out setObject:[rule objectForKey:key] forKey:key];
        if (regex) [out setObject:@YES forKey:@"titleMatched"];
        break;
    }
    return out;
}
- (id)valueAt:(NSString *)path { id value=_settings; for (NSString *part in [path componentsSeparatedByString:@"."]) { if (![value isKindOfClass:[NSDictionary class]]) return nil; value=[value objectForKey:part]; } return value; }
- (BOOL)hasValueAt:(NSString *)path { return [self valueAt:path]!=nil; }
- (double)numberAt:(NSString *)path fallback:(double)fallback minimum:(double)minimum maximum:(double)maximum { double n; return tana_number([self valueAt:path],&n) && n>=minimum && n<=maximum ? n : fallback; }
- (BOOL)boolAt:(NSString *)path fallback:(BOOL)fallback { return tana_bool([self valueAt:path],fallback); }
- (NSString *)stringAt:(NSString *)path fallback:(NSString *)fallback { id value=[self valueAt:path]; return [value isKindOfClass:[NSString class]] && [value length] ? value : fallback; }
- (id)initWithMotion:(double)motion autofocus:(TanaAutofocusMode)autofocus showStripMap:(BOOL)showStripMap widths:(NSArray *)widths shortcuts:(NSDictionary *)shortcuts rules:(NSDictionary *)rules conflicts:(NSArray *)conflicts { if ((self=[super init])) { _motionStrength=motion; _autofocusMode=autofocus; _showStripMap=showStripMap; _stripWidths=[widths copy]; _shortcuts=[shortcuts copy]; _appRules=[rules copy]; _shortcutConflicts=[conflicts copy]; } return self; }
/* Snapshots are immutable, so a copy is the same object. */
- (id)copyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }
- (NSString *)actionForKeyCode:(unsigned short)keyCode modifiers:(NSUInteger)modifiers { NSUInteger wanted=modifiers&TanaShortcutModifiers; for (TanaShortcutBinding *binding in [_shortcuts allValues]) if ([binding keyCode]==keyCode && [binding modifiers]==wanted) return [binding action]; return nil; }
- (TanaAppRule *)ruleForBundleIdentifier:(NSString *)bundleIdentifier { return [_appRules objectForKey:bundleIdentifier]; }
- (void)dealloc { [_stripWidths release]; [_shortcuts release]; [_appRules release]; [_shortcutConflicts release]; [_settings release]; [_diagnostics release]; [_ruleProperties release]; [_windowRules release]; [super dealloc]; }
@end

/* The recognised parts of one rule; anything unreadable is reported and left out. */
static NSDictionary *tana_rule_properties(NSDictionary *raw, NSString *label, NSMutableArray *diagnostics)
{
    NSMutableDictionary *out=[NSMutableDictionary dictionary]; double n;
    id width=[raw objectForKey:@"width"];
    if ([tana_lower(width) isEqual:@"auto"]) [out setObject:@YES forKey:@"autoWidth"];
    else if (tana_number(width,&n) && n>0) [out setObject:@(n) forKey:@"width"];
    else if (width) [diagnostics addObject:[NSString stringWithFormat:@"%@: width must be a positive number or \"auto\"",label]];
    for (NSString *key in @[@"floating",@"openBesideCurrent",@"tabbed",@"noBorder",@"sticky"]) { id value=[raw objectForKey:key]; if (!value) continue;
        if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)value)==CFBooleanGetTypeID()) [out setObject:value forKey:key];
        else [diagnostics addObject:[NSString stringWithFormat:@"%@: %@ must be true or false",label,key]]; }
    id opacity=[raw objectForKey:@"opacity"];
    if (tana_number(opacity,&n) && n>=.1 && n<=1) [out setObject:@(n) forKey:@"opacity"];
    else if (opacity) [diagnostics addObject:[NSString stringWithFormat:@"%@: opacity must be between 0.1 and 1",label]];
    id strip=[raw objectForKey:@"strip"];
    if (tana_number(strip,&n) && n>=1 && n<=9 && n==floor(n)) [out setObject:@((NSInteger)n-1) forKey:@"strip"];
    else if ([strip isKindOfClass:[NSString class]] && [strip length]) [out setObject:strip forKey:@"strip"];
    else if (strip) [diagnostics addObject:[NSString stringWithFormat:@"%@: strip must be a number from 1 to 9 or a strip name",label]];
    NSString *column=tana_lower([raw objectForKey:@"column"]);
    if ([column isEqual:@"start"] || [column isEqual:@"end"]) [out setObject:column forKey:@"column"];
    else if ([raw objectForKey:@"column"]) [diagnostics addObject:[NSString stringWithFormat:@"%@: column must be start or end",label]];
    NSString *corner=tana_lower([raw objectForKey:@"corner"]);
    if ([@[@"top-left",@"top-right",@"bottom-left",@"bottom-right"] containsObject:corner ?: @""]) [out setObject:corner forKey:@"corner"];
    else if ([raw objectForKey:@"corner"]) [diagnostics addObject:[NSString stringWithFormat:@"%@: corner must be top-left, top-right, bottom-left or bottom-right",label]];
    return out;
}

static TanaConfigSnapshot *tana_snapshot(NSDictionary *document, NSDictionary *defaults)
{
    NSDictionary *settings=tana_dictionary([document objectForKey:@"settings"]); double motion=1, candidate;
    NSMutableArray *diagnostics=[NSMutableArray array];
    NSUInteger mod=tana_parse_modifiers([settings objectForKey:@"mod"] ?: @"alt+cmd");
    if (!mod) { [diagnostics addObject:@"settings.mod is not a modifier list such as \"alt+cmd\""]; mod=NSEventModifierFlagOption|NSEventModifierFlagCommand; }
    tana_mod_mask=mod;
    if (tana_number([settings objectForKey:@"motionStrength"],&candidate) && candidate>=0 && candidate<=1) motion=candidate;
    NSString *focus=tana_lower([settings objectForKey:@"autofocus"]); TanaAutofocusMode autofocus=[focus isEqual:@"after-scroll"] ? TanaAutofocusAfterScroll : TanaAutofocusPointerMovement;
    BOOL showStripMap=tana_bool([settings objectForKey:@"showStripMap"],NO);
    NSArray *inputWidths=[settings objectForKey:@"stripWidths"]; NSMutableArray *widths=[NSMutableArray array];
    if ([inputWidths isKindOfClass:[NSArray class]]) for (id value in inputWidths) if (tana_number(value,&candidate) && candidate>0 && candidate<=1) [widths addObject:@(candidate)];
    if (![widths count]) [widths addObjectsFromArray:@[@(1.0/3.0),@(0.5),@(2.0/3.0),@(1.0)]];
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary]; NSMutableSet *used=[NSMutableSet set]; NSMutableArray *conflicts=[NSMutableArray array];
    NSDictionary *overrides=tana_dictionary([document objectForKey:@"shortcuts"]); NSMutableSet *claimed=[NSMutableSet set];
    /* Config entries win over defaults, including a deliberate disable. Sorting
     * gives diagnostics stable order instead of NSDictionary's hash order. */
    NSArray *overrideActions=[[overrides allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *defaultActions=[[defaults allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger pass=0; pass<2; pass++) for (NSString *action in (pass ? defaultActions : overrideActions)) {
        if (![action isKindOfClass:[NSString class]] || (pass && [claimed containsObject:action])) continue;
        id value=pass ? [defaults objectForKey:action] : [overrides objectForKey:action];
        if (!pass) [claimed addObject:action];
        if (value==[NSNull null] || ([value isKindOfClass:[NSNumber class]] && ![value boolValue]) || ([value isKindOfClass:[NSString class]] && [tana_lower(value) isEqual:@"disabled"])) continue;
        TanaShortcutBinding *binding=tana_parse_binding(value,action);
        /* An unreadable override must not silently unbind the action: say so
         * and fall back to the default binding in the second pass. */
        if (!binding) { if (!pass) { [claimed removeObject:action]; [diagnostics addObject:[NSString stringWithFormat:@"shortcut \"%@\" has an unreadable binding \"%@\"",action,value]]; } continue; }
        NSString *key=[NSString stringWithFormat:@"%hu:%lu",[binding keyCode],(unsigned long)[binding modifiers]];
        if ([used containsObject:key]) { [conflicts addObject:action]; [diagnostics addObject:[NSString stringWithFormat:@"shortcut \"%@\" duplicates another binding (%@)",action,TanaBindingDescription(binding)]]; continue; }
        [used addObject:key]; [bindings setObject:binding forKey:action];
    }
    /* "exec": { "<binding>": "<shell command>" } runs a command from a key. */
    NSDictionary *exec=tana_dictionary([document objectForKey:@"exec"]);
    for (NSString *text in [[exec allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *command=[exec objectForKey:text];
        if (![command isKindOfClass:[NSString class]] || ![command length]) { [diagnostics addObject:[NSString stringWithFormat:@"exec \"%@\" needs a command string",text]]; continue; }
        NSString *action=[@"exec:" stringByAppendingString:command];
        TanaShortcutBinding *binding=tana_parse_binding(text,action);
        if (!binding) { [diagnostics addObject:[NSString stringWithFormat:@"exec has an unreadable binding \"%@\"",text]]; continue; }
        NSString *key=[NSString stringWithFormat:@"%hu:%lu",[binding keyCode],(unsigned long)[binding modifiers]];
        if ([used containsObject:key]) { [diagnostics addObject:[NSString stringWithFormat:@"exec binding \"%@\" duplicates another binding",text]]; continue; }
        [used addObject:key]; [bindings setObject:binding forKey:action];
    }
    /* "jump": { "<binding>": "<bundle id>" | { "app": "<bundle id>", "launch": "<shell command>" } }
     * focuses a window of that application, or starts it when it has none. */
    NSDictionary *jump=tana_dictionary([document objectForKey:@"jump"]);
    for (NSString *text in [[jump allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id target=[jump objectForKey:text]; NSString *app=[target isKindOfClass:[NSString class]] ? target : [tana_dictionary(target) objectForKey:@"app"];
        NSString *launch=[tana_dictionary(target) objectForKey:@"launch"];
        if (![app isKindOfClass:[NSString class]] || ![app length] || [app rangeOfString:@"\t"].location!=NSNotFound || (launch && ![launch isKindOfClass:[NSString class]])) { [diagnostics addObject:[NSString stringWithFormat:@"jump \"%@\" needs an application bundle identifier",text]]; continue; }
        NSString *action=[NSString stringWithFormat:@"jump:%@\t%@",app,launch ?: @""];
        TanaShortcutBinding *binding=tana_parse_binding(text,action);
        if (!binding) { [diagnostics addObject:[NSString stringWithFormat:@"jump has an unreadable binding \"%@\"",text]]; continue; }
        NSString *key=[NSString stringWithFormat:@"%hu:%lu",[binding keyCode],(unsigned long)[binding modifiers]];
        if ([used containsObject:key]) { [diagnostics addObject:[NSString stringWithFormat:@"jump binding \"%@\" duplicates another binding",text]]; continue; }
        [used addObject:key]; [bindings setObject:binding forKey:action];
    }
    NSMutableDictionary *rules=[NSMutableDictionary dictionary]; NSDictionary *rawRules=tana_dictionary([document objectForKey:@"appRules"]);
    for (NSString *bundle in rawRules) { NSDictionary *raw=tana_dictionary([rawRules objectForKey:bundle]); double width=0; if (![bundle isKindOfClass:[NSString class]] || ![bundle length] || ![raw count]) continue; id rawWidth=[raw objectForKey:@"width"]; if (rawWidth && (!tana_number(rawWidth,&width) || width<=0)) width=0; BOOL fraction=width>0 && width<=1; [rules setObject:[[[TanaAppRule alloc] initWithBundleIdentifier:bundle width:width widthIsFraction:fraction floating:tana_bool([raw objectForKey:@"floating"],NO) openBesideCurrent:tana_bool([raw objectForKey:@"openBesideCurrent"],YES)] autorelease] forKey:bundle]; }
    TanaConfigSnapshot *snapshot=[[[TanaConfigSnapshot alloc] initWithMotion:motion autofocus:autofocus showStripMap:showStripMap widths:widths shortcuts:bindings rules:rules conflicts:conflicts] autorelease];
    NSMutableDictionary *properties=[NSMutableDictionary dictionary];
    for (NSString *bundle in rawRules) { NSDictionary *raw=tana_dictionary([rawRules objectForKey:bundle]); if (![bundle isKindOfClass:[NSString class]] || ![bundle length] || ![raw count]) continue;
        NSMutableDictionary *entry=[[tana_rule_properties(raw,[NSString stringWithFormat:@"appRules \"%@\"",bundle],diagnostics) mutableCopy] autorelease];
        /* An application rule has always decided these two, stated or not. */
        if (![entry objectForKey:@"floating"]) [entry setObject:@NO forKey:@"floating"];
        if (![entry objectForKey:@"openBesideCurrent"]) [entry setObject:@YES forKey:@"openBesideCurrent"];
        [properties setObject:entry forKey:bundle]; }
    NSMutableArray *windowRules=[NSMutableArray array]; id rawWindowRules=[document objectForKey:@"windowRules"]; NSUInteger index=0;
    if (rawWindowRules && ![rawWindowRules isKindOfClass:[NSArray class]]) [diagnostics addObject:@"windowRules must be a list of rules"];
    else for (id item in rawWindowRules) { NSDictionary *raw=tana_dictionary(item); NSString *label=[NSString stringWithFormat:@"windowRules[%lu]",(unsigned long)index++];
        id app=[raw objectForKey:@"app"], title=[raw objectForKey:@"title"];
        if (!raw || (app && (![app isKindOfClass:[NSString class]] || ![app length])) || (title && ![title isKindOfClass:[NSString class]]) || (!app && !title)) { [diagnostics addObject:[NSString stringWithFormat:@"%@ needs an \"app\" bundle identifier, a \"title\" pattern, or both",label]]; continue; }
        NSMutableDictionary *entry=[[tana_rule_properties(raw,label,diagnostics) mutableCopy] autorelease];
        if (title) { NSError *regexError=nil; NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:title options:0 error:&regexError];
            if (!regex) { [diagnostics addObject:[NSString stringWithFormat:@"%@: title is not a valid pattern (%@)",label,[regexError localizedDescription]]]; continue; }
            [entry setObject:regex forKey:@"titleRegex"]; }
        if (app) [entry setObject:app forKey:@"app"];
        [windowRules addObject:entry]; }
    [snapshot setSettings:settings ?: @{} diagnostics:diagnostics];
    [snapshot setRuleProperties:properties windowRules:windowRules];
    return snapshot;
}

/* NSDataWritingAtomic does not let us set the temporary file's mode before it
 * is visible in the directory.  mkstemp creates 0600, then rename is atomic. */
static BOOL tana_private_atomic_write(NSString *path, NSData *data, NSError **error)
{
    NSFileManager *manager=[NSFileManager defaultManager]; NSString *parent=[path stringByDeletingLastPathComponent];
    if (![manager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    if (chmod([parent fileSystemRepresentation],0700)!=0) { if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey:@"Could not secure Tana's config directory."}]; return NO; }
    NSString *templatePath=[parent stringByAppendingPathComponent:@".config.json.XXXXXX"]; char *temporary=strdup([templatePath fileSystemRepresentation]);
    if (!temporary) { if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil]; return NO; }
    int fd=mkstemp(temporary); if (fd<0) { int saved=errno; free(temporary); if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]; return NO; }
    BOOL ok=fchmod(fd,0600)==0; const uint8_t *bytes=[data bytes]; NSUInteger remaining=[data length];
    while (ok && remaining) { ssize_t written=write(fd,bytes,remaining); if (written<=0) { ok=NO; break; } bytes+=written; remaining-=(NSUInteger)written; }
    if (ok && fsync(fd)!=0) ok=NO; int saved=errno; if (close(fd)!=0 && ok) { ok=NO; saved=errno; }
    if (ok && rename(temporary,[path fileSystemRepresentation])!=0) { ok=NO; saved=errno; }
    if (!ok) { unlink(temporary); if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]; }
    free(temporary); return ok;
}

@implementation TanaConfig
@synthesize path=_path, lastError=_lastError;
+ (NSString *)defaultPath { NSArray *paths=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES); return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"Tana/config.json"]; }
- (id)initWithPath:(NSString *)path defaultShortcuts:(NSDictionary *)defaultShortcuts { if ((self=[super init])) { _path=[(path ?: [[self class] defaultPath]) copy]; _defaultShortcuts=[defaultShortcuts copy]; _document=[[NSMutableDictionary alloc] init]; _snapshot=[tana_snapshot(_document,_defaultShortcuts) retain]; } return self; }
- (BOOL)reload:(NSError **)error { if (error) *error=nil; @synchronized(self) { NSData *data=[NSData dataWithContentsOfFile:_path options:0 error:error]; if (!data) { if ([[NSFileManager defaultManager] fileExistsAtPath:_path]) return NO; if (error) *error=nil; [_document release]; _document=[[NSMutableDictionary alloc] init]; TanaConfigSnapshot *next=tana_snapshot(_document,_defaultShortcuts); [_snapshot release]; _snapshot=[next retain]; return YES; } NSError *jsonError=nil; id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]; if (![object isKindOfClass:[NSDictionary class]]) { if (!jsonError) jsonError=[NSError errorWithDomain:TanaConfigErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Config root must be an object."}]; [_lastError release]; _lastError=[[jsonError localizedDescription] copy]; if (error) *error=jsonError; return NO; } NSMutableDictionary *document=[object mutableCopy]; TanaConfigSnapshot *next=tana_snapshot(document,_defaultShortcuts); [_document release]; _document=document; [_snapshot release]; _snapshot=[next retain]; [_lastError release]; _lastError=nil; return YES; } }
- (TanaConfigSnapshot *)copySnapshot { @synchronized(self) { return [_snapshot copy]; } }
- (BOOL)rememberRuleForBundleIdentifier:(NSString *)bundleIdentifier width:(double)width floating:(BOOL)floating openBesideCurrent:(BOOL)openBesideCurrent error:(NSError **)error { if (![bundleIdentifier isKindOfClass:[NSString class]] || ![bundleIdentifier length] || !isfinite(width) || width<0) { if (error) *error=[NSError errorWithDomain:TanaConfigErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:@"Bundle identifier and non-negative width are required."}]; return NO; } @synchronized(self) { NSMutableDictionary *next=[_document mutableCopy]; NSMutableDictionary *rules=[[tana_dictionary([next objectForKey:@"appRules"]) mutableCopy] autorelease]; if (!rules) rules=[NSMutableDictionary dictionary]; NSMutableDictionary *rule=[[tana_dictionary([rules objectForKey:bundleIdentifier]) mutableCopy] autorelease]; if (!rule) rule=[NSMutableDictionary dictionary]; if (width>0) [rule setObject:@(width) forKey:@"width"]; else [rule removeObjectForKey:@"width"]; [rule setObject:@(floating) forKey:@"floating"]; [rule setObject:@(openBesideCurrent) forKey:@"openBesideCurrent"]; [rules setObject:rule forKey:bundleIdentifier]; [next setObject:rules forKey:@"appRules"]; NSData *data=[NSJSONSerialization dataWithJSONObject:next options:NSJSONWritingPrettyPrinted error:error]; if (!data) { [next release]; return NO; } if (!tana_private_atomic_write(_path,data,error)) { [next release]; return NO; } TanaConfigSnapshot *snapshot=tana_snapshot(next,_defaultShortcuts); [_document release]; _document=next; [_snapshot release]; _snapshot=[snapshot retain]; return YES; } }
- (void)dealloc { [_path release]; [_defaultShortcuts release]; [_snapshot release]; [_document release]; [_lastError release]; [super dealloc]; }
@end
