// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeymapviewer.mm - MacOS X Cocoa debug keyboard shortcut editor
//
//============================================================

#include "emu.h"
#import "debugkeymapviewer.h"

#import "debugkeymap.h"


@interface MAMEKeyBindingsWindow ()
- (void)stopRecording;
- (void)handleRecordedEvent:(NSEvent *)event;
- (void)keyMapChanged:(NSNotification *)notification;
@end


@implementation MAMEKeyBindingsWindow

+ (MAMEKeyBindingsWindow *)sharedInstance {
	static MAMEKeyBindingsWindow *instance = nil;
	if (instance == nil)
		instance = [[MAMEKeyBindingsWindow alloc] init];
	return instance;
}


- (id)init {
	if (!(self = [super init]))
		return nil;

	identifiers = [[[MAMEDebugKeyMap sharedKeyMap] actionIdentifiers] copy];
	recording = NO;
	eventMonitor = nil;

	NSRect const contentRect = NSMakeRect(0, 0, 460, 420);
	window = [[NSWindow alloc] initWithContentRect:contentRect
										 styleMask:(NSWindowStyleMaskTitled |
													NSWindowStyleMaskClosable |
													NSWindowStyleMaskMiniaturizable |
													NSWindowStyleMaskResizable)
										   backing:NSBackingStoreBuffered
											 defer:YES];
	[window setReleasedWhenClosed:NO];
	[window setTitle:@"Debugger Keyboard Shortcuts"];
	[window setContentMinSize:NSMakeSize(400, 300)];
	[window setDelegate:self];

	NSView *const content = [window contentView];
	CGFloat const margin = 16;
	CGFloat const buttonHeight = 32;
	CGFloat const bottom = margin + buttonHeight + 8;

	// table inside a scroll view
	NSScrollView *const scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(margin,
																				 bottom,
																				 contentRect.size.width - (2 * margin),
																				 contentRect.size.height - bottom - margin)];
	[scroll setHasVerticalScroller:YES];
	[scroll setHasHorizontalScroller:NO];
	[scroll setAutohidesScrollers:YES];
	[scroll setBorderType:NSBezelBorder];
	[scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	table = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
	[table setAllowsMultipleSelection:NO];
	[table setAllowsColumnReordering:NO];
	[table setUsesAlternatingRowBackgroundColors:YES];
	[table setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];

	NSTableColumn *const actionCol = [[NSTableColumn alloc] initWithIdentifier:@"action"];
	[[actionCol headerCell] setStringValue:@"Action"];
	[actionCol setWidth:230];
	[actionCol setEditable:NO];
	[table addTableColumn:actionCol];
	[actionCol release];

	NSTableColumn *const groupCol = [[NSTableColumn alloc] initWithIdentifier:@"group"];
	[[groupCol headerCell] setStringValue:@"Group"];
	[groupCol setWidth:100];
	[groupCol setEditable:NO];
	[table addTableColumn:groupCol];
	[groupCol release];

	NSTableColumn *const keyCol = [[NSTableColumn alloc] initWithIdentifier:@"shortcut"];
	[[keyCol headerCell] setStringValue:@"Shortcut"];
	[keyCol setWidth:90];
	[keyCol setEditable:NO];
	[table addTableColumn:keyCol];
	[keyCol release];

	[table setDataSource:self];
	[table setDelegate:self];
	[table setDoubleAction:@selector(beginRecording:)];
	[table setTarget:self];
	[scroll setDocumentView:table];
	[content addSubview:scroll];
	[scroll release];

	// buttons along the bottom
	recordButton = [[NSButton alloc] initWithFrame:NSMakeRect(margin, margin, 130, buttonHeight)];
	[recordButton setButtonType:NSButtonTypeMomentaryPushIn];
	[recordButton setBezelStyle:NSBezelStyleRounded];
	[recordButton setTitle:@"Record Shortcut"];
	[recordButton setTarget:self];
	[recordButton setAction:@selector(beginRecording:)];
	[recordButton setAutoresizingMask:NSViewMaxXMargin];
	[content addSubview:recordButton];

	clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(margin + 134, margin, 80, buttonHeight)];
	[clearButton setButtonType:NSButtonTypeMomentaryPushIn];
	[clearButton setBezelStyle:NSBezelStyleRounded];
	[clearButton setTitle:@"Clear"];
	[clearButton setTarget:self];
	[clearButton setAction:@selector(clearSelected:)];
	[clearButton setAutoresizingMask:NSViewMaxXMargin];
	[content addSubview:clearButton];

	resetButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentRect.size.width - margin - 150, margin, 150, buttonHeight)];
	[resetButton setButtonType:NSButtonTypeMomentaryPushIn];
	[resetButton setBezelStyle:NSBezelStyleRounded];
	[resetButton setTitle:@"Reset All to Defaults"];
	[resetButton setTarget:self];
	[resetButton setAction:@selector(resetAll:)];
	[resetButton setAutoresizingMask:NSViewMinXMargin];
	[content addSubview:resetButton];

	statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, bottom - 4, contentRect.size.width - (2 * margin), 16)];
	[statusField setEditable:NO];
	[statusField setSelectable:NO];
	[statusField setBordered:NO];
	[statusField setDrawsBackground:NO];
	[statusField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[statusField setTextColor:[NSColor secondaryLabelColor]];
	[statusField setStringValue:@"Double-click an action or press Record Shortcut, then type the new key combination."];
	[statusField setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
	[content addSubview:statusField];

	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(keyMapChanged:)
												 name:MAMEDebugKeyMapChangedNotification
											   object:nil];

	return self;
}


