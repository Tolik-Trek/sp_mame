// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeyconfig.h - portable remappable debugger key bindings
//
//  Framework-agnostic storage for the debugger's keyboard
//  shortcuts.  Each GUI debugger (Qt, ImGui, Windows) supplies
//  its own table of actions with default shortcuts; this class
//  holds the user's overrides and (de)serialises them through
//  the debugger configuration XML so the bindings survive across
//  sessions.  Shortcuts use a portable textual form such as
//  "Ctrl+Shift+F9" so the same config is understood everywhere.
//
//============================================================
#ifndef MAME_OSD_MODULES_DEBUGGER_DEBUGKEYCONFIG_H
#define MAME_OSD_MODULES_DEBUGGER_DEBUGKEYCONFIG_H

#pragma once

#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace util::xml { class data_node; }


namespace osd::debugger {

//-------------------------------------------------
//  key_shortcut - a key name plus modifier flags
//-------------------------------------------------

struct key_shortcut
{
	std::string key;        // canonical base key name, e.g. "F5", "D", "Up" (empty == unbound)
	bool        ctrl  = false;
	bool        alt   = false;
	bool        shift = false;

	bool empty() const { return key.empty(); }
	bool operator==(key_shortcut const &that) const;
	bool operator!=(key_shortcut const &that) const { return !(*this == that); }

	// portable textual form, e.g. "Ctrl+Shift+F9"
	std::string to_string() const;
	static key_shortcut from_string(std::string_view text);
};


//-------------------------------------------------
//  key_action - one remappable action
//-------------------------------------------------

struct key_action
{
	std::string  id;                // stable identifier stored in the config
	std::string  label;             // human-readable name for the UI
	std::string  group;             // grouping for the UI
	key_shortcut default_shortcut;  // built-in binding
};


//-------------------------------------------------
//  keymap_config - the action table plus overrides
//-------------------------------------------------

class keymap_config
{
public:
	explicit keymap_config(std::vector<key_action> &&actions);

	std::vector<key_action> const &actions() const { return m_actions; }

	// current binding (user override if present, otherwise the default)
	key_shortcut const &shortcut(std::string const &id) const;
	bool is_default(std::string const &id) const;

	// returns the id of an action already bound to sc (skipping exclude_id), or "" if none
	std::string conflicting_action(key_shortcut const &sc, std::string const &exclude_id) const;

	// editing
	void set_shortcut(std::string const &id, key_shortcut const &sc);
	void clear(std::string const &id);
	void reset(std::string const &id);
	void reset_all();
	bool has_overrides() const { return !m_overrides.empty(); }

	// persistence - operate on the parent debugger configuration node
	void save(util::xml::data_node &parentnode) const;   // adds a NODE_KEYMAP child if there are overrides
	void load(util::xml::data_node const &parentnode);    // reads a NODE_KEYMAP child if present

private:
	key_action const *find(std::string const &id) const;

	std::vector<key_action>                        m_actions;
	std::unordered_map<std::string, key_shortcut>  m_overrides;
	key_shortcut const                             m_unbound;  // returned for unknown ids
};

} // namespace osd::debugger

#endif // MAME_OSD_MODULES_DEBUGGER_DEBUGKEYCONFIG_H
