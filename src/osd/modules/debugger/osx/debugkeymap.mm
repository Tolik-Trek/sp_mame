// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeymap.mm - MacOS X Cocoa debug keyboard shortcut map
//
//============================================================

#include "emu.h"
#import "debugkeymap.h"

#include "util/xmlfile.h"


//============================================================
//  Action identifiers
//============================================================

NSString *const MAMEDebugActionBreak               = @"break";
NSString *const MAMEDebugActionRun                 = @"run";
NSString *const MAMEDebugActionRunAndHide          = @"runAndHide";
NSString *const MAMEDebugActionRunToNextCPU        = @"runToNextCPU";
NSString *const MAMEDebugActionRunToNextInterrupt  = @"runToNextInterrupt";
NSString *const MAMEDebugActionRunToNextVBLANK     = @"runToNextVBLANK";
NSString *const MAMEDebugActionRunToCursor         = @"runToCursor";
NSString *const MAMEDebugActionStepInto            = @"stepInto";
NSString *const MAMEDebugActionStepOver            = @"stepOver";
NSString *const MAMEDebugActionStepOut             = @"stepOut";
NSString *const MAMEDebugActionSoftReset           = @"softReset";
NSString *const MAMEDebugActionHardReset           = @"hardReset";
NSString *const MAMEDebugActionNewMemoryWindow     = @"newMemoryWindow";
NSString *const MAMEDebugActionNewDisassemblyWindow = @"newDisassemblyWindow";
NSString *const MAMEDebugActionNewErrorLogWindow   = @"newErrorLogWindow";
NSString *const MAMEDebugActionNewPointsWindow     = @"newPointsWindow";
NSString *const MAMEDebugActionNewDevicesWindow    = @"newDevicesWindow";
NSString *const MAMEDebugActionCloseWindow         = @"closeWindow";
NSString *const MAMEDebugActionQuit                = @"quit";
NSString *const MAMEDebugActionToggleBreakpoint    = @"toggleBreakpoint";
NSString *const MAMEDebugActionDisableBreakpoint   = @"disableBreakpoint";
NSString *const MAMEDebugActionShowRawOpcodes      = @"showRawOpcodes";
NSString *const MAMEDebugActionShowEncryptedOpcodes = @"showEncryptedOpcodes";
NSString *const MAMEDebugActionShowComments        = @"showComments";

NSString *const MAMEDebugKeyMapChangedNotification = @"MAMEDebugKeyMapChangedNotification";


//============================================================
//  MAMEDebugKeyBinding - a single editable shortcut
//============================================================

@interface MAMEDebugKeyBinding : NSObject
{
@public
	NSString    *key;   // key equivalent (may be empty)
	NSUInteger  mask;   // modifier flags
}
- (id)initWithKey:(NSString *)k mask:(NSUInteger)m;
@end

@implementation MAMEDebugKeyBinding

- (id)initWithKey:(NSString *)k mask:(NSUInteger)m {
	if (!(self = [super init]))
		return nil;
	key = [(k ? k : @"") copy];
	mask = m;
	return self;
}

- (void)dealloc {
	[key release];
	[super dealloc];
}

@end


//============================================================
//  MAMEDebugActionInfo - immutable per-action metadata + default
//============================================================

@interface MAMEDebugActionInfo : NSObject
{
@public
	NSString    *label;
	NSString    *group;
	NSString    *defaultKey;
	NSUInteger  defaultMask;
}
@end

@implementation MAMEDebugActionInfo
- (void)dealloc {
	[label release];
	[group release];
	[defaultKey release];
	[super dealloc];
}
@end


//============================================================
//  helpers
//============================================================

static NSString *KeyForFunction(unichar c)
{
	return [NSString stringWithFormat:@"%C", c];
}


@implementation MAMEDebugKeyMap

+ (MAMEDebugKeyMap *)sharedKeyMap {
	static MAMEDebugKeyMap *instance = nil;
	if (instance == nil)
		instance = [[MAMEDebugKeyMap alloc] init];
	return instance;
}


- (MAMEDebugActionInfo *)infoWithLabel:(NSString *)label
								  group:(NSString *)group
									key:(NSString *)key
								   mask:(NSUInteger)mask {
	MAMEDebugActionInfo *info = [[[MAMEDebugActionInfo alloc] init] autorelease];
	info->label = [label copy];
	info->group = [group copy];
	info->defaultKey = [(key ? key : @"") copy];
	info->defaultMask = mask;
	return info;
}


