// license:BSD-3-Clause
// copyright-holders:Vas Crabb
//============================================================
//
//  debugkeyconfig.cpp - portable remappable debugger key bindings
//
//============================================================

#include "debugkeyconfig.h"

#include "xmlconfig.h"

#include "util/xmlfile.h"

#include <algorithm>
#include <cctype>


namespace osd::debugger {

namespace {

std::string trim(std::string_view s)
{
	auto const notspace = [] (unsigned char c) { return !std::isspace(c); };
	auto const begin = std::find_if(s.begin(), s.end(), notspace);
	auto const end = std::find_if(s.rbegin(), std::string_view::const_reverse_iterator(begin), notspace).base();
	return std::string(begin, end);
}

std::string to_lower(std::string_view s)
{
	std::string result(s);
	std::transform(result.begin(), result.end(), result.begin(), [] (unsigned char c) { return std::tolower(c); });
	return result;
}

} // anonymous namespace


//**************************************************************************
//  KEY SHORTCUT
//**************************************************************************

bool key_shortcut::operator==(key_shortcut const &that) const
{
	return (key == that.key) && (ctrl == that.ctrl) && (alt == that.alt) && (shift == that.shift);
}


std::string key_shortcut::to_string() const
{
	if (key.empty())
		return std::string();

	std::string result;
	if (ctrl)
		result += "Ctrl+";
	if (alt)
		result += "Alt+";
	if (shift)
		result += "Shift+";
	result += key;
	return result;
}


key_shortcut key_shortcut::from_string(std::string_view text)
{
	key_shortcut result;
	std::string::size_type start = 0;
	std::string const s(text);
	while (start <= s.length())
	{
		std::string::size_type const plus = s.find('+', start);
		std::string const token = trim((plus == std::string::npos) ? s.substr(start) : s.substr(start, plus - start));
		std::string const lower = to_lower(token);
		bool const last = (plus == std::string::npos);
		if (!last && ((lower == "ctrl") || (lower == "control") || (lower == "cmd") || (lower == "command")))
			result.ctrl = true;
		else if (!last && ((lower == "alt") || (lower == "option") || (lower == "opt")))
			result.alt = true;
		else if (!last && (lower == "shift"))
			result.shift = true;
		else if (!token.empty())
			result.key = token;  // the base key is whatever is not a known modifier (normally last)
		if (last)
			break;
		start = plus + 1;
	}
	return result;
}


//**************************************************************************
//  KEYMAP CONFIG
//**************************************************************************

keymap_config::keymap_config(std::vector<key_action> &&actions) :
	m_actions(std::move(actions))
{
}


key_action const *keymap_config::find(std::string const &id) const
{
	auto const it = std::find_if(
			m_actions.begin(),
			m_actions.end(),
			[&id] (key_action const &a) { return a.id == id; });
	return (it != m_actions.end()) ? &*it : nullptr;
}


key_shortcut const &keymap_config::shortcut(std::string const &id) const
{
	auto const override = m_overrides.find(id);
	if (override != m_overrides.end())
		return override->second;
	key_action const *const action = find(id);
	return action ? action->default_shortcut : m_unbound;
}


bool keymap_config::is_default(std::string const &id) const
{
	return m_overrides.find(id) == m_overrides.end();
}


std::string keymap_config::conflicting_action(key_shortcut const &sc, std::string const &exclude_id) const
{
	if (sc.empty())
		return std::string();
	for (key_action const &action : m_actions)
	{
		if (action.id == exclude_id)
			continue;
		if (shortcut(action.id) == sc)
			return action.id;
	}
	return std::string();
}


void keymap_config::set_shortcut(std::string const &id, key_shortcut const &sc)
{
	key_action const *const action = find(id);
	if (!action)
		return;
	if (sc == action->default_shortcut)
		m_overrides.erase(id);  // back to default - drop the override
	else
		m_overrides[id] = sc;
}


void keymap_config::clear(std::string const &id)
{
	set_shortcut(id, key_shortcut());
}


void keymap_config::reset(std::string const &id)
{
	m_overrides.erase(id);
}


void keymap_config::reset_all()
{
	m_overrides.clear();
}


void keymap_config::save(util::xml::data_node &parentnode) const
{
	if (m_overrides.empty())
		return;

	util::xml::data_node *const keymap = parentnode.add_child(NODE_KEYMAP, nullptr);
	if (!keymap)
		return;

	// write in table order for a stable, readable config file
	for (key_action const &action : m_actions)
	{
		auto const override = m_overrides.find(action.id);
		if (override == m_overrides.end())
			continue;
		util::xml::data_node *const item = keymap->add_child(NODE_KEYMAP_ITEM, nullptr);
		if (!item)
			continue;
		item->set_attribute(ATTR_KEYMAP_ACTION, action.id.c_str());
		item->set_attribute(ATTR_KEYMAP_KEY, override->second.to_string().c_str());
	}
}


void keymap_config::load(util::xml::data_node const &parentnode)
{
	util::xml::data_node const *const keymap = parentnode.get_child(NODE_KEYMAP);
	if (!keymap)
		return;

	for (util::xml::data_node const *item = keymap->get_child(NODE_KEYMAP_ITEM);
			item;
			item = item->get_next_sibling(NODE_KEYMAP_ITEM))
	{
		char const *const id = item->get_attribute_string(ATTR_KEYMAP_ACTION, nullptr);
		if (!id || !find(id))
			continue;
		char const *const text = item->get_attribute_string(ATTR_KEYMAP_KEY, "");
		set_shortcut(id, key_shortcut::from_string(text));
	}
}

} // namespace osd::debugger
