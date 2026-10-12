#ifndef TANA_CONFIG_H
#define TANA_CONFIG_H

#import <Foundation/Foundation.h>

/* This file intentionally has no yabai types.  A caller supplies defaults and
 * holds a copied snapshot while processing input on another thread. */
typedef NS_ENUM(NSInteger, TanaAutofocusMode) {
    TanaAutofocusPointerMovement = 0,
    TanaAutofocusAfterScroll = 1,
};

@interface TanaShortcutBinding : NSObject <NSCopying> {
@private
    unsigned short _keyCode;
    NSUInteger _modifiers;
    NSString *_action;
}
@property(nonatomic, readonly) unsigned short keyCode;
@property(nonatomic, readonly) NSUInteger modifiers;
@property(nonatomic, readonly, copy) NSString *action;
- (id)initWithKeyCode:(unsigned short)keyCode modifiers:(NSUInteger)modifiers action:(NSString *)action;
@end

@interface TanaAppRule : NSObject <NSCopying> {
@private
    NSString *_bundleIdentifier;
    double _width;
    BOOL _widthIsFraction;
    BOOL _floating;
    BOOL _openBesideCurrent;
}
@property(nonatomic, readonly, copy) NSString *bundleIdentifier;
@property(nonatomic, readonly) double width; /* 0 is unspecified; 0 < width <= 1 is fractional */
@property(nonatomic, readonly) BOOL widthIsFraction;
@property(nonatomic, readonly) BOOL floating;
@property(nonatomic, readonly) BOOL openBesideCurrent;
- (id)initWithBundleIdentifier:(NSString *)bundleIdentifier width:(double)width widthIsFraction:(BOOL)widthIsFraction floating:(BOOL)floating openBesideCurrent:(BOOL)openBesideCurrent;
@end

@interface TanaConfigSnapshot : NSObject <NSCopying> {
@private
    double _motionStrength;
    TanaAutofocusMode _autofocusMode;
    BOOL _showStripMap;
    NSArray *_stripWidths;
    NSDictionary *_shortcuts;
    NSDictionary *_appRules;
    NSArray *_shortcutConflicts;
    NSDictionary *_settings;
    NSArray *_diagnostics;
    NSDictionary *_ruleProperties;
    NSArray *_windowRules;
}
@property(nonatomic, readonly) double motionStrength;
@property(nonatomic, readonly) TanaAutofocusMode autofocusMode;
@property(nonatomic, readonly) BOOL showStripMap;
@property(nonatomic, readonly, copy) NSArray *stripWidths;
@property(nonatomic, readonly, copy) NSDictionary *shortcuts; /* action -> TanaShortcutBinding */
@property(nonatomic, readonly, copy) NSArray *shortcutConflicts; /* action names rejected as duplicate */
/* Human-readable problems found while reading the file: unreadable bindings,
 * duplicate shortcuts, and values of the wrong type. Empty when clean. */
@property(nonatomic, readonly, copy) NSArray *diagnostics;
/* Typed lookups into "settings" by dotted path, e.g. @"border.width". A value
 * of the wrong type or outside [minimum, maximum] yields the fallback. */
- (double)numberAt:(NSString *)path fallback:(double)fallback minimum:(double)minimum maximum:(double)maximum;
- (BOOL)boolAt:(NSString *)path fallback:(BOOL)fallback;
- (NSString *)stringAt:(NSString *)path fallback:(NSString *)fallback;
- (BOOL)hasValueAt:(NSString *)path;
- (id)valueAt:(NSString *)path;
- (NSString *)actionForKeyCode:(unsigned short)keyCode modifiers:(NSUInteger)modifiers;
- (TanaAppRule *)ruleForBundleIdentifier:(NSString *)bundleIdentifier;
/* Everything the rules say about one window, or nil when none applies: the
 * "appRules" entry for its application overlaid with the first "windowRules"
 * entry whose "app" and "title" both match. Keys: width, autoWidth, floating,
 * openBesideCurrent, strip (NSNumber index or NSString name), column
 * ("start"/"end"), tabbed, opacity, noBorder, sticky, corner, titleMatched. */
- (NSDictionary *)propertiesForBundleIdentifier:(NSString *)bundleIdentifier title:(NSString *)title;
/* YES when some rule can only be decided once a window has a title. */
@property(nonatomic, readonly) BOOL hasTitleRules;
@end

@interface TanaConfig : NSObject {
@private
    NSString *_path;
    NSDictionary *_defaultShortcuts;
    TanaConfigSnapshot *_snapshot;
    NSMutableDictionary *_document;
    NSString *_lastError;
}
/* defaultShortcuts is action -> binding, e.g. @{ @"toggle-strip": @"ctrl+alt+t" }. */
- (id)initWithPath:(NSString *)path defaultShortcuts:(NSDictionary *)defaultShortcuts;
+ (NSString *)defaultPath;
/* YES installs a complete immutable replacement.  NO leaves the prior snapshot untouched. */
- (BOOL)reload:(NSError **)error;
/* Returns retained; the caller must release it. */
- (TanaConfigSnapshot *)copySnapshot;
@property(nonatomic, readonly, copy) NSString *path;
@property(nonatomic, readonly, copy) NSString *lastError;
/* Updates only the appRules entry and atomically writes the private file. */
- (BOOL)rememberRuleForBundleIdentifier:(NSString *)bundleIdentifier width:(double)width floating:(BOOL)floating openBesideCurrent:(BOOL)openBesideCurrent error:(NSError **)error;
@end

/* Parses #rgb, #rgba, #rrggbb and #rrggbbaa. Returns NO and leaves rgba alone otherwise. */
BOOL TanaParseColor(NSString *text, double rgba[4]);
/* Symbols for a binding, e.g. "⌥⌘←". */
NSString *TanaBindingDescription(TanaShortcutBinding *binding);

#endif
