// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeymapviewer.h - MacOS X Cocoa debug keyboard shortcut editor
//
//  A simple preferences window that lists every remappable
//  debugger action and lets the user record a new shortcut for
//  the selected one.  Edits go straight into the shared
//  MAMEDebugKeyMap, which persists them in the debugger config.
//
//============================================================
#ifndef MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAPVIEWER_H
#define MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAPVIEWER_H

#import <Cocoa/Cocoa.h>


@interface MAMEKeyBindingsWindow : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
	NSWindow    *window;
	NSTableView *table;
	NSButton    *recordButton;
	NSButton    *clearButton;
	NSButton    *resetButton;
	NSTextField *statusField;
	NSArray     *identifiers;       // ordered action identifiers
	id          eventMonitor;       // local key-down monitor while recording
	BOOL        recording;
}

// shared single-instance editor window
+ (MAMEKeyBindingsWindow *)sharedInstance;

- (void)activate;

- (IBAction)beginRecording:(id)sender;
- (IBAction)clearSelected:(id)sender;
- (IBAction)resetAll:(id)sender;

@end

#endif // MAME_OSD_MODULES_DEBUGGER_OSX_DEBUGKEYMAPVIEWER_H
