// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugosx.m - MacOS X Cocoa debug window handling
//
//============================================================


// TODO:
//  * Automatic scrolling for console view
//  * Keyboard shortcuts in error log and device windows
//  * Don't accept keyboard input while the game is running
//  * Interior focus rings - standard/exterior focus rings look really ugly here
//  * Updates causing debug views' widths to change are sometimes obscured by the scroll views' opaque backgrounds
//  * Scroll views with content narrower than clipping area are flaky under Tiger - nothing I can do about this


// MAME headers
#include "emu.h"
#include "config.h"
#include "debugger.h"

// MAMEOS headers
#include "modules/lib/osdobj_common.h"
#include "osx/debugosx.h"
#include "debug_module.h"

#import "osx/debugconsole.h"
#import "osx/debugkeymap.h"
#import "osx/debugwindowhandler.h"

#include "util/xmlfile.h"

#include <atomic>


//============================================================
//  MODULE SUPPORT
//============================================================

class debugger_osx : public osd_module, public debug_module
{
public:
	debugger_osx() :
		osd_module(OSD_DEBUG_PROVIDER, "osx"),
		debug_module(),
		m_machine(nullptr),
		m_console(nil),
		m_config()
	{
	}

	virtual ~debugger_osx()
	{
		if (m_console != nil)
			[m_console release];
	}

	virtual int init(osd_interface &osd, const osd_options &options) override;
	virtual void exit() override;

	virtual void init_debugger(running_machine &machine) override;
	virtual void wait_for_debugger(device_t &device, bool firststop) override;
	virtual void debugger_update() override;

private:
	void create_console();
	void build_menus();
	void config_load(config_type cfgtype, config_level cfglevel, util::xml::data_node const *parentnode);
	void config_save(config_type cfgtype, util::xml::data_node *parentnode);

	running_machine *m_machine;
	MAMEDebugConsole *m_console;
	util::xml::file::ptr m_config;

	static std::atomic_bool s_added_menus;
};

MODULE_DEFINITION(DEBUG_OSX, debugger_osx)

std::atomic_bool debugger_osx::s_added_menus(false);


//============================================================
//  debugger_osx::init
//  initialise debugger module
//============================================================

int debugger_osx::init(osd_interface &osd, const osd_options &options)
{
	return 0;
}


//============================================================
//  debugger_osx::exit
//  clean up debugger module
//============================================================

void debugger_osx::exit()
{
	if (m_console)
	{
		NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
		NSDictionary *info = [NSDictionary dictionaryWithObject:[NSValue valueWithPointer:m_machine]
														 forKey:@"MAMEDebugMachine"];
		[[NSNotificationCenter defaultCenter] postNotificationName:MAMEHideDebuggerNotification
															object:m_console
														  userInfo:info];
		[m_console release];
		m_console = nil;
		m_machine = nullptr;
		[pool release];
	}
}

//============================================================
//  debugger_osx::init_debugger
//  attach debugger module to a machine
//============================================================

void debugger_osx::init_debugger(running_machine &machine)
{
	m_machine = &machine;
	machine.configuration().config_register(
			"debugger",
			configuration_manager::load_delegate(&debugger_osx::config_load, this),
			configuration_manager::save_delegate(&debugger_osx::config_save, this));
}


//============================================================
//  debugger_osx::wait_for_debugger
//  perform debugger event processing
//============================================================

void debugger_osx::wait_for_debugger(device_t &device, bool firststop)
{
	NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];

	// create a console window
	create_console();

	// make sure the debug windows are visible
	if (firststop)
	{
		if (m_config)
		{
			[m_console loadConfiguration:m_config->get_first_child()];
			m_config.reset();
		}
		NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:[NSValue valueWithPointer:&device],
																		@"MAMEDebugDevice",
																		[NSValue valueWithPointer:m_machine],
																		@"MAMEDebugMachine",
																		nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:MAMEShowDebuggerNotification
															object:m_console
														  userInfo:info];
	}

	// get and process messages
	NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
									 untilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]
										inMode:NSDefaultRunLoopMode
									   dequeue:YES];
	if (ev != nil)
		[NSApp sendEvent:ev];

	[pool release];
}


//============================================================
//  debugger_osx::debugger_update
//============================================================

void debugger_osx::debugger_update()
{
}


//============================================================
//  debugger_osx::create_console
//  create main debugger window if we haven't already done so
//============================================================

void debugger_osx::create_console()
{
	if (m_console == nil)
	{
		build_menus();
		m_console = [[MAMEDebugConsole alloc] initWithMachine:*m_machine];
	}
}


//============================================================
//  debugger_osx::build_menus
//  extend global menu bar with debugging options
//============================================================

