// license:BSD-3-Clause
// copyright-holders:Andrew Gardner
#ifndef MAME_DEBUGGER_QT_WINDOWQT_H
#define MAME_DEBUGGER_QT_WINDOWQT_H

#include "../xmlconfig.h"
#include "../debugkeyconfig.h"

#ifdef __aarch64__
#include <arm_acle.h> // QtCore/qyieldcpu.h uses __yield() without #including this, causing an error
#endif

#include <QtWidgets/QMainWindow>

#include <deque>
#include <map>
#include <memory>
#include <vector>

class QAction;


namespace osd::debugger::qt {

// table of remappable actions with their default Qt shortcuts (defined in windowqt.cpp)
std::vector<osd::debugger::key_action> qtDefaultKeyActions();

//============================================================
//  The Qt debugger module interface
//============================================================
class DebuggerQt : public QObject
{
	Q_OBJECT

public:
	virtual ~DebuggerQt() { }

	virtual running_machine &machine() const = 0;

	// shared, remappable keyboard shortcut map
	virtual osd::debugger::keymap_config &keymap() = 0;

	void hideAll() { emit hideAllWindows(); }
	void notifyKeyBindingsChanged() { emit keyBindingsChanged(); }

signals:
	void exitDebugger();
	void hideAllWindows();
	void showAllWindows();
	void saveConfiguration(util::xml::data_node &parentnode);
	void keyBindingsChanged();
};


//============================================================
//  The Qt window that everyone derives from.
//============================================================
class WindowQt : public QMainWindow
{
	Q_OBJECT

public:
	virtual ~WindowQt();

	virtual void restoreConfiguration(util::xml::data_node const &node);

protected slots:
	void debugActOpenMemory();
	void debugActOpenDasm();
	void debugActOpenLog();
	void debugActOpenPoints();
	void debugActOpenDevices();
	void debugActRun();
	void debugActRunAndHide();
	void debugActRunToNextCpu();
	void debugActRunNextInt();
	void debugActRunNextVBlank();
	void debugActStepInto();
	void debugActStepOver();
	void debugActStepOut();
	void debugActSoftReset();
	void debugActHardReset();
	virtual void debugActClose();
	void debugActQuit();
	void debugActCustomizeKeys();
	virtual void debuggerExit();

private slots:
	void saveConfiguration(util::xml::data_node &parentnode);
	void applyKeyBindings();

protected:
	WindowQt(DebuggerQt &debugger, QWidget *parent = nullptr);

	virtual void saveConfigurationToNode(util::xml::data_node &node);

	// create a menu action whose shortcut is driven by the remappable key map
	QAction *createKeyAction(char const *id, QString const &text, void (WindowQt::*slot)());

	DebuggerQt &m_debugger;
	running_machine &m_machine;
	std::map<std::string, QAction *> m_keyActions;  // action id -> menu action, for live shortcut updates
};


//============================================================
//  Command history helper
//============================================================
class CommandHistory
{
public:
	CommandHistory();
	~CommandHistory();

	void add(QString const &entry);
	QString const *previous(QString const &current);
	QString const *next(QString const &current);
	void edit();
	void reset();
	void clear();

	void restoreConfigurationFromNode(util::xml::data_node const &node);
	void saveConfigurationToNode(util::xml::data_node &node);

private:
	static inline constexpr unsigned CAPACITY = 100U;

	std::deque<QString> m_history;
	std::unique_ptr<QString> m_current;
	int m_position;
};

} // namespace osd::debugger::qt

#endif // MAME_DEBUGGER_QT_WINDOWQT_H
