// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeymap.h - MacOS X Cocoa debug keyboard shortcut map
//
//  Central registry of remappable debugger hot keys.  Menu
//  builders consult it instead of hard-coding key equivalents,
//  the preferences window edits it, and it (de)serialises the
//  user's overrides into the debugger configuration XML.
//
//============================================================
#ifndef MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAP_H
#define MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAP_H

#import <Cocoa/Cocoa.h>

#include "../xmlconfig.h"

namespace util::xml { class data_node; }


//============================================================
//  Action identifiers (stable keys used in the config XML)
//============================================================

extern NSString *const MAMEDebugActionBreak;
extern NSString *const MAMEDebugActionRun;
extern NSString *const MAMEDebugActionRunAndHide;
extern NSString *const MAMEDebugActionRunToNextCPU;
extern NSString *const MAMEDebugActionRunToNextInterrupt;
extern NSString *const MAMEDebugActionRunToNextVBLANK;
extern NSString *const MAMEDebugActionRunToCursor;
extern NSString *const MAMEDebugActionStepInto;
extern NSString *const MAMEDebugActionStepOver;
extern NSString *const MAMEDebugActionStepOut;
extern NSString *const MAMEDebugActionSoftReset;
extern NSString *const MAMEDebugActionHardReset;
extern NSString *const MAMEDebugActionNewMemoryWindow;
extern NSString *const MAMEDebugActionNewDisassemblyWindow;
extern NSString *const MAMEDebugActionNewErrorLogWindow;
extern NSString *const MAMEDebugActionNewPointsWindow;
extern NSString *const MAMEDebugActionNewDevicesWindow;
extern NSString *const MAMEDebugActionCloseWindow;
extern NSString *const MAMEDebugActionQuit;
extern NSString *const MAMEDebugActionToggleBreakpoint;
extern NSString *const MAMEDebugActionDisableBreakpoint;
extern NSString *const MAMEDebugActionShowRawOpcodes;
extern NSString *const MAMEDebugActionShowEncryptedOpcodes;
extern NSString *const MAMEDebugActionShowComments;


// posted (object == shared keymap) whenever a binding changes so open menus can refresh
extern NSString *const MAMEDebugKeyMapChangedNotification;


//============================================================
//  MAMEDebugKeyMap
//============================================================

@interface MAMEDebugKeyMap : NSObject
{
	NSArray             *order;     // action identifiers in display order
	NSDictionary        *defaults;  // identifier -> default MAMEDebugKeyBinding
	NSMutableDictionary *current;   // identifier -> current MAMEDebugKeyBinding
}

+ (MAMEDebugKeyMap *)sharedKeyMap;

// metadata for the preferences window
- (NSArray *)actionIdentifiers;                         // ordered list
- (NSString *)labelForAction:(NSString *)identifier;    // human readable name
- (NSString *)groupForAction:(NSString *)identifier;    // grouping name

// current binding for an action
- (NSString *)keyEquivalentForAction:(NSString *)identifier;
- (NSUInteger)modifierMaskForAction:(NSString *)identifier;
- (BOOL)isDefaultForAction:(NSString *)identifier;

// a printable description of the current shortcut (e.g. "⇧F9", "⌘D", "F5")
- (NSString *)displayStringForAction:(NSString *)identifier;
- (NSString *)displayStringForKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask;

// editing - posts MAMEDebugKeyMapChangedNotification
- (void)setKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask forAction:(NSString *)identifier;
- (void)clearAction:(NSString *)identifier;             // remove the shortcut
- (void)resetActionToDefault:(NSString *)identifier;
- (void)resetAllToDefaults;

// returns the identifier of an action that already uses this shortcut (or nil), ignoring excludeIdentifier
- (NSString *)actionUsingKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask excluding:(NSString *)excludeIdentifier;

// apply the current binding for identifier to a freshly created menu item (also tags it for refreshMenu:)
- (void)applyToMenuItem:(NSMenuItem *)item forAction:(NSString *)identifier;

// re-apply current bindings to every tagged item in a menu tree (after a change)
- (void)refreshMenu:(NSMenu *)menu;

// persistence into the debugger configuration XML
- (void)saveConfigurationToNode:(util::xml::data_node *)node;
- (void)restoreConfigurationFromNode:(util::xml::data_node const *)node;

@end

#endif // MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAP_H
