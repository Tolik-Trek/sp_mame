# Управление эмулятором MAME из Claude — переносимый онбординг

> **Назначение этого файла.** Подгрузи его в новую сессию Claude (в любом проекте),
> и я сразу умею управлять эмулятором MAME (на примере машины **Sprinter**, CPU
> z84c015): читать/писать регистры и память (с учётом банкирования), ставить
> брейк-/вотчпойнты, шагать, дизассемблировать, **видеть экран** и **управлять**
> машиной (клавиатура, мышь, джойстик).
>
> Как подгрузить: либо «прочитай файл `/Users/tolik/Documents/GitHub/mame/MAME_MCP_GUIDE.md`
> и действуй по нему», либо скопируй этот файл в `CLAUDE.md` нового проекта.
>
> Все пути абсолютные — файл самодостаточен и не зависит от текущего проекта.

---

## 0. TL;DR — как поднять связку за 3 шага

```bash
# 1) Запустить MAME с дебаггером и плагином-мостом (см. полный конфиг в Debug.sh):
cd /Users/tolik/Documents/MAME && ./Debug.sh         # содержит -debug -debugger auto (на macOS = Cocoa)
#   но в Debug.sh нужно дописать в строку запуска:  -plugin mamebridge
#   (без него мост не поднимется). Полный минимум, если запускать вручную:
#   ./mame sprinter -mouse -kbd ms_naturl,bios=sp2k -bios dev -debug -debugger auto -plugin mamebridge <диски...>
#   Мост debugger-agnostic: одинаково работает с -debugger qt | imgui | auto(Cocoa).
#   Проверено вживую под Cocoa (2026-05-22): все команды + цикл stop/step без таймаутов.

# 2) Зарегистрировать MCP-сервер в Claude Code (один раз на проект):
claude mcp add mame-z80 -- python /Users/tolik/Documents/GitHub/mame/src/mame_mcp.py

# 3) Готово. В сессии доступны MCP-инструменты read_registers, read_memory, step, scrpix и т.д.
```

Если MAME не находит плагин: добавь явно `-pluginspath /Users/tolik/Documents/GitHub/mame/plugins`.

**Остановка MAME:** НИКОГДА не `kill`/`pkill`. Слать debugger-команду `exit`
(через мост: `debugger_command("exit")` или просто положить запрос `cmd exit`).
Ответа не будет — процесс завершится, это нормально.

---

## 1. Архитектура связки

```
Claude (MCP-клиент)
   │  вызывает MCP-инструменты
   ▼
mame_mcp.py  (FastMCP-сервер, stdio)            pip install "mcp[cli]"
   │  файловый IPC: пишет req_<id>.txt, ждёт resp_<id>.txt в общей папке
   ▼
plugins/mamebridge/init.lua  (плагин MAME)
   │  читает запрос, исполняет в дебаггере MAME, атомарно пишет ответ
   ▼
MAME debugger ──> эмулируемая машина (Sprinter / любой CPU)
```

- **IPC**: текстовые файлы `req_<id>.txt` / `resp_<id>.txt` в общей папке
  (по умолчанию `/tmp/mame_mcp`). Запись атомарная (`.tmp` + rename).
- **Почему плагин, а не `-autoboot_script`**: старый `mame_bridge.lua` опрашивал
  IPC через `emu.add_machine_frame_notifier`, который **молчит, пока машина
  hard-stopped** в дебаггере → интерактивный stop→step→inspect зависал. Плагин
  качает опрос через **`emu.register_periodic()`**, который вызывается из
  `emulator_info::periodic_check()` ВНУТРИ цикла дебаггера
  `while (is_stopped())` (src/emu/debug/debugcpu.cpp). → шаги/инспекция в стопе
  работают.
- **Совместимость**: протокол IPC у `mame_bridge.lua` (fallback) и плагина
  идентичен — `mame_mcp.py` один и тот же.

