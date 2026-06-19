// license:BSD-3-Clause
// copyright-holders:Andrew Gardner
#include "emu.h"
#include "windowqt.h"

#include "breakpointswindow.h"
#include "dasmwindow.h"
#include "deviceswindow.h"
#include "logwindow.h"
#include "memorywindow.h"

#include "debugger.h"
#include "debug/debugcon.h"
#include "debug/debugcpu.h"

#include "util/xmlfile.h"

#include <QtWidgets/QDialog>
#include <QtWidgets/QDialogButtonBox>
#include <QtWidgets/QGridLayout>
#include <QtWidgets/QKeySequenceEdit>
#include <QtWidgets/QLabel>
#include <QtWidgets/QMenu>
#include <QtWidgets/QMenuBar>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QScrollArea>
#include <QtWidgets/QVBoxLayout>

#include <vector>


namespace osd::debugger::qt {

namespace {

// action identifiers (also used as keys in the configuration file)
constexpr char const *ACT_NEW_MEMORY   = "new_memory";
constexpr char const *ACT_NEW_DISASM   = "new_disasm";
constexpr char const *ACT_NEW_LOG      = "new_log";
constexpr char const *ACT_NEW_POINTS   = "new_points";
constexpr char const *ACT_NEW_DEVICES  = "new_devices";
constexpr char const *ACT_RUN          = "run";
constexpr char const *ACT_RUN_AND_HIDE = "run_and_hide";
constexpr char const *ACT_RUN_NEXT_CPU = "run_next_cpu";
constexpr char const *ACT_RUN_NEXT_INT = "run_next_int";
constexpr char const *ACT_RUN_VBLANK   = "run_vblank";
constexpr char const *ACT_STEP_INTO    = "step_into";
constexpr char const *ACT_STEP_OVER    = "step_over";
constexpr char const *ACT_STEP_OUT     = "step_out";
constexpr char const *ACT_SOFT_RESET   = "soft_reset";
constexpr char const *ACT_HARD_RESET   = "hard_reset";
constexpr char const *ACT_CLOSE_WINDOW = "close_window";
constexpr char const *ACT_QUIT         = "quit";

osd::debugger::key_shortcut make_sc(char const *key, bool ctrl, bool shift)
{
	osd::debugger::key_shortcut sc;
	sc.key = key;
	sc.ctrl = ctrl;
	sc.shift = shift;
	return sc;
}

} // anonymous namespace


std::vector<osd::debugger::key_action> qtDefaultKeyActions()
{
	return {
		{ ACT_NEW_MEMORY,   "New Memory Window",            "Windows",   make_sc("M", true,  false) },
		{ ACT_NEW_DISASM,   "New Disassembly Window",       "Windows",   make_sc("D", true,  false) },
		{ ACT_NEW_LOG,      "New Error Log Window",         "Windows",   make_sc("L", true,  false) },
		{ ACT_NEW_POINTS,   "New (Break|Watch)points Window", "Windows", make_sc("B", true,  false) },
		{ ACT_NEW_DEVICES,  "New Devices Window",           "Windows",   osd::debugger::key_shortcut() },
		{ ACT_RUN,          "Run / Break",                  "Execution", make_sc("F5",  false, false) },
		{ ACT_RUN_AND_HIDE, "Run and Hide Debugger",        "Execution", make_sc("F12", false, false) },
		{ ACT_RUN_NEXT_CPU, "Run to Next CPU",              "Execution", make_sc("F6",  false, false) },
		{ ACT_RUN_NEXT_INT, "Run to Next Interrupt",        "Execution", make_sc("F7",  false, false) },
		{ ACT_RUN_VBLANK,   "Run to Next VBLANK",           "Execution", make_sc("F8",  false, false) },
		{ ACT_STEP_INTO,    "Step Into",                    "Execution", make_sc("F11", false, false) },
		{ ACT_STEP_OVER,    "Step Over",                    "Execution", make_sc("F10", false, false) },
		{ ACT_STEP_OUT,     "Step Out",                     "Execution", make_sc("F11", false, true)  },
		{ ACT_SOFT_RESET,   "Soft Reset",                   "Execution", make_sc("F3",  false, false) },
		{ ACT_HARD_RESET,   "Hard Reset",                   "Execution", make_sc("F3",  false, true)  },
		{ ACT_CLOSE_WINDOW, "Close Window",                 "Windows",   make_sc("W", true,  false) },
		{ ACT_QUIT,         "Quit",                         "Windows",   make_sc("Q", true,  false) }
	};
}

// Since all debug windows are intended to be top-level, this inherited
// constructor is always called with a nullptr parent.  The passed-in parent widget,
// however, is often used to place each child window & the code to do this can
// be found in most of the inherited classes.

WindowQt::WindowQt(DebuggerQt &debugger, QWidget *parent) :
	QMainWindow(parent),
	m_debugger(debugger),
	m_machine(debugger.machine())
{
	setAttribute(Qt::WA_DeleteOnClose, true);

	// Subscribe to signals
	connect(&debugger, &DebuggerQt::exitDebugger, this, &WindowQt::debuggerExit);
	connect(&debugger, &DebuggerQt::hideAllWindows, this, &WindowQt::hide);
	connect(&debugger, &DebuggerQt::showAllWindows, this, &WindowQt::show);
	connect(&debugger, &DebuggerQt::saveConfiguration, this, &WindowQt::saveConfiguration);
	connect(&debugger, &DebuggerQt::keyBindingsChanged, this, &WindowQt::applyKeyBindings);

	// The Debug menu bar - shortcuts come from the remappable key map
	QAction *debugActOpenMemory  = createKeyAction(ACT_NEW_MEMORY,   "New &Memory Window",              &WindowQt::debugActOpenMemory);
	QAction *debugActOpenDasm    = createKeyAction(ACT_NEW_DISASM,   "New &Disassembly Window",         &WindowQt::debugActOpenDasm);
	QAction *debugActOpenLog     = createKeyAction(ACT_NEW_LOG,      "New Error &Log Window",           &WindowQt::debugActOpenLog);
	QAction *debugActOpenPoints  = createKeyAction(ACT_NEW_POINTS,   "New (&Break|Watch)points Window", &WindowQt::debugActOpenPoints);
	QAction *debugActOpenDevices = createKeyAction(ACT_NEW_DEVICES,  "New D&evices Window",             &WindowQt::debugActOpenDevices);
	QAction *dbgActRun           = createKeyAction(ACT_RUN,          "Run/Break",                       &WindowQt::debugActRun);
	QAction *dbgActRunAndHide    = createKeyAction(ACT_RUN_AND_HIDE, "Run And Hide Debugger",           &WindowQt::debugActRunAndHide);
	QAction *dbgActRunToNextCpu  = createKeyAction(ACT_RUN_NEXT_CPU, "Run to Next CPU",                 &WindowQt::debugActRunToNextCpu);
	QAction *dbgActRunNextInt    = createKeyAction(ACT_RUN_NEXT_INT, "Run to Next Interrupt on This CPU", &WindowQt::debugActRunNextInt);
	QAction *dbgActRunNextVBlank = createKeyAction(ACT_RUN_VBLANK,   "Run to Next VBlank",              &WindowQt::debugActRunNextVBlank);
	QAction *dbgActStepInto      = createKeyAction(ACT_STEP_INTO,    "Step Into",                       &WindowQt::debugActStepInto);
	QAction *dbgActStepOver      = createKeyAction(ACT_STEP_OVER,    "Step Over",                       &WindowQt::debugActStepOver);
	QAction *dbgActStepOut       = createKeyAction(ACT_STEP_OUT,     "Step Out",                        &WindowQt::debugActStepOut);
	QAction *dbgActSoftReset     = createKeyAction(ACT_SOFT_RESET,   "Soft Reset",                      &WindowQt::debugActSoftReset);
	QAction *dbgActHardReset     = createKeyAction(ACT_HARD_RESET,   "Hard Reset",                      &WindowQt::debugActHardReset);
	QAction *dbgActClose         = createKeyAction(ACT_CLOSE_WINDOW, "Close &Window",                   &WindowQt::debugActClose);
	QAction *dbgActQuit          = createKeyAction(ACT_QUIT,         "&Quit",                           &WindowQt::debugActQuit);

	QAction *dbgActCustomizeKeys = new QAction("Customize &Keys...", this);
	connect(dbgActCustomizeKeys, &QAction::triggered, this, &WindowQt::debugActCustomizeKeys);

	// Construct the menu
	QMenu *debugMenu = menuBar()->addMenu("&Debug");
	debugMenu->addAction(debugActOpenMemory);
	debugMenu->addAction(debugActOpenDasm);
	debugMenu->addAction(debugActOpenLog);
	debugMenu->addAction(debugActOpenPoints);
	debugMenu->addAction(debugActOpenDevices);
	debugMenu->addSeparator();
	debugMenu->addAction(dbgActRun);
	debugMenu->addAction(dbgActRunAndHide);
	debugMenu->addAction(dbgActRunToNextCpu);
	debugMenu->addAction(dbgActRunNextInt);
	debugMenu->addAction(dbgActRunNextVBlank);
	debugMenu->addSeparator();
	debugMenu->addAction(dbgActStepInto);
	debugMenu->addAction(dbgActStepOver);
	debugMenu->addAction(dbgActStepOut);
	debugMenu->addSeparator();
	debugMenu->addAction(dbgActSoftReset);
	debugMenu->addAction(dbgActHardReset);
	debugMenu->addSeparator();
	debugMenu->addAction(dbgActCustomizeKeys);
	debugMenu->addSeparator();
	debugMenu->addAction(dbgActClose);
	debugMenu->addAction(dbgActQuit);
}


QAction *WindowQt::createKeyAction(char const *id, QString const &text, void (WindowQt::*slot)())
{
	QAction *const action = new QAction(text, this);
	connect(action, &QAction::triggered, this, slot);
	m_keyActions[id] = action;
	action->setShortcut(QKeySequence(QString::fromStdString(m_debugger.keymap().shortcut(id).to_string())));
	return action;
}


void WindowQt::applyKeyBindings()
{
	for (auto const &entry : m_keyActions)
		entry.second->setShortcut(QKeySequence(QString::fromStdString(m_debugger.keymap().shortcut(entry.first).to_string())));
}


WindowQt::~WindowQt()
{
}


void WindowQt::debugActOpenMemory()
{
	MemoryWindow *foo = new MemoryWindow(m_debugger, this);
	// A valiant effort, but it just doesn't wanna' hide behind the main window & not make a new taskbar icon
	// foo->setWindowFlags(Qt::Dialog);
	// foo->setWindowFlags(foo->windowFlags() & ~Qt::WindowStaysOnTopHint);
	foo->show();
}


void WindowQt::debugActOpenDasm()
{
	DasmWindow *foo = new DasmWindow(m_debugger, this);
	// A valiant effort, but it just doesn't wanna' hide behind the main window & not make a new toolbar icon
	// foo->setWindowFlags(Qt::Dialog);
	// foo->setWindowFlags(foo->windowFlags() & ~Qt::WindowStaysOnTopHint);
	foo->show();
}


void WindowQt::debugActOpenLog()
{
	LogWindow *foo = new LogWindow(m_debugger, this);
	// A valiant effort, but it just doesn't wanna' hide behind the main window & not make a new toolbar icon
	// foo->setWindowFlags(Qt::Dialog);
	// foo->setWindowFlags(foo->windowFlags() & ~Qt::WindowStaysOnTopHint);
	foo->show();
}


void WindowQt::debugActOpenPoints()
{
	BreakpointsWindow *foo = new BreakpointsWindow(m_debugger, this);
	// A valiant effort, but it just doesn't wanna' hide behind the main window & not make a new toolbar icon
	// foo->setWindowFlags(Qt::Dialog);
	// foo->setWindowFlags(foo->windowFlags() & ~Qt::WindowStaysOnTopHint);
	foo->show();
}


void WindowQt::debugActOpenDevices()
{
	DevicesWindow *foo = new DevicesWindow(m_debugger, this);
	// A valiant effort, but it just doesn't wanna' hide behind the main window & not make a new toolbar icon
	// foo->setWindowFlags(Qt::Dialog);
	// foo->setWindowFlags(foo->windowFlags() & ~Qt::WindowStaysOnTopHint);
	foo->show();
}


void WindowQt::debugActRun()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->go();
}