- (id)init {
	if (!(self = [super init]))
		return nil;

	NSUInteger const cmd = NSEventModifierFlagCommand;
	NSUInteger const shift = NSEventModifierFlagShift;

	// ordered table of actions: identifier -> metadata + default shortcut
	NSMutableArray *ord = [NSMutableArray array];
	NSMutableDictionary *def = [NSMutableDictionary dictionary];

	void (^add)(NSString *, NSString *, NSString *, NSString *, NSUInteger) =
		^(NSString *ident, NSString *label, NSString *group, NSString *key, NSUInteger mask) {
			[ord addObject:ident];
			[def setObject:[self infoWithLabel:label group:group key:key mask:mask] forKey:ident];
		};

	add(MAMEDebugActionBreak,              @"Break",                                    @"Execution", @"",                            0);
	add(MAMEDebugActionRun,                @"Run",                                      @"Execution", KeyForFunction(NSF5FunctionKey),  0);
	add(MAMEDebugActionRunAndHide,         @"Run and Hide Debugger",                    @"Execution", KeyForFunction(NSF12FunctionKey), 0);
	add(MAMEDebugActionRunToNextCPU,       @"Run to Next CPU",                          @"Execution", KeyForFunction(NSF6FunctionKey),  0);
	add(MAMEDebugActionRunToNextInterrupt, @"Run until Next Interrupt on Current CPU",  @"Execution", KeyForFunction(NSF7FunctionKey),  0);
	add(MAMEDebugActionRunToNextVBLANK,    @"Run until Next VBLANK",                    @"Execution", KeyForFunction(NSF8FunctionKey),  0);
	add(MAMEDebugActionRunToCursor,        @"Run to Cursor",                            @"Execution", KeyForFunction(NSF4FunctionKey),  0);
	add(MAMEDebugActionStepInto,           @"Step Into",                                @"Execution", KeyForFunction(NSF11FunctionKey), 0);
	add(MAMEDebugActionStepOver,           @"Step Over",                                @"Execution", KeyForFunction(NSF10FunctionKey), 0);
	add(MAMEDebugActionStepOut,            @"Step Out",                                 @"Execution", KeyForFunction(NSF10FunctionKey), shift);
	add(MAMEDebugActionSoftReset,          @"Soft Reset",                               @"Execution", KeyForFunction(NSF3FunctionKey),  0);
	add(MAMEDebugActionHardReset,          @"Hard Reset",                               @"Execution", KeyForFunction(NSF3FunctionKey),  shift);

	add(MAMEDebugActionToggleBreakpoint,   @"Toggle Breakpoint at Cursor",              @"Disassembly", KeyForFunction(NSF9FunctionKey), 0);
	add(MAMEDebugActionDisableBreakpoint,  @"Disable Breakpoint at Cursor",             @"Disassembly", KeyForFunction(NSF9FunctionKey), shift);
	add(MAMEDebugActionShowRawOpcodes,     @"Show Raw Opcodes",                         @"Disassembly", @"r", cmd);
	add(MAMEDebugActionShowEncryptedOpcodes, @"Show Encrypted Opcodes",                 @"Disassembly", @"e", cmd);
	add(MAMEDebugActionShowComments,       @"Show Comments",                            @"Disassembly", @"n", cmd);

	add(MAMEDebugActionNewMemoryWindow,    @"New Memory Window",                        @"Windows", @"d", cmd);
	add(MAMEDebugActionNewDisassemblyWindow, @"New Disassembly Window",                 @"Windows", @"a", cmd);
	add(MAMEDebugActionNewErrorLogWindow,  @"New Error Log Window",                     @"Windows", @"l", cmd);
	add(MAMEDebugActionNewPointsWindow,    @"New (Break|Watch)points Window",           @"Windows", @"b", cmd);
	add(MAMEDebugActionNewDevicesWindow,   @"New Devices Window",                       @"Windows", @"D", cmd);
	add(MAMEDebugActionCloseWindow,        @"Close Window",                             @"Windows", @"w", cmd);
	add(MAMEDebugActionQuit,               @"Quit",                                     @"Windows", @"q", cmd);

	order = [ord copy];
	defaults = [def copy];
	current = [[NSMutableDictionary alloc] init];
	for (NSString *ident in order)
	{
		MAMEDebugActionInfo *info = [defaults objectForKey:ident];
		[current setObject:[[[MAMEDebugKeyBinding alloc] initWithKey:info->defaultKey mask:info->defaultMask] autorelease]
				   forKey:ident];
	}

	return self;
}


