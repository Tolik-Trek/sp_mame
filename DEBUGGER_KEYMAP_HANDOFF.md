# Handoff: переназначаемые горячие клавиши в дебаггерах MAME

> Дай этот файл Claude в новой сессии (на другом компьютере) — он восстановит весь
> контекст задачи и сможет продолжить. Рабочая копия: `/Users/tolik/Documents/GitHub/mame`,
> ветка `Vibe`. Пользователь общается по-русски.

## Цель
Добавить в дебаггеры MAME возможность переназначать горячие клавиши с сохранением
между сессиями и UI для редактирования. Изначально просили для macOS-Cocoa-дебаггера
(`osd/modules/debugger/osx/`), затем — «для остальных дебаггеров» в
`src/osd/modules/debugger/`.

## Статус по дебаггерам
- **Cocoa (osx)** — ✅ СДЕЛАНО и собиралось (отдельная реализация на Objective-C).
- **ImGui** (`debugimgui.cpp`) — ✅ СДЕЛАНО, компилируется чисто.
- **Qt** (`debugqt.cpp` + `qt/`) — ✅ СДЕЛАНО, компилируется чисто (с `USE_QTDEBUG=1`).
- **Win** (`win/`) — ⛔ ПРОПУЩЕНО по решению пользователя (нельзя собрать/проверить на macOS;
  нативный Win32-диалог — высокий риск вслепую). Не трогали.
- **gdbstub / none** — не GUI, не трогаем.

`-debugger auto` на macOS выбирает Cocoa (регистрируется первым, всегда инициализируется).
Для проверки других: `-debugger imgui -video bgfx` или `-debugger qt`.

---

## Архитектура

### Общий C++-модуль (для ImGui/Qt/Win) — НОВЫЙ
- `src/osd/modules/debugger/debugkeyconfig.h`
- `src/osd/modules/debugger/debugkeyconfig.cpp`

`namespace osd::debugger`:
- `struct key_shortcut { std::string key; bool ctrl, alt, shift; }` —
  `to_string()` → "Ctrl+Shift+F9" (переносимый текст), `from_string()`.
- `struct key_action { std::string id, label, group; key_shortcut default_shortcut; }`.
- `class keymap_config(std::vector<key_action>&& actions)` — хранит таблицу + override’ы:
  `shortcut(id)`, `is_default`, `conflicting_action`, `set_shortcut/clear/reset/reset_all`,
  `save(node)` / `load(node)` (узел `<keymap>` с дочерними `<key>`).

Каждый дебаггер задаёт СВОЮ таблицу действий (id/label/group/дефолты), а хранилище,
парсинг и XML — общие. Формат текстовый и единый → раскладка в `default.cfg` понятна
всем трём (Qt↔ImGui↔Win шарят). **Cocoa хранит в своём формате (codepoint+mask), с ним
не пересекается — это ОК (разные id, конфликтов в файле нет).**

### XML-константы (общие) — в `xmlconfig.h/.cpp`
Добавлены: `NODE_KEYMAP="keymap"`, `NODE_KEYMAP_ITEM="key"`,
`ATTR_KEYMAP_ACTION="action"`, `ATTR_KEYMAP_KEY="char"`, `ATTR_KEYMAP_MODIFIERS="modifiers"`.
(У C++-дебаггеров modifiers зашиты в текст `ATTR_KEYMAP_KEY`; у Cocoa — отдельные int.)

### Персистентность
Все дебаггеры пишут раскладку как ГЛОБАЛЬНУЮ — в `default.cfg`, через
`config_register("debugger", …)` и обработку `config_type::DEFAULT` (а не `SYSTEM`,
который для позиций окон). Сохраняются только отличия от дефолтов; пустой `<keymap>` не пишется.

---

## Что и где изменено

### Cocoa (Objective-C, отдельная реализация — НЕ использует debugkeyconfig)
НОВЫЕ:
- `osx/debugkeymap.h` / `osx/debugkeymap.mm` — синглтон `MAMEDebugKeyMap` (реестр действий,
  лукапы, `applyToMenuItem:forAction:`, `refreshMenu:`, save/restore XML). Хранит unichar+mask.
- `osx/debugkeymapviewer.h` / `osx/debugkeymapviewer.mm` — окно `MAMEKeyBindingsWindow`
  (таблица + запись через локальный монитор NSEvent, конфликты, Reset All).