### Файлы (всё в /Users/tolik/Documents/GitHub/mame)
| Файл | Роль |
|------|------|
| `plugins/mamebridge/init.lua` | плагин-мост (вся логика команд, ввод, scrpix) |
| `plugins/mamebridge/plugin.json` | манифест, `"name":"mamebridge"`, `"start":"false"` |
| `src/mame_mcp.py` | FastMCP-сервер, объявляет MCP-инструменты |
| `src/mame_bridge.lua` | старый autoboot-вариант, fallback для live-инспекции |
| `src/CLAUDE.md` | подробная проектная документация (источник истины) |

### Ключевое про окружение
- `plugins/` — это **симлинк** из активного `pluginspath`:
  `/Users/tolik/Documents/MAME/plugins → /Users/tolik/Documents/GitHub/mame/plugins`.
  → правки файлов плагина в репозитории **сразу** живые (Lua интерпретируется),
  пересборка MAME НЕ нужна.
- Запускать **только ОДИН** `mame` против одной `MAME_MCP_DIR`. Второй инстанс не
  стартует, а застрявший первый продолжит отвечать СТАРЫМ кодом плагина — путаница.
- Запускать с реальным конфигом (`-bios dev` + диски), см. `~/Documents/MAME/Debug.sh`.
  Без `-bios dev` дефолтный BIOS `sp2k` отсутствует и машина не стартует.
- Плагин `portname` когда-то ронял загрузку (`register_start` удалён из API).
  Если снова `attempt to call a nil value` на старте — это он; запусти с
  `-noplugin portname` либо проверь, что он использует `add_machine_reset_notifier`.

### Переменные окружения (должны совпадать на обеих сторонах)
| Переменная | Что | Дефолт |
|------------|-----|--------|
| `MAME_MCP_DIR` | папка IPC | `/tmp/mame_mcp` |
| `MAME_MCP_CPU` | тег CPU | `:maincpu` |
| `MAME_MCP_SNAP_DIR` | папка скриншотов | `/tmp/mame_snap` (чистится при ребуте) |
| `MAME_MCP_TIMEOUT` | таймаут ожидания ответа (сторона Python) | `10` сек |

---

## 2. MCP-инструменты (что я вызываю)

Адреса принимают `"0xC000"`, голый hex `"C000"` или десятичное `"49152"`
(нормализует `parse_addr`).

**CPU / память**
- `read_registers()` — регистры Z80/8080 (PC, SP, AF, BC, DE, HL, IX, IY, ...).
- `read_memory(address, length=16)` — СЫРОЕ программное пространство (без банков).
  На Sprinter окна Z80 живут в program 0x10000+ — для логики используй lmem.
- `read_logical_memory(address, length=16)` — как видит Z80 через банки
  (логический 0x0000–0xFFFF → program `0x10000|addr`). **Обычно нужен этот.**
- `read_vram(address, length=16)` — напрямую из видеоОЗУ (share `:vram`, 256K),
  минуя банкинг. Для пиксельных данных, тайлов/дескрипторов, палитры.
- `read_share(name, address, length=16)` — из именованного share (`vram`,
  `fastram`, ...). См. `list_shares()`.
- `list_shares()` — список share/region (теги + размеры).
- `write_memory(address, hex_bytes)` — запись в program space (`"3E01CD0500"`).
  Для логического вида Z80 пиши по `0x10000|addr`.

**Точки останова / шаги**
- `set_breakpoint(address, condition="")` — PC-брейк; condition — выражение
  дебаггера (`"A==0"`). Возвращает индекс.
- `clear_breakpoint(index)`, `list_breakpoints()`.
- `set_watchpoint(address, length, access="w", space="program")` — `r`/`w`/`rw`;
  `space`=`program`(умолч.)|`data`|`io`|`opcodes` (напр. `space="io"` ловит Z80
  IN/OUT по порту). Bridge-verb: `wp ADDR LEN ACCESS [space]`. Ставится нативно
  (`cpu().debug:wpset`); адрес ЛИТЕРАЛЬНЫЙ в пространстве — для Z80-окна в program
  давай 0x10000+ (напр. 0x18000 = окно 2).