- (void)dealloc {
	[order release];
	[defaults release];
	[current release];
	[super dealloc];
}


- (NSArray *)actionIdentifiers {
	return order;
}


- (NSString *)labelForAction:(NSString *)identifier {
	MAMEDebugActionInfo *info = [defaults objectForKey:identifier];
	return info ? info->label : identifier;
}


- (NSString *)groupForAction:(NSString *)identifier {
	MAMEDebugActionInfo *info = [defaults objectForKey:identifier];
	return info ? info->group : @"";
}


- (NSString *)keyEquivalentForAction:(NSString *)identifier {
	MAMEDebugKeyBinding *b = [current objectForKey:identifier];
	return b ? b->key : @"";
}


- (NSUInteger)modifierMaskForAction:(NSString *)identifier {
	MAMEDebugKeyBinding *b = [current objectForKey:identifier];
	return b ? b->mask : 0;
}


- (BOOL)isDefaultForAction:(NSString *)identifier {
	MAMEDebugActionInfo *info = [defaults objectForKey:identifier];
	MAMEDebugKeyBinding *b = [current objectForKey:identifier];
	if (!info || !b)
		return YES;
	return (b->mask == info->defaultMask) && [b->key isEqualToString:info->defaultKey];
}


- (NSString *)displayStringForKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask {
	if ([keyEquivalent length] == 0)
		return @"None";

	NSMutableString *result = [NSMutableString string];
	if (mask & NSEventModifierFlagControl)  [result appendString:@"⌃"]; // ⌃
	if (mask & NSEventModifierFlagOption)   [result appendString:@"⌥"]; // ⌥
	if (mask & NSEventModifierFlagShift)    [result appendString:@"⇧"]; // ⇧
	if (mask & NSEventModifierFlagCommand)  [result appendString:@"⌘"]; // ⌘

	unichar c = [keyEquivalent characterAtIndex:0];
	if (c >= NSF1FunctionKey && c <= NSF35FunctionKey)
		[result appendFormat:@"F%d", (int)(c - NSF1FunctionKey + 1)];
	else switch (c)
	{
	case NSUpArrowFunctionKey:    [result appendString:@"↑"]; break; // ↑
	case NSDownArrowFunctionKey:  [result appendString:@"↓"]; break; // ↓
	case NSLeftArrowFunctionKey:  [result appendString:@"←"]; break; // ←
	case NSRightArrowFunctionKey: [result appendString:@"→"]; break; // →
	case 0x7F:
	case NSDeleteFunctionKey:     [result appendString:@"⌦"]; break; // ⌦
	case NSHomeFunctionKey:       [result appendString:@"Home"]; break;
	case NSEndFunctionKey:        [result appendString:@"End"]; break;
	case NSPageUpFunctionKey:     [result appendString:@"PgUp"]; break;
	case NSPageDownFunctionKey:   [result appendString:@"PgDn"]; break;
	case 0x1B:                    [result appendString:@"⎋"]; break; // ⎋ esc
	case 0x0D: case 0x03:         [result appendString:@"↩"]; break; // ↩ return
	case 0x09:                    [result appendString:@"⇥"]; break; // ⇥ tab
	case ' ':                     [result appendString:@"Space"]; break;
	default:                      [result appendString:[[keyEquivalent uppercaseString] substringToIndex:1]]; break;
	}
	return result;
}


- (NSString *)displayStringForAction:(NSString *)identifier {
	return [self displayStringForKeyEquivalent:[self keyEquivalentForAction:identifier]
								  modifierMask:[self modifierMaskForAction:identifier]];
}


- (void)setKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask forAction:(NSString *)identifier {
	if (![defaults objectForKey:identifier])
		return;
	[current setObject:[[[MAMEDebugKeyBinding alloc] initWithKey:keyEquivalent mask:mask] autorelease]
			   forKey:identifier];
	[[NSNotificationCenter defaultCenter] postNotificationName:MAMEDebugKeyMapChangedNotification object:self];
}