ИЗМЕНЕНЫ:
- `osx/debugwindowhandler.{h,mm}` — `addCommonActionItems:` берёт клавиши из реестра;
  пункт «Customize Keys…»; `showKeyBindings:`; `keyMapChanged:` рефрешит главное меню и
  popup-кнопки окна; подписка на `MAMEDebugKeyMapChangedNotification`.
- `osx/disassemblyview.mm` — оба построителя меню (контекст + action-button) через реестр.
- `debugosx.mm` — `build_menus` (главное меню Debug/Run/Step) через реестр; пункт
  «Customize Keys…»; `config_load/config_save` обрабатывают `DEFAULT` для глобальной раскладки.
- `osx/debugkeymap.h` включает `"../xmlconfig.h"` (важно: с `../`, файл в подкаталоге osx/).
Идентификаторы Cocoa — camelCase ("stepInto" и т.п.).

### ImGui — `src/osd/modules/debugger/debugimgui.cpp`
- Добавлены include `debugkeyconfig.h`, `util/xmlfile.h`.
- Статическая таблица `f_imgui_keys[]` (имя↔ImGuiKey), функции `imgui_key_for_name`,
  `shortcut_pressed(key_shortcut)`, `capture_shortcut(out)`.
- id-константы `IMGUI_ACT_*` (snake_case) + `imgui_default_actions()`.
- Поля класса: `keymap_config m_keymap`, `bool m_keybind_open`,
  `std::string m_keybind_recording, m_keybind_status`. Инициализация в конструкторе.
- `handle_events()`: блок «global keys» переписан на `shortcut_pressed(m_keymap.shortcut(ID))`;
  в начале `if(!m_keybind_recording.empty()) return;`.
- `init_debugger`: `config_register("debugger", …)`; **РАСШИРЕН `m_mapping`** — добавлены
  F1/F2/F4, все буквы, 0-9, Space, Insert (иначе MAME не прокидывает эти клавиши в ImGui и
  их нельзя ни нажать, ни записать).
- Меню Debug: ярлыки из `m_keymap.shortcut(ID).to_string()`, пункт «Customize keys...».
- Новые методы: `config_load`, `config_save`, `draw_keybindings()` (окно с таблицей,
  запись клавиш, Esc/Delete, конфликты, Reset All). Вызов `draw_keybindings()` в `update()`.

### Qt — 3 файла (без новых файлов и без новых moc-классов; диалог инлайн на лямбдах)
- `qt/windowqt.h`: include `"../debugkeyconfig.h"`; в `DebuggerQt` —
  `virtual keymap_config &keymap()=0`, сигнал `keyBindingsChanged()`, `notifyKeyBindingsChanged()`;
  в `WindowQt` — слоты `applyKeyBindings()`, `debugActCustomizeKeys()`, метод
  `createKeyAction(id,text,slot)`, поле `std::map<std::string,QAction*> m_keyActions`.
  Объявлена `std::vector<key_action> qtDefaultKeyActions();`.
- `qt/windowqt.cpp`: id-константы `ACT_*` + `qtDefaultKeyActions()`; действия создаются через
  `createKeyAction` (ярлык из keymap, сохраняется в map); пункт «Customize Keys...»;
  `applyKeyBindings()`; `debugActCustomizeKeys()` — инлайн `QDialog` с `QKeySequenceEdit`
  на каждое действие, кнопки Ok/Cancel/RestoreDefaults; по OK пишет в keymap (через
  `QKeySequence::toString(PortableText)`, берёт первый аккорд) и `notifyKeyBindingsChanged()`.
- `debugqt.cpp`: член `keymap_config m_keymap{qtDefaultKeyActions()}`, override `keymap()`,
  в `configuration_load/save` добавлена ветка `config_type::DEFAULT` → `m_keymap.load/save`.
- **Дефолты Qt ИЗМЕНЕНЫ** со странных `F16–F19` (заглушка в оригинале) на нормальные
  F5/F6/F7/F8/F11/F10/Shift+F11/F3/Shift+F3/Ctrl+M,D,L,B/Ctrl+W/Ctrl+Q — единые с остальными.

### Build-скрипты
- `scripts/src/osd/modules.lua` — добавлены `debugkeyconfig.cpp/.h` в общий
  `osdmodulesbuild()` (компилируется во ВСЕХ OSD).