void WindowQt::debugActRunAndHide()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->go();
	m_debugger.hideAll();
}

void WindowQt::debugActRunToNextCpu()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->go_next_device();
}

void WindowQt::debugActRunNextInt()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->go_interrupt();
}

void WindowQt::debugActRunNextVBlank()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->go_vblank();
}

void WindowQt::debugActStepInto()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->single_step();
}

void WindowQt::debugActStepOver()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->single_step_over();
}

void WindowQt::debugActStepOut()
{
	m_machine.debugger().console().get_visible_cpu()->debug()->single_step_out();
}

void WindowQt::debugActSoftReset()
{
	m_machine.schedule_soft_reset();
	m_machine.debugger().console().get_visible_cpu()->debug()->single_step();
}

void WindowQt::debugActHardReset()
{
	m_machine.schedule_hard_reset();
}

void WindowQt::debugActClose()
{
	close();
}

void WindowQt::debugActQuit()
{
	m_machine.schedule_exit();
}

void WindowQt::debugActCustomizeKeys()
{
	osd::debugger::keymap_config &keymap = m_debugger.keymap();

	QDialog dialog(this);
	dialog.setWindowTitle("Customize Debugger Keys");
	dialog.resize(440, 480);

	QVBoxLayout *const outer = new QVBoxLayout(&dialog);

	QLabel *const hint = new QLabel(
			"Click a field and press the desired key combination. Use Backspace to clear a binding.",
			&dialog);
	hint->setWordWrap(true);
	outer->addWidget(hint);

	QScrollArea *const scroll = new QScrollArea(&dialog);
	scroll->setWidgetResizable(true);
	QWidget *const content = new QWidget(scroll);
	QGridLayout *const grid = new QGridLayout(content);

	std::vector<std::pair<std::string, QKeySequenceEdit *> > edits;
	int row = 0;
	std::string group;
	for (osd::debugger::key_action const &action : keymap.actions())
	{
		if (action.group != group)
		{
			group = action.group;
			QLabel *const header = new QLabel(QString("<b>%1</b>").arg(QString::fromStdString(group)), content);
			grid->addWidget(header, row++, 0, 1, 2);
		}
		QLabel *const label = new QLabel(QString::fromStdString(action.label), content);
		QKeySequenceEdit *const edit = new QKeySequenceEdit(
				QKeySequence(QString::fromStdString(keymap.shortcut(action.id).to_string())),
				content);
		grid->addWidget(label, row, 0);
		grid->addWidget(edit, row, 1);
		edits.emplace_back(action.id, edit);
		++row;
	}
	scroll->setWidget(content);
	outer->addWidget(scroll, 1);

	QDialogButtonBox *const buttons = new QDialogButtonBox(
			QDialogButtonBox::Ok | QDialogButtonBox::Cancel | QDialogButtonBox::RestoreDefaults,
			&dialog);
	outer->addWidget(buttons);
	connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
	connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
	connect(buttons->button(QDialogButtonBox::RestoreDefaults), &QPushButton::clicked, &dialog,
			[&edits, &keymap] ()
			{
				for (auto const &entry : edits)
				{
					keymap.reset(entry.first);
					entry.second->setKeySequence(QKeySequence(QString::fromStdString(keymap.shortcut(entry.first).to_string())));
				}
			});

	if (dialog.exec() == QDialog::Accepted)
	{
		for (auto const &entry : edits)
		{
			// keep only the first chord and store it in portable form
			QString portable = entry.second->keySequence().toString(QKeySequence::PortableText);
			int const comma = portable.indexOf(", ");
			if (comma >= 0)
				portable = portable.left(comma);
			keymap.set_shortcut(entry.first, osd::debugger::key_shortcut::from_string(portable.toStdString()));
		}
		m_debugger.notifyKeyBindingsChanged();
	}
}