- `clear_watchpoint(index)`.
- `step(count=1)`, `step_over(count=1)` (CALL до конца), `step_out()`.
- `resume()` (cont), `pause()`, `status()` (running/stopped + PC).
- `disassemble(address, num_bytes=32)`.

**Экран**
- `scrpix(x,y,w,h)` — ⭐ ОСНОВНОЙ способ «смотреть»: читает ОТРИСОВАННЫЕ пиксели
  через `screen:pixel(x,y)`, по 4 hex-символа на пиксель (пен), row-major,
  до 8192 px. Это видеовыход, декодированный железом → правильные экранные коорд.,
  без ручной возни с тайлами/4bpp/буфером.
- `screenshot(name="")` — PNG активного экрана, возвращает путь. **Последнее
  средство** (дорого по токенам, коорд. «на глаз»). Снимок = последний
  отрисованный кадр; в hard-stop сначала ненадолго `resume()` для свежего кадра.

**Ввод (клавиатура/мышь/джойстик)** — машина должна быть RUNNING (`resume` перед вводом)
- `list_ports()` — порты и поля (тег, маска, имя).
- `press_key(key, frames=3)` — нажать ИМЕНОВАННУЮ клавишу на N кадров с
  авто-отпусканием. Бьёт по ОБЕИМ клавиатурам (PC + ZX), где есть эквивалент.
- `type_text(text, coded=False)` — печать через natkeyboard; если `coded`,
  понимает `{ENTER}` и пр. (но НЕ курсорные стрелки). Для UI прошивки лучше press_key.
- `move_mouse(dx, dy, frames=3)` — двигать ОБЕ мыши (Kempston + RS232 COM),
  относительные оси накапливаются за кадры.
- `click_mouse(button="left", frames=3)` — клик (left/right/middle) на обеих мышах.
- `press_input(port, mask, frames=2)` — низкоуровневый цифровой ввод
  (`press_input(':JOY1','0x400')`).
- `set_input(port, mask, value, frames=0)` — задать поле (analog/digital).
- `debugger_command(raw)` — ⭐ escape-hatch: любая команда консоли дебаггера
  (`"print pc"`, `"print (ib@C9)"`, `"trace t.log"`, `"exit"`).

---

## 3. Чтение портов эмулируемой машины

Чтобы узнать значение, которое выдаёт порт: в консоли дебаггера
`print (ib@C9)` (читает io-байт порта 0xC9, напр. rgmod). Через мост:
`debugger_command("print (ib@C9)")`. `ib@<addr>` = io-space byte по адресу.

**Не путать внешние и внутренние порты Sprinter:**
- **Внешние** — порты, с которыми Z80 работает через OUT/IN.
- **Внутренние** — порты конфигурации Altera FPGA, маппятся на внешние через
  таблицу DCP (decoded control ports).

Активный двойной буфер экрана выбирается портом **rgmod**.

---

## 4. Sprinter: карта памяти и видео (проверено вживую по sinclair/sprinter.cpp)

CPU **z84c015**, ТРИ пространства: program (mem), io, opcodes (fetch).
Память **банкируемая** — читать с осторожностью (поэтому путь B/Lua-мост, а не
gdbstub: gdbstub видит плоское адресное пространство и не следит за банками).

**Банкинг — 64K логических Z80 → физические страницы:**
- 4 окна по 16K. Program-пространство ШИРЕ 64K: окна живут в program 0x10000+
  (`map_mem`, sprinter.cpp:1448): win0 Z80 0x0000–0x3FFF → program 0x10000;
  win1 0x4000→0x14000; win2 0x8000→0x18000; win3 0xC000→0x1C000.
- `mem L` (сырой program 0..0xFFFF) идёт в `bootstrap_r` (sprinter.cpp:1185),
  который форвардит в `0x10000|L` *после* загрузки FPGA-битстрима, а пока грузится
  — отдаёт fastram (ненадёжно на раннем этапе). Используй `lmem` (читает
  `0x10000|L`) для реального вида Z80. Проверено: lmem == mem(0x10000|L) == dasm.