- (void)dealloc {
	[self stopRecording];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[identifiers release];
	[recordButton release];
	[clearButton release];
	[resetButton release];
	[statusField release];
	[table release];
	if (window != nil)
	{
		[window orderOut:self];
		[window release];
	}
	[super dealloc];
}


- (void)activate {
	[table reloadData];
	[window center];
	[window makeKeyAndOrderFront:self];
}


- (void)keyMapChanged:(NSNotification *)notification {
	// reflect external changes (e.g. config reload) in the table
	if (!recording)
		[table reloadData];
}


//============================================================
//  table data source / delegate
//============================================================

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	return [identifiers count];
}


- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
	if ((row < 0) || (row >= (NSInteger)[identifiers count]))
		return @"";
	MAMEDebugKeyMap *const keys = [MAMEDebugKeyMap sharedKeyMap];
	NSString *const ident = [identifiers objectAtIndex:row];
	NSString *const colID = [column identifier];
	if ([colID isEqualToString:@"action"])
		return [keys labelForAction:ident];
	else if ([colID isEqualToString:@"group"])
		return [keys groupForAction:ident];
	else
		return [keys displayStringForAction:ident];
}


- (void)tableViewSelectionDidChange:(NSNotification *)notification {
	if (recording)
		[self stopRecording];
}


//============================================================
//  recording
//============================================================

- (void)stopRecording {
	if (eventMonitor != nil)
	{
		[NSEvent removeMonitor:eventMonitor];
		eventMonitor = nil;
	}
	recording = NO;
	[recordButton setTitle:@"Record Shortcut"];
}


- (IBAction)beginRecording:(id)sender {
	NSInteger const row = [table selectedRow];
	if (row < 0)
	{
		[statusField setStringValue:@"Select an action first."];
		NSBeep();
		return;
	}
	if (recording)
	{
		[self stopRecording];
		return;
	}

	recording = YES;
	[recordButton setTitle:@"Press keys… (Esc to cancel)"];
	NSString *const ident = [identifiers objectAtIndex:row];
	[statusField setStringValue:[NSString stringWithFormat:@"Recording shortcut for \"%@\" — press a key combination (Delete clears, Esc cancels).",
															[[MAMEDebugKeyMap sharedKeyMap] labelForAction:ident]]];

	// the editor is a long-lived singleton, so capturing self here is safe
	eventMonitor = [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
														  handler:^NSEvent *(NSEvent *event) {
		[self handleRecordedEvent:event];
		return nil; // swallow the key event
	}] retain];
}