void WindowQt::debuggerExit()
{
	// this isn't called from a Qt event loop, so close() will leak the window object
	delete this;
}


void WindowQt::restoreConfiguration(util::xml::data_node const &node)
{
	QPoint p(geometry().topLeft());
	p.setX(node.get_attribute_int(ATTR_WINDOW_POSITION_X, p.x()));
	p.setY(node.get_attribute_int(ATTR_WINDOW_POSITION_Y, p.y()));

	QSize s(size());
	s.setWidth(node.get_attribute_int(ATTR_WINDOW_WIDTH, s.width()));
	s.setHeight(node.get_attribute_int(ATTR_WINDOW_HEIGHT, s.height()));

	// TODO: sanity checks, restrict to screen area

	setGeometry(p.x(), p.y(), s.width(), s.height());
}


void WindowQt::saveConfiguration(util::xml::data_node &parentnode)
{
	util::xml::data_node *const node = parentnode.add_child(NODE_WINDOW, nullptr);
	if (node)
		saveConfigurationToNode(*node);
}


void WindowQt::saveConfigurationToNode(util::xml::data_node &node)
{
	node.set_attribute_int(ATTR_WINDOW_POSITION_X, geometry().topLeft().x());
	node.set_attribute_int(ATTR_WINDOW_POSITION_Y, geometry().topLeft().y());
	node.set_attribute_int(ATTR_WINDOW_WIDTH, size().width());
	node.set_attribute_int(ATTR_WINDOW_HEIGHT, size().height());
}