- Физ. страницы — `m_ram` (по умолчанию 64M), индекс `page<<14`
  (configure_entries, sprinter.cpp:1577). Страница окна считается в
  `update_memory` (sprinter.cpp:327) из кучи портов (m_pn/7FFD, m_sc/1FFD, m_cnf,
  m_dos, m_rom_rg, ...) через DCP-таблицу `m_ram_pages`. Если `page&0xF0==0x50` —
  это апертура VRAM: `phys = (0x50<<14)+m_port_y*1024+(offset&0x3FF)`.

**Видео (VRAM = 256K share `:vram`, читать через `read_vram`):**
- Выбор режима: `m_conf` (Game Config) → screen_update_game, иначе
  screen_update_graph (sprinter.cpp:404). Режимы: 320x256x256, 640x256x16,
  Spectrum, text.
- Per-16x8-тайл 4-байтный «mode descriptor»:
  `as_mode(a,b)=vram+(1+a*2+0x80*(m_rgmod&1))*1024+0x300+b*4` (sprinter.cpp:554).
- Пиксель (draw_tile, sprinter.cpp:453):
  `color = vram[(y+((dy-hold.y)&7>>lowres))*1024 + x + ((dx-hold.x)&15>>(1+lowres))]`,
  `x=(mode[0][0:4]<<6)|(mode[1][0:3]<<3)`, `y=mode[1][3:8]<<3`. 8bpp если
  mode[0] bit5, иначе 4bpp (2 px/байт). База палитры `= mode[0][6:8]<<8`.
- Палитра — в VRAM: запись по `laddr>=0x3E0` ставит пен
  `(offset[2:5]*256 + offset>>10)` = RGB-тройка по `offset&~3` (vram_w
  sprinter.cpp:1287). 256 пенов × 8 палитр. Текстовые пены `0x400+`.

**Брейк-/вотчпойнты по регионам:**
- PC-брейки берут логический 0..0xFFFF (fetch-пространство) — независимо от банка.
- Вотчпойнты по умолчанию в program space: `wpset ADDR,LEN,rw`. Для конкретного
  окна Z80 — адрес 0x10000+.
- Поймать ПЕРЕКЛЮЧЕНИЕ БАНКОВ — io-вотчпойнт на порты пейджинга. В текущем MAME
  команда ЗАВИСИТ ОТ ПРОСТРАНСТВА: `wpiset` для io (старая форма
  `wpset ADDR,1,w,1,1,i` отвергается — "too many parameters"). Напр.
  `debugger_command("wpiset 0xc1,1,w")` (порт 0xC1=m_pn) или 0xC0 (m_sc),
  0xC4 (m_port_y), 0xC5 (m_rgmod), 0xC6 (m_cnf). (`wpset`=program, `wpdset`=data,
  `wpiset`=io.) ВАЖНО: порты, которые пишутся внутренне через FPGA/DCP (напр. rgmod
  0xC9), io-вотчпойнт НЕ ловит — туда нет Z80-команды OUT; io-wp ловит только
  реальные IN/OUT по этому порту.
- `m_pages/m_pn/...` — приватные C++ члены, в Lua НЕ проброшены. Чтобы понять
  текущий банкинг — следи за портами или читай копии DCP в m_ram.

---

## 5. Ввод в Sprinter (проверено вживую)

**Ввод обрабатывается только пока машина RUNNING** — frame-нотифаеры и таймер
natkeyboard не тикают в hard-stop. Значит `resume` ПЕРЕД вводом (и `pause` после,
если надо). Плагин держит каждое нажатие N кадров, переустанавливая `set_value(1)`
каждый кадр (MAME перечитывает поля покадрово), и сам отпускает по номеру кадра.