- `scripts/src/osd/mac.lua`, `sdl.lua`, `sdl3.lua` — добавлены 4 osx-файла Cocoa
  (`debugkeymap.{h,mm}`, `debugkeymapviewer.{h,mm}`).
- ImGui/Qt новых файлов не добавляли — правки в существующих.

---

## Сборка и проверка (то, что использовалось)

Окружение: macOS, OSD `sdl3`, конфиг `release64`, тулчейн `gmake-osx-clang`, Qt5 (`/usr/local/bin/qmake`).

Регенерация проекта (ОБЯЗАТЕЛЬНО с `--USE_QTDEBUG=1`, иначе qt-файлы выпадают из сборки):
```
cd /Users/tolik/Documents/GitHub/mame
3rdparty/genie/bin/darwin/genie --with-emulator --USE_QTDEBUG=1 --OPTIMIZE=3 \
  --target='mame' --subtarget='mame' --build-dir='build' --osd='sdl3' \
  --targetos='macosx' --PLATFORM='x86' --gcc=osx-clang --gcc_version=17.0.0 gmake
```
Сборка только нужных библиотек (быстро, без линковки всего MAME):
```
make -R --no-print-directory -C build/projects/sdl3/mame/gmake-osx-clang config=release64 osd_sdl3 qtdbg_sdl3
```
- `osd_sdl3` содержит `debugimgui.o`, `debugkeyconfig.o`, и osx-файлы Cocoa.
- `qtdbg_sdl3` содержит `debugqt.o`, `windowqt.o` + moc.

Статус последней сборки: **всё компилируется чисто, без ошибок/предупреждений** (по теме).
Полный бинарник (`mame`) НЕ релинковали — релинк потянул бы пересборку всего MAME.
Для живого теста нужен полный билд (напр. `make macosx_arm64_clang` или скрипт пользователя),
затем `~/Documents/MAME/debug.sh` (там `-debugger auto` → Cocoa). Для ImGui/Qt — сменить
`-debugger` (imgui требует `-video bgfx`).

Гочи сборки:
- genie без `--USE_QTDEBUG=1` отключает qt → `windowqt.o` пропадает из всех `.make`
  (был эпизод: казалось, что файл не пересобирается).
- Объекты лежат в `build/osx_clang/obj/x64/Release/<lib>/...`.
- `qmake -query QT_INSTALL_LIBS` даёт `-F` для фреймворков (macOS).

---

## Что осталось / возможные продолжения
1. **Win-дебаггер** (пропущен). Если делать: ключи в `win/debugwininfo.cpp`
   (`handle_key`, `WM_KEYDOWN`-switch по `VK_*` + `GetAsyncKeyState`) и
   `win/disasmbasewininfo.cpp`; текст меню в `create_standard_menubar()`
   (строки вида `"Run\tF5"`); персист через `debugwin` config (`DEFAULT`); пункт
   «Customize keys…» + Win32-диалог (самое рискованное вслепую). Можно переиспользовать
   `debugkeyconfig`; нужен маппинг `key_shortcut`↔`VK_*`. Текстовый формат уже совместим —
   Windows-юзер и так может настроить через `default.cfg`/Qt/ImGui, а Win подхватит.
2. **Полный релинк** и интерактивная проверка ImGui/Qt вживую (запись клавиш, сохранение в
   `default.cfg`, перезапуск — раскладка восстановилась).
3. Возможная унификация Cocoa на тот же текстовый формат `debugkeyconfig` (сейчас отдельный) —
   не обязательно.

## Действия (id → дефолт), для ориентира
ImGui (snake_case): new_disasm=Ctrl+D, new_memory=Ctrl+M, new_bpoints=Ctrl+B,
new_wpoints=Ctrl+W, new_log=Ctrl+L, run=F5, run_next_cpu=F6, run_next_int=F7,
run_vblank=F8, run_and_hide=F12, step_into=F11, step_over=F10, step_out=F9,
soft_reset=F3, hard_reset=Shift+F3.

Qt (snake_case): new_memory=Ctrl+M, new_disasm=Ctrl+D, new_log=Ctrl+L, new_points=Ctrl+B,
new_devices=(нет), run=F5, run_and_hide=F12, run_next_cpu=F6, run_next_int=F7,
run_vblank=F8, step_into=F11, step_over=F10, step_out=Shift+F11, soft_reset=F3,
hard_reset=Shift+F3, close_window=Ctrl+W, quit=Ctrl+Q.