- (void)handleRecordedEvent:(NSEvent *)event {
	NSInteger const row = [table selectedRow];
	if (row < 0)
	{
		[self stopRecording];
		return;
	}
	NSString *const ident = [identifiers objectAtIndex:row];
	MAMEDebugKeyMap *const keys = [MAMEDebugKeyMap sharedKeyMap];

	NSString *const chars = [event charactersIgnoringModifiers];
	unichar const code = ([chars length] > 0) ? [chars characterAtIndex:0] : 0;

	// Escape cancels without changing anything
	if (code == 0x1B)
	{
		[self stopRecording];
		[statusField setStringValue:@"Recording cancelled."];
		return;
	}

	// Delete / Backspace clears the binding
	if ((code == 0x7F) || (code == NSDeleteCharacter) || (code == NSDeleteFunctionKey))
	{
		[keys clearAction:ident];
		[self stopRecording];
		[statusField setStringValue:[NSString stringWithFormat:@"Cleared shortcut for \"%@\".", [keys labelForAction:ident]]];
		return;
	}

	if (code == 0)
	{
		[self stopRecording];
		return;
	}

	NSUInteger const mask = [event modifierFlags] &
		(NSEventModifierFlagCommand | NSEventModifierFlagOption |
		 NSEventModifierFlagControl | NSEventModifierFlagShift);

	// store letters in lower case and rely on the shift flag, matching menu conventions
	NSString *key = chars;
	if ((code >= 'A') && (code <= 'Z'))
		key = [chars lowercaseString];

	// check for a conflicting assignment
	NSString *const conflict = [keys actionUsingKeyEquivalent:key modifierMask:mask excluding:ident];
	if (conflict)
	{
		NSString *const shortcut = [keys displayStringForKeyEquivalent:key modifierMask:mask];
		NSAlert *const alert = [[[NSAlert alloc] init] autorelease];
		[alert setMessageText:[NSString stringWithFormat:@"\"%@\" is already used by \"%@\".",
														  shortcut, [keys labelForAction:conflict]]];
		[alert setInformativeText:@"Do you want to reassign it to the selected action?"];
		[alert addButtonWithTitle:@"Reassign"];
		[alert addButtonWithTitle:@"Cancel"];
		[self stopRecording];
		if ([alert runModal] == NSAlertFirstButtonReturn)
		{
			[keys clearAction:conflict];
			[keys setKeyEquivalent:key modifierMask:mask forAction:ident];
			[statusField setStringValue:[NSString stringWithFormat:@"Reassigned %@ to \"%@\".", shortcut, [keys labelForAction:ident]]];
		}
		else
		{
			[statusField setStringValue:@"Recording cancelled."];
		}
		return;
	}

	[keys setKeyEquivalent:key modifierMask:mask forAction:ident];
	[self stopRecording];
	[statusField setStringValue:[NSString stringWithFormat:@"Set %@ for \"%@\".",
															[keys displayStringForAction:ident], [keys labelForAction:ident]]];
}


- (IBAction)clearSelected:(id)sender {
	NSInteger const row = [table selectedRow];
	if (row < 0)
	{
		NSBeep();
		return;
	}
	NSString *const ident = [identifiers objectAtIndex:row];
	[[MAMEDebugKeyMap sharedKeyMap] clearAction:ident];
	[statusField setStringValue:[NSString stringWithFormat:@"Cleared shortcut for \"%@\".",
															[[MAMEDebugKeyMap sharedKeyMap] labelForAction:ident]]];
}


- (IBAction)resetAll:(id)sender {
	[[MAMEDebugKeyMap sharedKeyMap] resetAllToDefaults];
	[statusField setStringValue:@"All shortcuts reset to defaults."];
}


//============================================================
//  window delegate
//============================================================

- (void)windowWillClose:(NSNotification *)notification {
	[self stopRecording];
}

@end