**Всё в ДВУХ экземплярах.** На реальном хосте одно нажатие идёт в ОБЕ клавиатуры,
движение — в ОБЕ мыши. Поэтому `press_key`/`move_mouse`/`click_mouse` бьют по обеим:
- **Клавиатуры**: PC PS/2 `:kbd:ms_naturl:P1.0..P2.7` (его читает Flex Navigator и
  большинство прошивок — проверено: курсор/Tab двигают UI) И ZX-матрица
  `:IO_LINE0..7`. `press_key` маппит имена в обе, где есть эквивалент.
- **Мыши**: Kempston `:mouse_input1/2` (X/Y маска 0xFF) + кнопки `:mouse_input3`, И
  RS232 COM `:rs232:microsoft_mouse:X/Y` (маска 0xFFF) + `:BTN`. **В Flex Navigator
  читается COM-мышь, а не Kempston.** Оси относительные → движение держим
  несколько кадров для накопления.
- **Джойстики**: `:JOY1`/`:JOY2` (A=0x400, B=0x010, Up=0x208, Down=0x104,
  Left=0x002, Right=0x001) через `press_input`.

Имена клавиш в `press_key`: a–z, 0–9, enter, space, esc, tab, backspace,
up/down/left/right, home, end, pgup, pgdn, ins, del, f1–f12, shift, ctrl, alt,
symbolshift и символы `; ' / . , - = [ ] \ ` `.

**ВАЖНО про скорость и «залипание»** (объяснение пользователя):
> «Мышка и клавиши летят в буферы SIO процессора на скорости 1200 бод, поэтому
> зажатие клавиши на несколько кадров может сгенерировать много повторов.»

PS/2 typematic delay ≈ 60 опросов @60Гц ≈ 1 сек. Поэтому:
- для ОДИНОЧНОГО нажатия держи мало кадров (frames=2..3) — иначе авто-повтор
  «настрочит» символ десятки раз и список/курсор «улетит»;
- между одиночными нажатиями есть естественная пауза из-за 1200 бод — это нормально,
  «быстрее» = риск повторов.

ZX-токены: в TR-DOS работают токены клавиатуры как в BASIC спектрума, поэтому
**`LIST` — это ОДНА клавиша `K`** (IO_LINE6, маска 0x04).

`type_text` использует natkeyboard, но целится в ОДНУ клавиатуру и требует in_use;
для UI прошивки предпочитай `press_key`. natkeyboard НЕ умеет курсорные стрелки.
Перед natkeyboard выбери целевую клавиатуру (в плагине — команда `kbsel ms_naturl`).
`list_ports` — чтобы заново найти теги/маски.

---

## 6. Как «смотреть» на экран — три метода и что выбирать

Оценка по скорости / точности / токенам:

| Метод | Скорость | Точность коорд. | Токены | Когда |
|-------|----------|-----------------|--------|-------|
| **scrpix** (`screen:pixel`) | средняя | **пиксель-точно** (декодировано железом) | **дёшево** (hex обрабатывать в python-скрипте, в контекст — только вывод) | ⭐ по умолчанию для наблюдения экрана и наведения |
| **raw VRAM** (`read_vram`) | средняя | требует ручного декодера (тайлы/4bpp/буфер) — ненадёжно | дёшево | только для того, чего нет в отрисовке: back-buffer, палитра, дескрипторы тайлов |
| **screenshot** (PNG) | быстрее всего для всего экрана | «на глаз» | **дороже всего** (картинка целиком в контекст) | последнее средство, быстрый визуальный гештальт |

**Правило (предпочтение пользователя):** МИНИМИЗИРОВАТЬ скриншоты. По умолчанию —
scrpix; raw VRAM — для «закулисных» данных; скриншот — только если иначе никак.

**Двойная буферизация (важно при чтении VRAM напрямую):** в видеопамяти ДВА
экрана — один отображается, второй в это время прорисовывается; после готовности
буферы переключаются. Активный набор дескрипторов выбирается портом **rgmod**
(`print (ib@C9)`). Список UI рисуется в АКТИВНОМ буфере (+0x20000), а КУРСОР мыши —
в ДРУГОМ буфере. Рекомендация: ставить эмулятор на `pause` и дампить именно
отображаемый экран (по rgmod). Из-за этого raw-VRAM-диффы давали ложные коорд.
курсора → **для курсора предпочитай scrpix**.

**Поиск курсора сложен:** текст И курсор оба белые (пен `0xFFFF`=65535), цветом не
изолировать — только ДИФФОМ (чуть двинуть мышь, сравнить два scrpix-грэба;
изменившиеся пиксели = курсор). Точка клика = **крайний левый верхний пиксель**
курсора.

**НЕ РЕШЕНО надёжно:** замкнутое наведение мыши на конкретный мелкий пункт.
Дифф-поиск курсора флакки (пробное движение + тайминги/буфер теряют курсор),
масштаб мышь→пиксель плывёт. **Надёжный путь — навигация клавиатурой** (точные
одиночные `press_key`). Если мышь macOS не в зоне окна MAME — координаты могут
«замораживаться».

---

## 7. Что уже отлажено и работает

- ✅ Конвертация в плагин; брейки/шаги/инспекция РАБОТАЮТ в hard-stop
  (`register_periodic`).
- ✅ Чтение банкируемой памяти (`lmem`), VRAM/палитры, портов (`print (ib@)`).
- ✅ Полное управление клавиатурой с точными одиночными нажатиями. Тест 1 пройден:
  навигация в C:\ZX\, запуск sprinter.zx → меню ZX → TR-DOS → выполнен `LIST`.
- ✅ Защитное отпускание ввода на `pause` (release_all) и авто-отпускание по
  номеру кадра (tick_held в register_periodic) — иначе typematic-шторм.
- ⚠️ Частично/НЕ решено: надёжное замкнутое наведение мыши на мелкий пункт через
  VRAM/scrpix (см. §6). Клавиатура — рабочий обходной путь.

**Структура списка в Flex Navigator (C:\ZX\):** строки текста с шагом 8px; левая
панель — колонки ~x48–150 (col1) и ~x166–220 (col2 с pent_*/sprinter);
sprinter.zx ≈ строка 6 колонки 2. (Это эвристика из наблюдений, не «читы из RAM».)

---

## 8. Типовые рецепты

**Старт отладочной сессии:**
```
status()                       # running/stopped + PC
set_breakpoint("0x8000")       # PC-брейк (логический адрес)
resume()
# ...брейк сработал, машина в стопе...
status()                       # state=stop, БЕЗ таймаута (это и есть фикс плагина)
read_registers(); step(); read_registers()   # PC двигается, оставаясь в стопе
```

**Проверка банкирования:** прочитать байт из банкируемого региона → переключить
банк (программой или `write_memory` в порт пейджинга) → снова прочитать тот же
адрес: значение должно измениться (чтение идёт через живое адресное пространство).

**Посмотреть кусок экрана дёшево:** `scrpix(x,y,w,h)` → получить hex-пены →
обработать в python (искать пятно/край/дифф) → в контекст вернуть только вывод.

**Корректно остановить MAME:** `debugger_command("exit")` (НЕ kill).

---

## 9. Источник истины и расширение

- Полная проектная документация: `/Users/tolik/Documents/GitHub/mame/src/CLAUDE.md`.
- Логика моста (можно править — изменения живые из-за симлинка):
  `/Users/tolik/Documents/GitHub/mame/plugins/mamebridge/init.lua`.
- Объявления MCP-инструментов: `/Users/tolik/Documents/GitHub/mame/src/mame_mcp.py`.
- Эталон стиля плагина MAME: `/Users/tolik/Documents/GitHub/mame/plugins/gdbstub/`.

---

## 10. Авторитетный справочник API и команд (из docs.mamedev.org)

Сверено с официальной докой: plugins, luascript (ref-common/core/devices/mem/
input/debugger), debugger (general/execution/watchpoint…). Здесь — то, что
неочевидно или чем стоит пользоваться вместо строк `cmd`.

### 10.1 Lua-API дебаггера (нативный — чище, чем `cmd "..."`)
`machine.debugger` (manager.machine.debugger; `nil` если без `-debug`):
- `.execution_state` (rw) — `"run"` / `"stop"`. `.visible_cpu` (rw).
- `.consolelog[]`, `.errorlog[]` (ro) — строки вывода консоли/ошибок (можно ЧИТАТЬ
  результат команд, а не только слать их!).
- `:command(str)` — выполнить консольную команду дебаггера.

`device.debug` (напр. `manager.machine.devices[":maincpu"].debug`):
- `:bpset(addr [,cond] [,act])` → номер bp; `:bpclear([n])`, `:bpenable([n])`,
  `:bpdisable([n])`, `:bplist()` → таблица (поля bp: `.index .enabled .address
  .condition .action`).
- `:wpset(space, type, addr, len [,cond] [,act])` — type `"r"|"w"|"rw"`, `space` —
  объект адресного пространства (см. 10.4); `:wpclear([n])`, `:wplist(space)`
  (поля wp: `.index .enabled .type .address .length .condition .action`).
- `:step([cnt])`, `:go()` (нативных `over`/`out`/disassemble НЕТ — они остаются на
  `cmd`). `bpset`/`wpset` в биндинге требуют `cond` и `act` как `char*` → передавай
  `""` если не нужны.
> ПРИМЕНЕНО В МОСТЕ: `bp`/`bpclr`/`bplist`/`wp`/`wpclr`/`step` идут через нативный
> `cpu().debug:*` (структурные возвраты: числовой индекс, таблицы; без скрейпинга
> consolelog). `over`/`out`/`dasm` — по-прежнему `run_cmd` (нет нативных).
> ВАЖНО: нативный `wpset` берёт адрес ЛИТЕРАЛЬНО в выбранном пространстве (без
> трансляции банков) — для Z80-окна в program давай 0x10000+ (напр. 0x18000 =
> окно 2), как в `write_memory`/`mem`. (Старый консольный `wpset 0x8000`
> неожиданно релоцировал в 0x18000; нативный — литеральный и предсказуемый.)

### 10.2 Команды дебаггера — авторитетный синтаксис
- Watchpoints: `wp[{d|i|o}][set] <addr>[:<space>],<len>,<type>[,<cond>[,<act>]]`.
  `wpset`=program, `wpdset`=data, **`wpiset`=io**, `wposet`=opcodes. Можно и через
  суффикс пространства: `wpset 0xC9:io,1,w`. Переменные в cond/act: `wpaddr`,
  `wpdata`. Ещё: `wpclear/wpdisable/wpenable [n,…]`, `wplist [cpu]`.
- Breakpoints: `bpset <addr>[,<cond>[,<act>]]`, `bpclear/bpdisable/bpenable [n,…]`,
  `bplist`.
- Шаги/выполнение: `s[tep] [n]`, `o[ver] [n]`, `out`, `g[o] [addr]`,
  `gv[blank]`, `gi[nt] [irqline]`, `gt[ime] <ms>`, `ge[x] [exc,[cond]]`,
  `gbt [cond]` / `gbf [cond]` (взятая/невзятая ветвь), `n[ext]` (до смены CPU),
  `focus/ignore/observe <cpu>`, `trace {file|off}[,cpu[,…]]`, `traceover`,
  `traceflush`.
- Общие: `print <expr>[,…]` (hex), `printf <fmt>[,arg…]` (%d %x %X %o %c %s %%),
  `logerror`, `history [cpu[,len]]`, `softreset`, `hardreset`, `help [topic]`.

### 10.3 Выражения и операторы доступа к памяти
Форма: `[prefix]<size>[@|!]<addr>`.
- size: `b`=8, `w`=16, `d`=32, `q`=64.
- `@` = ПОДАВИТЬ side-effects (безопасное чтение), `!` = НЕ подавлять.
- prefix пространства: `p`/`lp`=program(лог.), `d`/`ld`=data, `i`/`li`=io,
  `3`/`l3`=opcodes; физические — `pp pd pi p3`; `r`=прямой указатель program,
  `o`=прямой opcodes, `m`=region, `s`=share.
- Примеры: `b@1234` (program byte), **`ib@C9`** (io byte, как мы читаем rgmod),
  `dw@300` (data word), `pp b@addr` (физ. program byte).
- Встроенные функции: `min/max(a,b)`, `if(cond,t,f)`, `abs(x)`, `bit(x,n[,w])`,
  `s8/s16/s32(x)` (знаковое расширение).
- Адресация устройства/пространства: `[tag][:space]` или `cpunum[:space]`
  (напр. `maincpu`, `^melodypsg`, `.:adc`).

### 10.4 Память (Lua)
- Пространство: `dev.spaces[name]` (напр. `cpu.spaces["program"]`/`"io"`/
  `"opcodes"`). Чтение: `:read_u8/16/32/64(addr)` (+ `_i` знаковые), логические
  `:readv_*`, прямые `:read_direct_*`. **`:read_range(start,end,width[,step])` →
  бинарная строка** (быстрый пакетный дамп — полезно для mem/vram). Запись:
  `:write_u8/…(addr,val)`, `:writev_*`. Свойства: `.name .data_width
  .address_mask .endianness`.
- Share/region: `machine.memory.shares[tag]` / `.regions[tag]` / `.banks[tag]`
  (или `device:memshare(tag)`, `device:memregion(tag)`); `:read/​write_u8/…`,
  `.length .endianness .bitwidth`.
- ПРИМЕНЕНО В МОСТЕ: `mem`/`lmem`/`vram`/`share` читают через ОДИН
  `obj:read_range(addr,addr+len-1,8)` (вместо `len` вызовов `read_u8` с pcall) +
  быстрый hex по lookup-таблице. Фолбэк на побайтовый цикл, если у объекта нет
  `read_range` (например, у share). Проверено: байт-в-байт совпадает с прежним.

### 10.5 Lifecycle / события (emu) — ВАЖНЫЙ нюанс
- Документированы: `emu.add_machine_{reset,stop,pause,resume,frame,pre_save,
  post_load}_notifier(cb)` → объект подписки с `:unsubscribe()` и `.is_active`;
  корутинные `emu.wait(sec)`, `emu.wait_next_frame()`, `emu.wait_next_update()`;
  логи `emu.print_{error,warning,info,verbose,debug}`; `emu.subst_env`.
- **`emu.register_periodic(fn)` в доке ОТСУТСТВУЕТ**, но реален (luaengine.cpp:933)
  и КРИТИЧЕН: он качается из `emulator_info::periodic_check()` в цикле
  `while(is_stopped())` ДО `wait_for_debugger`, поэтому работает в hard-stop при
  любом OSD-дебаггере. `add_machine_frame_notifier` в стопе МОЛЧИТ. → для pump
  IPC/опроса в дебаггере используй `register_periodic`, а не frame-нотифаер.

### 10.6 Плагин и манифест
- `plugin.json`: `{ "plugin": { "name", "description", "version", "author",
  "type": "plugin"|"library", "start": "false" } }`. Грузится `-plugin <name>`;
  путь поиска `-pluginspath`; `start:false` → только по явному запросу.
- `init.lua`: таблица `exports` с `name/version/description/license/author` и
  функцией `exports.startplugin()`; в конце `return exports`. Runtime-объект:
  `manager.plugins[name]` (`.name .description .type .directory .start`).
- Эталоны: `plugins/gdbstub/` и наш `plugins/mamebridge/`.
- Встроенные плагины MAME: autofire, console, data, discord, dummy, gdbstub,
  hiscore, inputmacro, layout, offscreen reload, timecode, timer.

Язык общения с пользователем: **русский**.