CommandHistory::CommandHistory() :
	m_history(),
	m_current(),
	m_position(-1)
{
}


CommandHistory::~CommandHistory()
{
}


void CommandHistory::add(QString const &entry)
{
	if (m_history.empty() || (m_history.front() != entry))
	{
		while (m_history.size() >= CAPACITY)
			m_history.pop_back();
		m_history.push_front(entry);
	}
	m_position = 0;
}


QString const *CommandHistory::previous(QString const &current)
{
	if ((m_position + 1) < m_history.size())
	{
		if (0 > m_position)
			m_current = std::make_unique<QString>(current);
		return &m_history[++m_position];
	}
	else
	{
		return nullptr;
	}
}


QString const *CommandHistory::next(QString const &current)
{
	if (0 < m_position)
	{
		return &m_history[--m_position];
	}
	else if (!m_position && m_current && (m_history.front() != *m_current))
	{
		--m_position;
		return m_current.get();
	}
	else
	{
		return nullptr;
	}
}


void CommandHistory::edit()
{
	if (!m_position)
		--m_position;
}


void CommandHistory::reset()
{
	m_position = -1;
	m_current.reset();
}


void CommandHistory::clear()
{
	m_position = -1;
	m_current.reset();
	m_history.clear();
}


void CommandHistory::restoreConfigurationFromNode(util::xml::data_node const &node)
{
	clear();
	util::xml::data_node const *const historynode = node.get_child(NODE_WINDOW_HISTORY);
	if (historynode)
	{
		util::xml::data_node const *itemnode = historynode->get_child(NODE_HISTORY_ITEM);
		while (itemnode)
		{
			if (itemnode->get_value() && *itemnode->get_value())
			{
				while (m_history.size() >= CAPACITY)
					m_history.pop_back();
				m_history.push_front(QString::fromUtf8(itemnode->get_value()));
			}
			itemnode = itemnode->get_next_sibling(NODE_HISTORY_ITEM);
		}
	}
}


void CommandHistory::saveConfigurationToNode(util::xml::data_node &node)
{
	util::xml::data_node *const historynode = node.add_child(NODE_WINDOW_HISTORY, nullptr);
	if (historynode)
	{
		for (auto it = m_history.crbegin(); m_history.crend() != it; ++it)
			historynode->add_child(NODE_HISTORY_ITEM, it->toUtf8().data());
	}
}

} // namespace osd::debugger::qt