void debugger_osx::build_menus()
{
	if (!s_added_menus.exchange(true, std::memory_order_relaxed))
	{
		NSMenuItem *item;

		NSMenu *const editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
		item = [[NSApp mainMenu] insertItemWithTitle:@"Edit" action:NULL keyEquivalent:@"" atIndex:1];
		[item setSubmenu:editMenu];
		[editMenu release];

		[editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
		[editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
		[editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];

		MAMEDebugKeyMap *const keys = [MAMEDebugKeyMap sharedKeyMap];

		NSMenu *const debugMenu = [[NSMenu alloc] initWithTitle:@"Debug"];
		item = [[NSApp mainMenu] insertItemWithTitle:@"Debug" action:NULL keyEquivalent:@"" atIndex:2];
		[item setSubmenu:debugMenu];
		[debugMenu release];

		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"New Memory Window"
												  action:@selector(debugNewMemoryWindow:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionNewMemoryWindow];
		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"New Disassembly Window"
												  action:@selector(debugNewDisassemblyWindow:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionNewDisassemblyWindow];
		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"New Error Log Window"
												  action:@selector(debugNewErrorLogWindow:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionNewErrorLogWindow];
		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"New (Break|Watch)points Window"
												  action:@selector(debugNewPointsWindow:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionNewPointsWindow];
		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"New Devices Window"
												  action:@selector(debugNewDevicesWindow:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionNewDevicesWindow];

		[debugMenu addItem:[NSMenuItem separatorItem]];

		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"Soft Reset"
												  action:@selector(debugSoftReset:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionSoftReset];
		[keys applyToMenuItem:[debugMenu addItemWithTitle:@"Hard Reset"
												  action:@selector(debugHardReset:)
										   keyEquivalent:@""]
					forAction:MAMEDebugActionHardReset];

		[debugMenu addItem:[NSMenuItem separatorItem]];

		[debugMenu addItemWithTitle:@"Customize Keys…"
							 action:@selector(showKeyBindings:)
					  keyEquivalent:@""];

		NSMenu *const runMenu = [[NSMenu alloc] initWithTitle:@"Run"];
		item = [[NSApp mainMenu] insertItemWithTitle:@"Run"
											  action:NULL
									   keyEquivalent:@""
											 atIndex:([[NSApp mainMenu] indexOfItemWithSubmenu:debugMenu] + 1)];
		[item setSubmenu:runMenu];
		[runMenu release];

		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Break"
												action:@selector(debugBreak:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionBreak];

		[runMenu addItem:[NSMenuItem separatorItem]];

		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run"
												action:@selector(debugRun:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRun];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run and Hide Debugger"
												action:@selector(debugRunAndHide:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRunAndHide];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run to Next CPU"
												action:@selector(debugRunToNextCPU:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRunToNextCPU];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run until Next Interrupt on Current CPU"
												action:@selector(debugRunToNextInterrupt:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRunToNextInterrupt];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run until Next VBLANK"
												action:@selector(debugRunToNextVBLANK:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRunToNextVBLANK];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Run to Cursor"
												action:@selector(debugRunToCursor:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionRunToCursor];

		[runMenu addItem:[NSMenuItem separatorItem]];

		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Step Into"
												action:@selector(debugStepInto:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionStepInto];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Step Over"
												action:@selector(debugStepOver:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionStepOver];
		[keys applyToMenuItem:[runMenu addItemWithTitle:@"Step Out"
												action:@selector(debugStepOut:)
										 keyEquivalent:@""]
					forAction:MAMEDebugActionStepOut];
	}
}


//============================================================
//  debugger_osx::config_load
//  restore state based on configuration XML
//============================================================

void debugger_osx::config_load(config_type cfgtype, config_level cfglevel, util::xml::data_node const *parentnode)
{
	// keyboard shortcuts are global - they live in default.cfg
	if ((config_type::DEFAULT == cfgtype) && parentnode)
	{
		util::xml::data_node const *const keymap = parentnode->get_child(osd::debugger::NODE_KEYMAP);
		if (keymap)
		{
			NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
			[[MAMEDebugKeyMap sharedKeyMap] restoreConfigurationFromNode:keymap];
			[pool release];
		}
		return;
	}

	if ((config_type::SYSTEM == cfgtype) && parentnode)
	{
		if (m_console)
		{
			NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
			[m_console loadConfiguration:parentnode];
			[pool release];
		}
		else
		{
			m_config = util::xml::file::create();
			parentnode->copy_into(*m_config);
		}
	}
}


//============================================================
//  debugger_osx::config_save
//  save state to system XML
//============================================================

void debugger_osx::config_save(config_type cfgtype, util::xml::data_node *parentnode)
{
	// keyboard shortcuts are global - they live in default.cfg
	if (config_type::DEFAULT == cfgtype)
	{
		NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
		util::xml::data_node *const keymap = parentnode->add_child(osd::debugger::NODE_KEYMAP, nullptr);
		if (keymap)
		{
			[[MAMEDebugKeyMap sharedKeyMap] saveConfigurationToNode:keymap];
			if (!keymap->get_first_child())
				keymap->delete_node();  // no overrides - don't clutter default.cfg
		}
		[pool release];
		return;
	}

	if ((config_type::SYSTEM == cfgtype) && m_console)
	{
		NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
		NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:[NSValue valueWithPointer:m_machine],
																		@"MAMEDebugMachine",
																		[NSValue valueWithPointer:parentnode],
																		@"MAMEDebugParentNode",
																		nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:MAMESaveDebuggerConfigurationNotification
															object:m_console
														  userInfo:info];
		[pool release];
	}
}