- (void)clearAction:(NSString *)identifier {
	[self setKeyEquivalent:@"" modifierMask:0 forAction:identifier];
}


- (void)resetActionToDefault:(NSString *)identifier {
	MAMEDebugActionInfo *info = [defaults objectForKey:identifier];
	if (info)
		[self setKeyEquivalent:info->defaultKey modifierMask:info->defaultMask forAction:identifier];
}


- (void)resetAllToDefaults {
	for (NSString *ident in order)
	{
		MAMEDebugActionInfo *info = [defaults objectForKey:ident];
		[current setObject:[[[MAMEDebugKeyBinding alloc] initWithKey:info->defaultKey mask:info->defaultMask] autorelease]
				   forKey:ident];
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:MAMEDebugKeyMapChangedNotification object:self];
}


- (NSString *)actionUsingKeyEquivalent:(NSString *)keyEquivalent modifierMask:(NSUInteger)mask excluding:(NSString *)excludeIdentifier {
	if ([keyEquivalent length] == 0)
		return nil;
	for (NSString *ident in order)
	{
		if (excludeIdentifier && [ident isEqualToString:excludeIdentifier])
			continue;
		MAMEDebugKeyBinding *b = [current objectForKey:ident];
		if (b && (b->mask == mask) && [b->key isEqualToString:keyEquivalent])
			return ident;
	}
	return nil;
}


- (void)applyToMenuItem:(NSMenuItem *)item forAction:(NSString *)identifier {
	[item setKeyEquivalent:[self keyEquivalentForAction:identifier]];
	[item setKeyEquivalentModifierMask:[self modifierMaskForAction:identifier]];
	[item setRepresentedObject:identifier];
}


- (void)refreshMenu:(NSMenu *)menu {
	for (NSMenuItem *item in [menu itemArray])
	{
		id rep = [item representedObject];
		if ([rep isKindOfClass:[NSString class]] && [defaults objectForKey:rep])
		{
			[item setKeyEquivalent:[self keyEquivalentForAction:rep]];
			[item setKeyEquivalentModifierMask:[self modifierMaskForAction:rep]];
		}
		if ([item submenu])
			[self refreshMenu:[item submenu]];
	}
}


//============================================================
//  persistence
//============================================================

- (void)saveConfigurationToNode:(util::xml::data_node *)node {
	// only write entries that differ from the built-in defaults
	for (NSString *ident in order)
	{
		if ([self isDefaultForAction:ident])
			continue;
		MAMEDebugKeyBinding *b = [current objectForKey:ident];
		util::xml::data_node *const item = node->add_child(osd::debugger::NODE_KEYMAP_ITEM, nullptr);
		if (!item)
			continue;
		item->set_attribute(osd::debugger::ATTR_KEYMAP_ACTION, [ident UTF8String]);
		item->set_attribute_int(osd::debugger::ATTR_KEYMAP_KEY,
								([b->key length] > 0) ? (int)[b->key characterAtIndex:0] : 0);
		item->set_attribute_int(osd::debugger::ATTR_KEYMAP_MODIFIERS, (int)b->mask);
	}
}


- (void)restoreConfigurationFromNode:(util::xml::data_node const *)node {
	for (util::xml::data_node const *item = node->get_child(osd::debugger::NODE_KEYMAP_ITEM);
		 item;
		 item = item->get_next_sibling(osd::debugger::NODE_KEYMAP_ITEM))
	{
		char const *const action = item->get_attribute_string(osd::debugger::ATTR_KEYMAP_ACTION, nullptr);
		if (!action)
			continue;
		NSString *const ident = [NSString stringWithUTF8String:action];
		if (![defaults objectForKey:ident])
			continue;
		int const code = item->get_attribute_int(osd::debugger::ATTR_KEYMAP_KEY, 0);
		NSUInteger const mask = (NSUInteger)item->get_attribute_int(osd::debugger::ATTR_KEYMAP_MODIFIERS, 0);
		NSString *const key = (code > 0) ? [NSString stringWithFormat:@"%C", (unichar)code] : @"";
		[current setObject:[[[MAMEDebugKeyBinding alloc] initWithKey:key mask:mask] autorelease]
				   forKey:ident];
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:MAMEDebugKeyMapChangedNotification object:self];
}

@end
