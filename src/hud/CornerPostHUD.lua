-- EN: Corner Post HUD — a 2D replica of the John Deere S770 corner post, drawn as a large
--     popped-out panel rather than a small in-corner widget.
--
--     WHY 2D AND WHY LARGE
--     The in-cab 3D post is authentic but camera-dependent, and at true scale it is far too
--     small to read while also watching the field. For training, both people need to see it:
--     the student to react, the instructor to confirm the student reacted. So it is drawn
--     screen-space, oversized, and always visible.
--
--     LAYOUT AUTHORING
--     Everything is positioned in PANEL UNITS — a virtual canvas PANEL_W x PANEL_H with the
--     origin at the TOP-LEFT, matching how you would measure pixels off a reference image or
--     an art layer. toScreen() converts to FS25's bottom-up normalised screen space and
--     applies aspect correction, so a cell authored as square renders square on any monitor.
--     Consequence: when the real artwork arrives, updating this display is editing numbers in
--     the LAYOUT table below, not touching drawing code.
--
--     PLACEHOLDER STATE
--     Until the HD atlas exists, every element is drawn as a tinted quad using the mod's 1x1
--     white texture. The geometry, proportions, colour logic and all live data are already
--     final — only the surface finish is standing in. Constants that are guesses rather than
--     measurements are marked REFERENCE NEEDED.
--
-- UA: HUD кутової стійки — 2D-репліка стійки John Deere S770, велика винесена панель,
--     а не маленький віджет у кутку.
--     2D і ВЕЛИКА: тривимірна стійка в кабіні автентична, але залежить від камери й надто
--     дрібна. Для навчання її мають бачити обидва — студент і інструктор.
--     РОЗМІТКА в ОДИНИЦЯХ ПАНЕЛІ (віртуальне полотно PANEL_W x PANEL_H, початок згори-зліва),
--     як вимірюють пікселі на référence-зображенні. toScreen() переводить у екранний простір
--     FS25 і застосовує корекцію співвідношення сторін.
CornerPostHUD = {}
CornerPostHUD.__index = CornerPostHUD

-- ============================================================================
-- EN: Authoring canvas. Chosen to match the reference post's proportions
--     (roughly 1 wide : 2.67 tall for the whole two-panel stack).
-- UA: Полотно розмітки — пропорції як у реальної стійки (приблизно 1 : 2.67).
-- ============================================================================
local PANEL_W = 100
local PANEL_H = 214

-- EN: Layout in panel units, y measured DOWNWARD from the top edge.
--     REFERENCE NEEDED markers are values I estimated from the screenshot rather than
--     measured; they are the first things to correct against the HD art.
-- UA: Розмітка в одиницях панелі, y — вниз від верхнього краю.
--     PANEL ORDER: machine state on TOP, losses on the BOTTOM.
--     This matches the real unit — the operator glances up for rpm and speed while driving,
--     and looks down at the loss page when actually setting the machine.
-- UA: ПОРЯДОК ПАНЕЛЕЙ: стан машини ЗВЕРХУ, втрати ЗНИЗУ — як на реальній стійці.
CornerPostHUD.LAYOUT = {
    -- ========================================================================
    -- EN: UPPER PANEL — machine state. What you watch while driving.
    -- UA: ВЕРХНЯ ПАНЕЛЬ — стан машини.
    -- ========================================================================
    upper        = { x = 4,  y = 3,  w = 92, h = 86 },

    -- EN: Four gauges, left to right: engine load, coolant temperature, fuel, DEF.
    --     Each is a fixed colour scale with a white level bar beside it — the colours never
    --     move, the bar does.
    --
    --     The whole upper stack starts at 8 rather than 15: the info badge that used to head
    --     the panel is gone, and that space now goes to the speed readout, which was running
    --     off the bottom edge of the panel and getting clipped.
    -- UA: Чотири датчики: навантаження, температура, пальне, DEF. Нерухома кольорова шкала
    --     і біла смуга рівня поруч. Весь блок піднято до 8: значок інформації прибрано, і це
    --     місце віддано показнику швидкості, який раніше обрізався нижнім краєм панелі.
    gaugeLoad    = { x = 9,  y = 8, w = 18, h = 34 },
    gaugeCoolant = { x = 30, y = 8, w = 18, h = 34 },
    gaugeFuel    = { x = 51, y = 8, w = 18, h = 34 },
    gaugeDef     = { x = 72, y = 8, w = 18, h = 34 },
    -- EN: Icon strip under the gauges. Only y and h are used — each icon takes its x and
    --     width from the gauge it labels, so the two cannot fall out of alignment.
    -- UA: Смуга іконок під датчиками. Використовуються лише y і h — x і ширину кожна іконка
    --     бере від свого датчика, тож вони не можуть розійтися.
    gaugeIcons   = { x = 9,  y = 44, w = 81, h = 12 },

    -- EN: Engine speed — the largest readout on the panel, as on the machine.
    rpm          = { x = 17, y = 57, w = 58, h = 16, digits = 4, label = "rpm" },

    -- EN: Ground speed. Its bottom edge must clear the upper panel's (89) — at y = 74 with
    --     h = 14 it ends at 88, with a unit to spare. It previously ran to 94 and the lower
    --     half of the digits was painted outside the panel, over the field.
    -- UA: Швидкість. Нижній край має лишатися в межах верхньої панелі (89): 74 + 14 = 88.
    --     Раніше було 94 — нижня половина цифр малювалась поза панеллю.
    speed        = { x = 17, y = 74, w = 58, h = 14, digits = 4, label = "MPH" },

    -- EN: The info badge and the gear/park indicator boxes were removed. All three were
    --     placeholder grey squares with nothing driving them — a blank box beside a live
    --     readout reads as a broken element, which is worse than an empty margin. Reinstate
    --     them only alongside real state and proper glyphs.
    -- UA: Значок інформації та індикатори передачі й гальма прибрано: усі три були порожніми
    --     сірими квадратами без даних, а порожня рамка читається як зламаний елемент.

    -- ========================================================================
    -- EN: LOWER PANEL — the loss page. What you work from when setting the machine.
    -- UA: НИЖНЯ ПАНЕЛЬ — сторінка втрат.
    -- ========================================================================
    lower        = { x = 4,  y = 95, w = 92, h = 116 },

    -- EN: Grain moisture heads the loss page — it is the first thing that explains why the
    --     loss numbers are what they are.
    -- UA: Вологість очолює сторінку втрат — саме вона пояснює рівень втрат.
    moisture     = { x = 16, y = 99, w = 54, h = 14, digits = 4, label = "%" },

    -- EN: Grain tank level with its icon, upper-left of the loss page.
    tankBar      = { x = 8,  y = 119, w = 6,  h = 26 },
    tankIcon     = { x = 7,  y = 147, w = 8,  h = 7 },

    -- EN: MACHINE SETTINGS ROW — five columns: chaffer, sieve, fan, rotor, concave, each an
    --     icon over its live value. This replaces the decorative cross-section, which showed
    --     nothing. For training it is the more useful half of the page: the student changes a
    --     setting and both people can see exactly what it now reads, side by side with the
    --     loss columns those settings are moving.
    -- UA: РЯДОК НАЛАШТУВАНЬ — п'ять колонок: решето, сито, вентилятор, ротор, дека; іконка
    --     над живим значенням. Замінює декоративний переріз, який нічого не показував.
    --     Для навчання це корисніша половина сторінки.
    --     Laid out as a 2 + 3 grid mirroring Deere's Harvest Settings page: threshing
    --     clearance and speed on the top row, then the three cleaning settings below.
    --     A single row of five was too narrow — the values ran into each other.
    -- UA: Сітка 2 + 3, як на сторінці Harvest Settings у Deere: зазор і швидкість обмолоту
    --     згори, три налаштування очистки знизу. Один ряд із п'яти був завузький.
    -- EN: Starts at 16 so it clears the tank bar (8..14) instead of drawing the first icon
    --     over it, and runs to 90 to use the full remaining width.
    settingsRow  = { x = 16, y = 118, w = 74, h = 22 },

    -- EN: Icon strip above the columns, identifying each one.
    barIcons     = { y = 148, h = 9 },

    -- EN: THE LOSS COLUMNS, geometry proportioned from the HD draft.
    --     TOTAL is deliberately wider than the two components it sums — that width is how
    --     the real panel gives the headline number its visual weight.
    --     Every column carries full x/y/w/h so each is independently nudgeable and so the
    --     live editor's dump can never drop a stray scalar.
    -- UA: КОЛОНКИ ВТРАТ. TOTAL навмисно ширший за складові — так панель надає йому ваги.
    colShoe      = { x = 12.3, y = 160, w = 12.9, h = 36 },
    colTotal     = { x = 28.7, y = 160, w = 20.0, h = 36 },
    colSep       = { x = 51.8, y = 160, w = 12.4, h = 36 },
    colTail      = { x = 73.9, y = 160, w = 12.5, h = 36 },

    -- EN: Guide strips flanking TOTAL. These carry ALL the colour — amber outside the target
    --     band, green inside — against which the white bars are read.
    -- UA: Напрямні обабіч TOTAL несуть увесь колір: бурштиновий поза смугою, зелений усередині.
    markerL      = { x = 25.7, y = 160, w = 2.6, h = 36 },
    markerR      = { x = 48.9, y = 160, w = 2.4, h = 36 },

}

-- EN: Local alias so the hot draw path does a direct upvalue read rather than a table
--     lookup on the module every frame.
-- UA: Локальний псевдонім — швидкий доступ у шляху малювання.
local LAYOUT = CornerPostHUD.LAYOUT

-- ============================================================================
-- EN: SEGMENT ZONES — the single definition of how a column is divided, counted from the
--     BOTTOM up. Confirmed against the panel: 4 below the green marker, 3 in the green,
--     4 above it, for 11 segments total.
--
--     This one table drives BOTH the green band on the orange threshold strips AND the
--     colour bands of the loss columns, which is what makes them line up. Deriving them
--     separately is exactly how a display ends up with a marker sitting half a cell off from
--     the bar it is supposed to reference — the kind of flaw that is obvious on the machine
--     and invisible in code.
--
--     Zone meaning for a loss column, reading upward:
--       below (1-4)  — AMBER: under the target band
--       green (5-7)  — GREEN: the operating window, where you want the reading to sit
--       above (8-11) — AMBER: over the target band
--
--     Amber both sides, no red anywhere. A loss column is a TARGET BAND, not a severity
--     ramp: drifting low is as much a signal as drifting high, and neither is an alarm
--     state. Red is reserved for the fuel / DEF / engine-load gauges, which genuinely do
--     have a bad end — see GAUGE_ZONES.
-- UA: ЗОНИ СЕГМЕНТІВ — знизу вгору: 4 бурштинові, 3 зелені, 4 бурштинові; разом 11.
--     Бурштиновий з обох боків, червоного немає: колонка втрат — це ЦІЛЬОВА СМУГА, а не
--     шкала тяжкості. Червоний залишений для датчиків пального, DEF і навантаження.
--     Ця таблиця керує І зеленою смугою на порогових стрічках, І кольоровими зонами колонок
--     втрат — саме тому вони збігаються. Роздільне обчислення дає позначку, зсунуту на пів
--     комірки відносно смуги: помітно на машині, непомітно в коді.
-- ============================================================================
-- EN: GAUGE ZONES — the fixed colour scale beside each level bar, as fractions of height
--     measured from the BOTTOM. Unlike the loss columns these DO have a bad end, which is
--     what red is for.
--     redAtTop distinguishes the two senses:
--       engine load — high is bad, so red sits at the top
--       fuel, DEF   — LOW is bad, so red sits at the bottom
--     The photo shows one gauge and cannot disambiguate which way fuel and DEF run, so the
--     direction here is inferred from what the quantity means. One flag each to flip.
-- UA: ЗОНИ ДАТЧИКІВ — нерухома кольорова шкала біля кожної смуги рівня, частки висоти знизу.
--     На відміну від колонок втрат, тут є "поганий" кінець — саме для нього червоний.
--     Навантаження: високе = погано (червоний зверху). Пальне і DEF: НИЗЬКЕ = погано
--     (червоний знизу). Напрямок для пального/DEF виведено зі змісту величини.
--     Each gauge declares its full-scale value and an ordered list of zones by THRESHOLD,
--     not by fraction. That distinction matters: engine load's boundaries are real numbers
--     the operator knows — green ends at 100%, red begins at 120% — and expressing them as
--     fractions of an arbitrary scale would bury those numbers and make them drift the
--     moment the scale changed.
-- UA: Кожен датчик оголошує повну шкалу і зони за ПОРОГАМИ, а не частками. Це важливо:
--     межі навантаження — реальні числа (зелений до 100%, червоний від 120%), і виражати їх
--     частками означало б сховати ці числа й зсунути їх при зміні шкали.
local GAUGE_SPECS = {
    -- EN: Engine load. 100% is rated capacity — the green/amber boundary. 120% is where the
    --     machine is genuinely in trouble. Scale runs to 140 so there is headroom above red;
    --     a bar pinned at the top tells you nothing about how far past the limit you are.
    -- UA: Навантаження. 100% — номінал (межа зеленого), 120% — початок червоного.
    --     Шкала до 140, щоб було видно, наскільки перевищено межу.
    load = { max = 140, zones = {
        { upto = 100, color = "segGreen" },
        { upto = 120, color = "segAmber" },
        { upto = 140, color = "segRed"   },
    }},

    -- EN: Coolant temperature, degrees C. Cosmetic — see readCoolantC in TelemetryProvider
    --     for what actually backs it. Normal running sits in the green band.
    -- UA: Температура охолоджувальної рідини, °C. Косметичний показник.
    coolant = { max = 120, zones = {
        { upto = 100, color = "segGreen" },
        { upto = 110, color = "segAmber" },
        { upto = 120, color = "segRed"   },
    }},

    -- EN: Fuel and DEF, percent. These run the other way — EMPTY is the bad end — so the
    --     red band sits at the BOTTOM of the scale rather than the top.
    -- UA: Пальне і DEF, відсотки. Тут поганий кінець — порожньо, тому червона зона ЗНИЗУ.
    fuel = { max = 100, zones = {
        { upto = 10,  color = "segRed"   },
        { upto = 25,  color = "segAmber" },
        { upto = 100, color = "segGreen" },
    }},

    -- EN: DEF uses the same thresholds as fuel but is spelled out rather than aliased to it.
    --     An alias would share one table, so tuning fuel's amber point would silently move
    --     DEF's too — they happen to agree today, but nothing says they must.
    -- UA: DEF має ті самі пороги, що й пальне, але записаний окремо, а не як псевдонім:
    --     спільна таблиця означала б, що зміна порогу пального тихо змінює й DEF.
    def = { max = 100, zones = {
        { upto = 10,  color = "segRed"   },
        { upto = 25,  color = "segAmber" },
        { upto = 100, color = "segGreen" },
    }},
}

-- EN: Which placeholder glyph identifies each column. TOTAL is absent because it is marked
--     by the sigma badge instead, which says something the other icons cannot: that the
--     column is computed from its neighbours rather than measured.
-- UA: Яка тимчасова іконка позначає кожну колонку. TOTAL відсутній — його позначає сигма.
-- EN: Everything the renderer needs to know about a loss column, in one place and built once.
--     This used to be three separate tables — an icon map here, plus a geometry map and a
--     segment map rebuilt inside draw() on every frame — which meant adding a column meant
--     remembering three edits, and the draw path churned tables at 60 Hz for data that never
--     changes. LAYOUT and the telemetry field are referenced BY NAME rather than captured, so
--     the live editor can keep mutating LAYOUT in place without this going stale.
-- UA: Усе, що рендерер має знати про колонку втрат, в одному місці й будується один раз.
--     Раніше це були три окремі таблиці, дві з яких створювались щокадру всередині draw().
--     LAYOUT і поле телеметрії згадуються ЗА ІМЕНЕМ, тож редактор може змінювати LAYOUT.
local COLUMNS = {
    shoeLoss  = { geom = "colShoe",  seg = "shoeSeg",  icon = "shoe"     },  -- icon_cln.dds
    totalLoss = { geom = "colTotal", seg = "totalSeg", icon = "total"    },  -- icon_total.dds
    sepLoss   = { geom = "colSep",   seg = "sepSeg",   icon = "sep"      },  -- icon_sep.dds
    tailings  = { geom = "colTail",  seg = "tailSeg",  icon = "tailings" },  -- icon_tailings.dds
}

-- EN: The four gauges, likewise stated once. Previously the gauges were drawn by four
--     hand-written calls and their icons by a separate list rebuilt each frame, so the two
--     could disagree about which gauge was which — and did, before the icons were pinned to
--     gauge geometry.
-- UA: Чотири датчики, так само описані один раз. Раніше датчики малювались чотирма окремими
--     викликами, а їхні іконки — окремим списком, який будувався щокадру.
local GAUGES = {
    { icon = "load",    geom = "gaugeLoad",    field = "engineLoad", spec = "load"    },
    { icon = "coolant", geom = "gaugeCoolant", field = "coolantC",   spec = "coolant" },
    { icon = "fuel",    geom = "gaugeFuel",    field = "fuelPct",    spec = "fuel"    },
    { icon = "def",     geom = "gaugeDef",     field = "defPct",     spec = "def"     },
}

-- EN: Machine settings grid, 2 + 3 as on Deere's Harvest Settings page. `field` is read from
--     the telemetry table at draw time; `param` selects the unit and decimals.
-- UA: Сітка налаштувань 2 + 3, як на сторінці Harvest Settings.
local SETTING_ROWS = {
    { { icon = "concave", param = "concave",    field = "concave"    },
      { icon = "rotor",   param = "rotor",      field = "rotor"      } },
    { { icon = "fan",     param = "fan",        field = "fan"        },
      { icon = "chaffer", param = "upperSieve", field = "upperSieve" },
      { icon = "sieve",   param = "lowerSieve", field = "lowerSieve" } },
}

-- EN: Published so the tests can check every name above actually resolves. These three tables
--     address LAYOUT, the telemetry table, GAUGE_SPECS and the icon registry BY STRING, which
--     buys the indirection the live editor needs but converts a typo from a load error into a
--     silently missing element at 60 Hz. The locals stay for the draw path; these are aliases,
--     not copies, so they cannot drift.
-- UA: Публікуємо для тестів: ці таблиці адресують LAYOUT, телеметрію, GAUGE_SPECS та іконки
--     РЯДКАМИ, тож помилка в назві не впаде під час завантаження, а тихо прибере елемент.
--     Локальні змінні лишаються для швидкого шляху малювання; це псевдоніми, не копії.
CornerPostHUD.COLUMNS      = COLUMNS
CornerPostHUD.GAUGES       = GAUGES
CornerPostHUD.SETTING_ROWS = SETTING_ROWS
CornerPostHUD.GAUGE_SPECS  = GAUGE_SPECS

local ZONES = {
    below = 4,   -- EN: segments 1-4 from the bottom
    green = 3,   -- EN: segments 5-7 — the marked band
    above = 4,   -- EN: segments 8-11
}

-- EN: First and last segment index (1-based, from the bottom) of the green band.
-- UA: Перший і останній індекс сегмента зеленої смуги (від низу).
local GREEN_FROM = ZONES.below + 1
local GREEN_TO   = ZONES.below + ZONES.green

-- EN: The zone table and the conditioner's segment count are set independently, so a mismatch
--     is possible and would silently misalign every marker on the panel. Check once at load
--     and say so loudly rather than letting it render subtly wrong.
-- UA: Кількість зон і сегментів задаються окремо — розбіжність тихо зсунула б усі позначки.
--     Перевіряємо один раз при завантаженні.
local ZONE_TOTAL = ZONES.below + ZONES.green + ZONES.above
if SignalConditioner and SignalConditioner.segments
   and SignalConditioner.segments ~= ZONE_TOTAL then
    Logging.warning(string.format(
        "[RHM] Corner post zones sum to %d but SignalConditioner.segments is %d — " ..
        "the green marker band will not line up with the bar segments.",
        ZONE_TOTAL, SignalConditioner.segments))
end

local COLORS = {
    -- EN: John Deere tan/beige surround, as on the real post housing.
    bezel      = { 0.78, 0.68, 0.45, 1.00 },
    -- EN: Crisp black display glass. The readouts sit directly on this with no fill of their
    --     own — a tinted field behind a number reads as a separate widget, which the real
    --     display does not have.
    panel      = { 0.00, 0.00, 0.00, 1.00 },
    segOff     = { 0.13, 0.15, 0.13, 1.00 },
    segGreen   = { 0.16, 0.90, 0.24, 1.00 },
    segAmber   = { 1.00, 0.74, 0.05, 1.00 },
    segRed     = { 1.00, 0.16, 0.10, 1.00 },
    digit      = { 0.96, 0.98, 1.00, 1.00 },  -- EN: white, as on the reference cab photo
    label      = { 0.62, 0.66, 0.62, 1.00 },
    iconOff    = { 0.22, 0.24, 0.22, 1.00 },
    iconOn     = { 0.85, 0.88, 0.85, 1.00 },
    armed      = { 1.00, 0.85, 0.10, 1.00 },
}

-- ============================================================================
function CornerPostHUD.new(modDirectory, settings)
    local self = setmetatable({}, CornerPostHUD)

    self.modDirectory = modDirectory
    self.settings     = settings

    -- EN: Panel height as a fraction of screen height. Large enough to read at a glance from
    --     across a desk, but not so large it crowds the field view.
    -- UA: Висота панелі як частка висоти екрана — читається з відстані, але не заступає поле.
    self.scale = 0.55

    -- EN: Screen position of the panel's TOP-LEFT corner.
    --     While anchorSide is set, posX is recomputed from that edge on every layout change,
    --     so the panel stays pinned as the scale changes rather than drifting and needing to
    --     be re-dragged. Dragging clears the anchor and hands control back to the user — an
    --     explicit reposition should stick.
    --
    --     LEFT is the default: the game's own vehicle menus and the mod's settings dialog open
    --     on the right, and a panel that sits under them cannot be read while the settings it
    --     reports are being changed — which is the exact moment a trainee most needs it.
    -- UA: Позиція верхнього-лівого кута. Поки задано anchorSide, posX перераховується від того
    --     краю при зміні масштабу. Перетягування скидає прив'язку — явне переміщення
    --     зберігається. Ліворуч за замовчуванням: меню машини й діалог налаштувань
    --     відкриваються праворуч і перекривали б панель саме тоді, коли вона найпотрібніша.
    self.anchorSide  = "left"     -- EN: "left", "right", or nil for a free-dragged position
    self.edgeMargin  = 0.012
    self.posX = self.edgeMargin
    self.posY = 0.94

    self.dragging   = false
    self.dragDX     = 0
    self.dragDY     = 0

    self.overlay = nil

    return self
end

-- EN: Re-pins the panel to its anchored edge. Called after anything that changes its width —
--     load, scale change — so the gap to the screen edge stays constant instead of the panel
--     appearing to slide as it resizes. A nil anchor means the user placed it by hand and it
--     is left exactly where they put it.
-- UA: Притискає панель до заданого краю після будь-якої зміни ширини, щоб відступ лишався
--     сталим. nil означає ручне розміщення — його не чіпаємо.
function CornerPostHUD:applyAnchor()
    if self.anchorSide == "left" then
        self.posX = self.edgeMargin
    elseif self.anchorSide == "right" then
        self.posX = 1.0 - self:panelWidthNorm() - self.edgeMargin
    end
end

function CornerPostHUD:load()
    -- EN: Same 1x1 white texture the other HUD uses; setColor tints it to anything.
    --     One overlay, reused for every quad — the draw path allocates nothing per frame.
    -- UA: Та сама біла текстура 1x1; один оверлей перевикористовується для кожного
    --     прямокутника — шлях малювання не виділяє пам'ять щокадру.
    local whiteTex = self.modDirectory .. "textures/overlay_base.dds"
    self.overlay = Overlay.new(whiteTex, 0, 0, 0, 0)

    self:loadIcons()

    -- EN: Aspect ratio is only reliable once the mission is loaded, so pin to the right edge
    --     here rather than in the constructor.
    -- UA: Співвідношення сторін надійне лише після завантаження місії — притискаємо тут.
    self:applyAnchor()
end

function CornerPostHUD:delete()
    if self.overlay then
        self.overlay:delete()
        self.overlay = nil
    end
    if self.icons then
        for _, ov in pairs(self.icons) do ov:delete() end
        self.icons = nil
    end
end

-- ============================================================================
-- EN: Panel units -> screen space.
--     FS25 screen space is 0..1 with y increasing UPWARD, while the layout table is authored
--     with y increasing DOWNWARD from the panel's top edge (how you read a reference image).
--     The x scale also divides by the screen aspect so a cell authored square stays square
--     on any monitor instead of stretching on ultrawide.
-- UA: Одиниці панелі -> екран. У FS25 y росте ВГОРУ, а розмітка авторована згори-вниз.
--     Масштаб x ділиться на співвідношення сторін, щоб квадрат лишався квадратом.
-- ============================================================================
function CornerPostHUD:panelHeightNorm()
    return self.scale
end

function CornerPostHUD:panelWidthNorm()
    local aspect = g_screenAspectRatio or 1.7777
    return self.scale * (PANEL_W / PANEL_H) / aspect
end

function CornerPostHUD:toScreen(u, v)
    local w = self:panelWidthNorm()
    local h = self:panelHeightNorm()
    return self.posX + (u / PANEL_W) * w,
           self.posY - (v / PANEL_H) * h
end

function CornerPostHUD:toScreenSize(uw, vh)
    local w = self:panelWidthNorm()
    local h = self:panelHeightNorm()
    return (uw / PANEL_W) * w, (vh / PANEL_H) * h
end

-- EN: Draws one filled rectangle given panel-unit coordinates. The single primitive
--     everything else is built from.
-- UA: Малює один прямокутник в одиницях панелі — базовий примітив для всього іншого.
function CornerPostHUD:rect(u, v, uw, vh, c, alphaMul)
    if not self.overlay then return end

    local x, y  = self:toScreen(u, v + vh)   -- EN: +vh because y is flipped; anchor bottom-left
    local w, hh = self:toScreenSize(uw, vh)

    self.overlay:setPosition(x, y)
    self.overlay:setDimension(w, hh)
    self.overlay:setColor(c[1], c[2], c[3], (c[4] or 1) * (alphaMul or 1))
    self.overlay:render()
end

-- ============================================================================
-- EN: Vertical segmented bar column.
--     lit    — how many segments are illuminated, from the bottom up
--     total  — total segment count
--     armed  — draws the instructor's selection marker beside the column
--     Colour is decided PER SEGMENT by its position in the column, not by the overall value,
--     so the red and amber zones stay physically fixed the way LEDs on a real panel are.
--     A bar reading into the red therefore looks the same whether it climbed there or was
--     placed there, which is what makes the display readable at a glance.
-- UA: Вертикальна сегментна колонка. Колір визначається ПОЗИЦІЄЮ сегмента, а не загальним
--     значенням — червона й бурштинова зони фізично закріплені, як світлодіоди на панелі.
-- ============================================================================
function CornerPostHUD:drawBarColumn(u, v, uw, vh, lit, total, active)
    total = math.max(1, total)

    local cellH = vh / total
    local pad   = cellH * 0.16

    for i = 1, total do
        -- EN: i counts from the BOTTOM, matching how ZONES is defined, so the colour bands
        --     land on exactly the same rows as the green marker band on the threshold strips.
        -- UA: i рахується ЗНИЗУ, як і ZONES — кольорові смуги збігаються рядок у рядок
        --     із зеленою позначкою на порогових стрічках.
        local isLit = i <= lit

        -- EN: The bar itself is plain WHITE. All colour lives on the guide strip beside it.
        --     Same principle as the fuel and DEF gauges: a fixed colour reference that does
        --     not move, and a neutral bar that does. Colouring the bar too would mean the
        --     reading and the scale both change at once, which is harder to read at a glance
        --     and is not what the machine does.
        -- UA: Смуга — просто БІЛА; увесь колір на напрямній поруч. Той самий принцип, що й
        --     у датчиків пального і DEF: нерухома кольорова шкала і нейтральна рухома смуга.
        self:rect(u, v + vh - i * cellH, uw, cellH - pad,
            isLit and COLORS.iconOn or COLORS.segOff)
    end

    -- EN: Activity marker — a bright bar under any column being moved right now. With every
    --     channel on its own key pair there is no selection to indicate, so this serves a
    --     different purpose: it confirms the keypress registered, and lets anyone watching
    --     see which columns the instructor is driving. Two can light at once, which is the
    --     visible sign that simultaneous two-finger control is working.
    -- UA: Позначка активності — яскрава смуга під колонкою, яку зараз рухають. Підтверджує
    --     натискання і показує, які колонки веде інструктор. Дві можуть світитись одночасно.
    if active then
        self:rect(u - 1, v + vh + 1.5, uw + 2, 1.6, COLORS.armed)
    end
end

-- ============================================================================
-- EN: Numeric readout.
--     PLACEHOLDER: uses the default game font. The real LCD look needs a bitmap digit atlas
--     (0-9 . -) on a uniform grid; when that exists this function swaps to blitting cells and
--     nothing else changes. Digits are right-aligned within the field, as on the machine.
-- UA: Числовий показник. ТИМЧАСОВО використовує стандартний шрифт; справжній LCD-вигляд
--     потребує растрового атласу цифр. Вирівнювання праворуч, як на машині.
-- ============================================================================
function CornerPostHUD:drawNumber(spec, value, fmt)
    -- EN: No field fill. The readouts sit straight on the panel, which is already the same
    --     pure black — painting it again was three invisible rectangles every frame.
    -- UA: Без заливки поля: показники лежать просто на панелі того ж чорного кольору.
    --
    -- EN: nil off-colour means dormant segments are not drawn at all.
    local text = string.format(fmt or "%.0f", value or 0)
    self:drawSevenSegNumber(spec, text, COLORS.digit, nil)

    if spec.label then
        local x, y = self:toScreen(spec.x + spec.w, spec.y + spec.h)
        local _, h = self:toScreenSize(spec.w, spec.h)
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(COLORS.label[1], COLORS.label[2], COLORS.label[3], COLORS.label[4])
        renderText(x + 0.003, y + h * 0.10, h * 0.34, spec.label)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
end

-- EN: Icon registry. Every glyph on the panel is an ordinary 128x128 DDS in textures/, so
--     replacing one is dropping a new file over it — no code change, no atlas coordinates.
--     Keys here are logical roles, not filenames, so swapping which file a role uses is a
--     one-line edit rather than a hunt through the draw code.
-- UA: Реєстр іконок. Кожен гліф — звичайний DDS 128x128 у textures/, тож заміна — це просто
--     новий файл поверх старого. Ключі тут — ролі, а не імена файлів.
CornerPostHUD.ICON_FILES = {
    -- loss columns
    shoe     = "icon_cln",        -- EN: cleaning shoe loss  (user-supplied)
    sep      = "icon_sep",        -- EN: separator/rotor loss (user-supplied)
    total    = "icon_total",      -- EN: sigma with converging feeds (generated placeholder)
    tailings = "icon_tailings",   -- EN: inclined auger      (generated placeholder)

    -- gauges
    load     = "icon_load",       -- EN: engine load         (user-supplied)
    coolant  = "icon_coolant",    -- EN: thermometer         (generated placeholder)
    fuel     = "icon_fuel",       -- EN: fuel pump           (generated placeholder)
    def      = "icon_def",        -- EN: DEF droplet         (generated placeholder)

    -- machine settings row
    chaffer  = "icon_sieve_upper",
    sieve    = "icon_sieve_lower",
    fan      = "icon_fan",
    rotor    = "icon_rotor",
    concave  = "icon_concave",
    moisture = "icon_moisture",
}

-- EN: Loads every registered icon once into a reusable Overlay. Missing files are reported
--     individually and skipped rather than left to fail silently at draw time, where a nil
--     overlay would throw inside the draw callback and take the whole panel down.
-- UA: Завантажує кожну іконку один раз. Відсутні файли повідомляються і пропускаються —
--     інакше nil у шляху малювання завалив би всю панель.
function CornerPostHUD:loadIcons()
    self.icons = {}
    local missing = {}

    for role, file in pairs(CornerPostHUD.ICON_FILES) do
        local path = self.modDirectory .. "textures/" .. file .. ".dds"
        if fileExists(path) then
            self.icons[role] = Overlay.new(path, 0, 0, 0, 0)
        else
            table.insert(missing, string.format("%s (%s.dds)", role, file))
        end
    end

    if #missing > 0 then
        table.sort(missing)
        Logging.warning("[RHM] Corner post icons not found, those slots will be blank: "
            .. table.concat(missing, ", "))
    end
end

-- EN: Draws a registered icon. Silently skips an unloaded role — a missing texture should
--     leave a gap, never abort the frame.
-- UA: Малює зареєстровану іконку; відсутня роль просто пропускається.
function CornerPostHUD:drawIcon(role, u, v, uw, vh, colour)
    local ov = self.icons and self.icons[role]
    if not ov then return end

    local c = colour or COLORS.iconOn
    local x, y  = self:toScreen(u, v + vh)
    local w, hh = self:toScreenSize(uw, vh)

    ov:setPosition(x, y)
    ov:setDimension(w, hh)
    ov:setColor(c[1], c[2], c[3], c[4] or 1)
    ov:render()
end

-- EN: Setting value with NO unit suffix, but with the same decimal places the calibration
--     GUI uses — the two must never disagree about whether a setting has a fraction.
--     Deliberately not a change to UnitConverter.formatSetting: that function is correct for
--     the GUI, where there is room for the unit and the label is far from the number. This is
--     the same value formatted for a five-across strip where the unit will not fit.
-- UA: Значення налаштування БЕЗ суфікса одиниць, але з тією ж кількістю десяткових знаків,
--     що й у GUI калібрування. UnitConverter.formatSetting навмисно не змінюється — там
--     суфікс доречний, тут для нього немає місця.
function CornerPostHUD:formatBareSetting(param, value, machineType)
    local v = value or 0

    local conv = RHM_UnitConverter or UnitConverter
    local range = conv and conv.getPhysicalRange
        and conv.getPhysicalRange(param, machineType)

    if range and range.decimals and range.decimals > 0 then
        return string.format("%." .. range.decimals .. "f", v)
    end
    return string.format("%d", math.floor(v + 0.5))
end

-- ============================================================================
-- EN: SEVEN-SEGMENT DIGITS
--     Drawn from rectangles rather than typed with the game font, because no font available
--     here has the segmented look, and the segmented look is most of what makes a readout
--     read as instrument rather than as UI text — the alarm-clock character.
--
--     Segment naming, conventional:
--            aaa
--           f   b
--            ggg
--           e   c
--            ddd
--
--     Unlit segments are NOT drawn. The reference cab photo is an emissive LCD read in
--     daylight: only the lit elements are visible, and the dormant ones vanish into the
--     glass. Ghosting them grey is what a cheap alarm clock does, not what this display does.
--
--     Segment ends are MITRED — each element is a hexagon whose ends taper to a point, so
--     adjacent elements meet at a 45-degree corner instead of butting square. That taper is
--     the single detail that separates a real instrument glyph from stacked rectangles.
-- UA: СЕМИСЕГМЕНТНІ ЦИФРИ з прямокутників, а не шрифтом: жоден доступний шрифт не має
--     сегментного вигляду, а саме він робить показник приладом, а не текстом інтерфейсу.
--     Незасвічені сегменти НЕ малюються — на фото з кабіни видно лише засвічені елементи.
--     Кінці сегментів скошені під 45°, як на справжньому індикаторі.
-- ============================================================================
local SEG_MAP = {
    ["0"] = { a=1,b=1,c=1,d=1,e=1,f=1,g=0 },
    ["1"] = { a=0,b=1,c=1,d=0,e=0,f=0,g=0 },
    ["2"] = { a=1,b=1,c=0,d=1,e=1,f=0,g=1 },
    ["3"] = { a=1,b=1,c=1,d=1,e=0,f=0,g=1 },
    ["4"] = { a=0,b=1,c=1,d=0,e=0,f=1,g=1 },
    ["5"] = { a=1,b=0,c=1,d=1,e=0,f=1,g=1 },
    ["6"] = { a=1,b=0,c=1,d=1,e=1,f=1,g=1 },
    ["7"] = { a=1,b=1,c=1,d=0,e=0,f=0,g=0 },
    ["8"] = { a=1,b=1,c=1,d=1,e=1,f=1,g=1 },
    ["9"] = { a=1,b=1,c=1,d=1,e=0,f=1,g=1 },
    ["-"] = { a=0,b=0,c=0,d=0,e=0,f=0,g=1 },
    [" "] = { a=0,b=0,c=0,d=0,e=0,f=0,g=0 },
}

-- EN: Draws one seven-segment glyph in the given cell.
-- UA: Малює один семисегментний символ у заданій комірці.
-- EN: Slices used to fake each mitred end. Every step is 2 more rectangles per segment and
--     these numbers redraw every frame, so this is a real cost: at 2 steps a full "8" is 35
--     rectangles, at 3 it is 49. The bevel is only about a third of a segment thickness on
--     screen — roughly two pixels — so a third step would be sub-pixel and buys nothing.
-- UA: Зрізи для імітації скосу. Кожен крок — це ще 2 прямокутники на сегмент, а числа
--     перемальовуються щокадру. Скіс займає близько двох пікселів, тож третій крок був би
--     субпіксельним і нічого не дав би.
local MITRE_STEPS = 2

function CornerPostHUD:drawSevenSeg(ch, x, y, w, h, onC, offC)
    local m = SEG_MAP[ch]
    if not m then return end

    local t    = h * 0.155         -- EN: segment thickness — heavier than before, as on the photo
    local midY = y + h * 0.5 - t * 0.5

    -- EN: One element, tapering to a point at both ends. `horiz` picks which axis the taper
    --     runs along; the body is a full-thickness rectangle and the two ends are stepped
    --     wedges. Skipped entirely when unlit and no off-colour was supplied.
    -- UA: Один елемент зі скошеними кінцями. Тіло — прямокутник, кінці — сходинки-клини.
    local function seg(on, sx, sy, sw, sh, horiz)
        local c = (on == 1) and onC or offC
        if c == nil then return end

        local thick = horiz and sh or sw
        local long  = horiz and sw or sh
        local bev   = math.min(thick * 0.5, long * 0.45)
        local slice = bev / MITRE_STEPS

        if horiz then
            self:rect(sx + bev, sy, sw - bev * 2, sh, c)
        else
            self:rect(sx, sy + bev, sw, sh - bev * 2, c)
        end

        for k = 0, MITRE_STEPS - 1 do
            -- EN: Wedge width at this step: full thickness at the body, tapering to a sliver.
            local frac = (k + 0.5) / MITRE_STEPS
            local ext  = thick * frac
            local off  = (thick - ext) * 0.5
            if horiz then
                self:rect(sx + bev - (k + 1) * slice, sy + off, slice, ext, c)
                self:rect(sx + sw - bev + k * slice,  sy + off, slice, ext, c)
            else
                self:rect(sx + off, sy + bev - (k + 1) * slice, ext, slice, c)
                self:rect(sx + off, sy + sh - bev + k * slice,  ext, slice, c)
            end
        end
    end

    -- EN: Elements span the full cell and interlock at the mitres, so there is no explicit
    --     gap term any more — the 45-degree cuts create the separation themselves.
    -- UA: Елементи займають усю комірку і стикуються скосами; окремий зазор більше не потрібен.
    seg(m.a, x,         y,          w, t,                    true)   -- top
    seg(m.g, x,         midY,       w, t,                    true)   -- middle
    seg(m.d, x,         y + h - t,  w, t,                    true)   -- bottom
    seg(m.f, x,         y,          t, (midY + t) - y,       false)  -- upper left
    seg(m.b, x + w - t, y,          t, (midY + t) - y,       false)  -- upper right
    seg(m.e, x,         midY,       t, (y + h) - midY,       false)  -- lower left
    seg(m.c, x + w - t, midY,       t, (y + h) - midY,       false)  -- lower right
end

-- EN: Renders a right-aligned seven-segment number inside a field.
--     The decimal point is drawn as a square between digits and consumes about a third of a
--     cell, so "0.0" occupies noticeably less than three full digits — same as real hardware.
-- UA: Виводить число семисегментним шрифтом з вирівнюванням праворуч. Десяткова крапка —
--     квадрат між цифрами, займає близько третини комірки, як на реальному приладі.
function CornerPostHUD:drawSevenSegNumber(spec, text, onC, offC)
    local chars = {}
    for i = 1, #text do chars[#chars + 1] = text:sub(i, i) end

    -- EN: Width budget: a dot costs a third of a digit cell.
    local units = 0
    for _, c in ipairs(chars) do units = units + (c == "." and 0.34 or 1) end
    if units <= 0 then return end

    -- EN: Digits are sized to the SMALLER of the width and height budgets, so a long value
    --     cannot spill past the field and a short one cannot balloon. digHFactor sets the
    --     height share; the aspect cap keeps a glyph roughly 0.62 as wide as it is tall,
    --     which is the proportion a real seven-segment element has.
    -- UA: Цифри масштабуються за меншим із обмежень ширини й висоти: довге значення не
    --     вилізе за поле, коротке не роздується. Пропорція ~0.62 — як у реального індикатора.
    local padX   = spec.w * 0.05
    local availW = spec.w - padX * 2
    local cellW  = availW / units
    local digH   = math.min(spec.h * 0.62, cellW / 0.62)
    local digW   = digH * 0.62
    local yTop   = spec.y + (spec.h - digH) * 0.5

    -- EN: Re-centre horizontally once the glyph size is known, so the number sits in the
    --     middle of its field rather than being left-anchored with a ragged right edge.
    -- UA: Перецентровуємо по горизонталі після визначення розміру гліфа.
    local usedW  = 0
    for _, c in ipairs(chars) do usedW = usedW + (c == "." and digW * 0.42 or digW * 1.22) end

    local cx = spec.x + (spec.w - usedW) * 0.5
    for _, c in ipairs(chars) do
        if c == "." then
            self:rect(cx + digW * 0.10, yTop + digH - digH * 0.15,
                      digH * 0.15, digH * 0.15, onC)
            cx = cx + digW * 0.42
        else
            self:drawSevenSeg(c, cx, yTop, digW, digH, onC, offC)
            cx = cx + digW * 1.22
        end
    end
end

-- ============================================================================
-- EN: Vertical level gauge — fuel, DEF, engine load.
--
--     Two parts, and the distinction matters: a FIXED colour scale on the left, and a white
--     level bar beside it that grows and shrinks. The reading is taken by seeing where the
--     top of the white bar lands against the colours. The colours never move.
--
--     This is deliberately NOT how the loss columns work. There, the segments themselves are
--     coloured, because the question is "what zone is the reading in". Here the question is
--     "how much is left", and a fixed scale answers it at a glance without the eye having to
--     re-learn the colour boundaries every time the value changes.
--
--     redAtTop = true  → high values are bad (engine load)
--     redAtTop = false → low values are bad (fuel, DEF)
-- UA: Вертикальний датчик рівня — пальне, DEF, навантаження.
--     Дві частини: НЕРУХОМА кольорова шкала ліворуч і біла смуга рівня поруч, яка росте і
--     спадає. Показ читається за положенням верху білої смуги відносно кольорів.
--     Це навмисно НЕ так, як у колонках втрат: там питання "у якій зоні", тут — "скільки
--     лишилось", і нерухома шкала відповідає на нього миттєво.
-- ============================================================================
function CornerPostHUD:drawGauge(g, value, spec)
    if not spec then return end

    local maxV = spec.max
    local v    = math.max(0, math.min(maxV, value or 0))

    -- EN: Split the footprint: narrow colour scale, gap, wider level bar.
    -- UA: Ділимо площу: вузька кольорова шкала, проміжок, ширша смуга рівня.
    local scaleW = g.w * 0.30
    local gap    = g.w * 0.10
    local barX   = g.x + scaleW + gap
    local barW   = g.w - scaleW - gap

    -- ---- Fixed colour scale -------------------------------------------------
    -- EN: Zones are listed low-to-high by threshold. Each band's height is its share of the
    --     scale, and it is drawn from the BOTTOM up, so the same declaration works whether
    --     red sits at the top (engine load) or the bottom (fuel, DEF) — the order of the
    --     list decides, not a flag. One less thing to get inconsistent.
    -- UA: Зони перелічені знизу вгору за порогами; висота смуги — її частка шкали.
    --     Порядок списку визначає, де червоний — прапорець не потрібен.
    local prev = 0
    for _, z in ipairs(spec.zones) do
        local frac  = (z.upto - prev) / maxV
        local bandH = g.h * frac
        local bandY = g.y + g.h - (z.upto / maxV) * g.h
        self:rect(g.x, bandY, scaleW, bandH, COLORS[z.color] or COLORS.segOff)
        prev = z.upto
    end

    -- ---- Level bar ----------------------------------------------------------
    -- EN: Segmented, not a solid fill — same cell treatment as the loss columns, so every
    --     bar on the panel is read the same way. Uses the same segment count too, which
    --     means a gauge cell and a loss cell are the same height and the panel scans as one
    --     instrument rather than two unrelated ones.
    -- UA: Сегментована, а не суцільна — той самий вигляд, що й у колонок втрат, і та сама
    --     кількість сегментів, тож панель читається як один прилад.
    local segs  = (SignalConditioner and SignalConditioner.segments) or 11
    local lit   = math.floor((v / maxV) * segs + 0.5)
    local cellH = g.h / segs
    local pad   = cellH * 0.16

    for i = 1, segs do
        self:rect(barX, g.y + g.h - i * cellH, barW, cellH - pad,
            (i <= lit) and COLORS.iconOn or COLORS.segOff)
    end
end

-- ============================================================================
-- EN: Main draw.
-- UA: Головне малювання.
-- ============================================================================
function CornerPostHUD:draw()
    if not self.overlay then return end
    if not TelemetryProvider then return end

    local d = TelemetryProvider.get()
    local segTotal = (SignalConditioner and SignalConditioner.segments) or 14

    -- ---- Shell -------------------------------------------------------------
    self:rect(0, 0, PANEL_W, PANEL_H, COLORS.bezel)
    self:rect(LAYOUT.upper.x, LAYOUT.upper.y, LAYOUT.upper.w, LAYOUT.upper.h, COLORS.panel)
    self:rect(LAYOUT.lower.x, LAYOUT.lower.y, LAYOUT.lower.w, LAYOUT.lower.h, COLORS.panel)

    -- ---- Loss columns: SHOE | TOTAL | SEP ... TAIL ---------------------------
    -- EN: Each column has explicit geometry rather than a uniform stride, because on the real
    --     panel they are not equal: TOTAL is about twice the width of the two components it
    --     sums. That width difference is what gives the headline number its visual weight.
    -- UA: Кожна колонка має власну геометрію, а не однаковий крок: TOTAL приблизно вдвічі
    --     ширший за складові — саме це надає головному показнику ваги.
    for _, col in ipairs(TrainingMode.BAR_LAYOUT) do
        local c = COLUMNS[col.key]
        local g = c and LAYOUT[c.geom]
        if g then
            local isActive = (not col.derived)
                and TrainingMode.isChannelActive
                and TrainingMode.isChannelActive(col.key)

            self:drawBarColumn(g.x, g.y, g.w, g.h, d[c.seg] or 0, segTotal, isActive)

            -- EN: Icon above the column instead of a text caption. Text at this column
            --     width collided; a shape does not, and matches the real panel besides.
            -- UA: Іконка над колонкою замість підпису — текст на цій ширині накладався.
            local bi = LAYOUT.barIcons
            local iconW = math.min(g.w * 0.7, bi.h * 1.2)
            self:drawIcon(c.icon, g.x + (g.w - iconW) * 0.5, bi.y, iconW, bi.h, COLORS.iconOn)
        end
    end

    -- ---- Feed arrows: SHOE and SEP converge into TOTAL ----------------------
    -- EN: Two brackets running inward from the outer columns and turning down into TOTAL,
    --     as on the reference panel. Worth drawing rather than leaving implicit: it is the
    --     one thing on the page that states TOTAL is not a third sensor but the other two
    --     combined, which is exactly the relationship an operator has to understand to read
    --     the display correctly.
    -- UA: Дві дужки, що йдуть від крайніх колонок усередину і повертають униз до TOTAL,
    --     як на референсній панелі. Це єдине на сторінці, що показує: TOTAL — не третій
    --     датчик, а поєднання двох інших.
    do
        local shoe, tot, sep = LAYOUT.colShoe, LAYOUT.colTotal, LAYOUT.colSep
        local bi = LAYOUT.barIcons
        local t  = 0.9                                   -- EN: line thickness
        local y  = bi.y + bi.h + 1.5                     -- EN: bracket runs under the icons
        local drop = (shoe.y - y) * 0.55                 -- EN: how far the turn-down reaches

        local shoeCx = shoe.x + shoe.w * 0.5
        local totCx  = tot.x  + tot.w  * 0.5
        local sepCx  = sep.x  + sep.w  * 0.5

        -- horizontal runs inward
        self:rect(shoeCx, y, totCx - shoeCx, t, COLORS.iconOff)
        self:rect(totCx,  y, sepCx - totCx,  t, COLORS.iconOff)
        -- risers at the outer columns
        self:rect(shoeCx, y, t, drop * 0.5, COLORS.iconOff)
        self:rect(sepCx,  y, t, drop * 0.5, COLORS.iconOff)
        -- the shared drop into TOTAL, with an arrowhead
        self:rect(totCx - t * 0.5, y, t, drop, COLORS.iconOff)
        local ah = 1.6
        self:rect(totCx - ah, y + drop,           ah * 2, t,       COLORS.iconOff)
        self:rect(totCx - ah * 0.5, y + drop + t, ah,     t * 1.2, COLORS.iconOff)
    end

    -- ---- Threshold marker strips flanking TOTAL ------------------------------
    -- EN: Orange strips carrying a green setpoint band, drawn as part of the bar assembly
    --     because that is what they are on the machine — the alarm level, not decoration.
    --     The green band sits at the setpoint; the orange is the strip it rides in.
    -- UA: Помаранчеві смуги із зеленою позначкою уставки — частина збірки смуг, а не декор.
    for _, mk in ipairs({ LAYOUT.markerL, LAYOUT.markerR }) do
        -- EN: The guide strip carries ALL the colour: amber outside the target band, green
        --     inside it. Built cell by cell from the SAME segTotal the bars use, so every
        --     colour boundary lands exactly on a bar segment boundary rather than floating
        --     at a fractional height.
        -- UA: Напрямна несе УВЕСЬ колір: бурштиновий поза цільовою смугою, зелений усередині.
        --     Будується по комірках із того ж segTotal, що й смуги — межі кольорів точно
        --     збігаються з межами сегментів.
        local cellH = mk.h / segTotal
        for i = 1, segTotal do
            local inBand = (i >= GREEN_FROM and i <= GREEN_TO)
            self:rect(mk.x, mk.y + mk.h - i * cellH, mk.w, cellH,
                inBand and COLORS.segGreen or COLORS.segAmber)
        end
    end

    -- EN: TOTAL is identified by the icon_total glyph in the column icon row above, alongside
    --     the other three. The hand-drawn sigma that used to sit here rendered as a bare
    --     character in the game font at a size where it read as noise rather than as a symbol,
    --     and it sat apart from the icons it belonged with.
    -- UA: TOTAL позначається гліфом icon_total у рядку іконок над колонками, разом з іншими.
    --     Попередня сигма малювалась ігровим шрифтом і на цьому розмірі читалась як шум.

    -- ---- Upper panel: machine state ----------------------------------------
    self:drawNumber(LAYOUT.rpm, d.engineRpm or 0, "%.0f")

    -- EN: The reference post is a North American machine, so speed reads in MPH regardless
    --     of the game's unit setting — matching the display beats matching the options menu.
    -- UA: Референсна машина північноамериканська, тому швидкість у MPH незалежно від
    --     налаштувань гри — відповідність дисплею важливіша за відповідність меню.
    local mph = (d.speedKmh or 0) * 0.621371
    self:drawNumber(LAYOUT.speed, mph, "%.1f")

    -- EN: The four gauges. Each is passed its RAW value and its spec; the spec owns the
    --     scale and where the colour boundaries sit, so no scaling happens at the call site.
    -- UA: Чотири датчики. Кожен отримує СИРЕ значення і специфікацію — масштаб і межі
    --     кольорів належать специфікації, тож тут нічого не масштабується.
    for _, gg in ipairs(GAUGES) do
        self:drawGauge(LAYOUT[gg.geom], d[gg.field] or 0, GAUGE_SPECS[gg.spec])
    end

    -- EN: Icon row identifying the four gauges. Placeholder cells until the glyphs exist.
    -- UA: Рядок іконок під датчиками — заглушки до появи гліфів.
    do
        -- EN: Each icon is centred on ITS OWN gauge rather than on an equal division of the
        --     row. Those two are not the same thing — the gauges are laid out on their own
        --     x positions, so dividing the strip into four equal cells put every icon a
        --     little off from the bar it labels. Deriving from the gauge geometry means they
        --     cannot drift apart when either is nudged.
        -- UA: Кожна іконка центрується на СВОЄМУ датчику, а не на рівній частині смуги —
        --     інакше підписи зміщені відносно стовпців, які вони позначають.
        local gi = LAYOUT.gaugeIcons
        for _, gg in ipairs(GAUGES) do
            local g = LAYOUT[gg.geom]
            local iconW = math.min(g.w * 0.85, gi.h * 1.25)
            self:drawIcon(gg.icon, g.x + (g.w - iconW) * 0.5, gi.y, iconW, gi.h, COLORS.iconOn)
        end
    end

    -- ---- Lower panel: the loss page ----------------------------------------
    self:drawNumber(LAYOUT.moisture, d.grainMoisture or 0, "%.1f")

    -- EN: Grain tank level, bottom-filling like the real indicator.
    --     Drawn with a fixed green ramp rather than the loss colour zones: a full tank is not
    --     an alarm condition, so reusing the red-at-the-top scheme here would say the opposite
    --     of what it means. Its setpoint dash sits alongside, as in the reference art.
    -- UA: Рівень бункера — без червоної зони: повний бункер не є аварією, і зворотна
    --     кольорова схема сказала б протилежне. Поруч — позначка уставки, як у референсі.
    local tk = LAYOUT.tankBar
    local tankLit = math.floor(((d.tankPct or 0) / 100) * segTotal + 0.5)
    do
        local cellH = tk.h / segTotal
        local pad   = cellH * 0.16
        for i = 1, segTotal do
            local c = (i <= tankLit) and COLORS.segGreen or COLORS.segOff
            self:rect(tk.x, tk.y + tk.h - i * cellH, tk.w, cellH - pad, c)
        end
    end
    local ti = LAYOUT.tankIcon
    self:drawIcon("moisture", ti.x, ti.y, ti.w, ti.h, COLORS.iconOn)

    -- ---- Machine settings row: icon over live value -------------------------
    -- EN: Five settings the operator actually adjusts, each an icon above its current value.
    --     This is the training half of the page: the student changes something and both
    --     people immediately see what it now reads, sitting directly above the loss columns
    --     those settings are moving. The decorative cross-section this replaced conveyed
    --     nothing that could change.
    --
    --     Values are shown in the units the operator thinks in, converted from the 0-100
    --     stored form — a percentage would be a number nobody sets a combine by.
    -- UA: П'ять налаштувань, які реально регулює оператор: іконка над поточним значенням.
    --     Це навчальна половина сторінки — студент щось змінює, і обидва одразу бачать нове
    --     значення просто над колонками втрат, на які воно впливає.
    --     Значення показані в одиницях оператора, а не у відсотках.
    do
        local sr = LAYOUT.settingsRow
        local mt = d.machineType or "grain"

        -- EN: 2 + 3 grid mirroring Deere's Harvest Settings page: the two threshing settings
        --     on top, the three cleaning settings below. Each cell is an icon beside a boxed
        --     value, which is how that page presents them — the box is what makes a number
        --     read as an adjustable setting rather than as a readout.
        --
        --     Settings are stored as PHYSICAL values already — there is no percent-to-physical
        --     conversion layer — so formatSetting() is asked for the string rather than any
        --     scaling being done here. Units and decimals come from the same range table the
        --     calibration GUI uses, so the two can never disagree.
        -- UA: Сітка 2 + 3 як на сторінці Harvest Settings: два налаштування обмолоту згори,
        --     три налаштування очистки знизу. Кожна комірка — іконка поруч із значенням у
        --     рамці; саме рамка робить число регульованим налаштуванням, а не показником.
        local rowH = sr.h / #SETTING_ROWS
        for ri, row in ipairs(SETTING_ROWS) do
            local cellW = sr.w / #row
            local ry    = sr.y + (ri - 1) * rowH

            for ci, c in ipairs(row) do
                local cx = sr.x + (ci - 1) * cellW

                -- EN: Icon on the left of the cell, bare value to its right. No box and no
                --     unit suffix: with five cells across 80 units, "1100RPM" simply does not
                --     fit, and the suffix is the part carrying no information — the icon
                --     already says which setting this is, and an operator knows the concave is
                --     in millimetres and the rotor in rev/min without being told every frame.
                -- UA: Іконка ліворуч, голе значення праворуч. Без рамки й без суфікса одиниць:
                --     "1100RPM" не вміщається у комірку, а суфікс не несе інформації — іконка
                --     вже каже, яке це налаштування.
                local iconH = rowH * 0.68
                local iconW = math.min(cellW * 0.24, iconH)
                self:drawIcon(c.icon, cx, ry + (rowH - iconH) * 0.5,
                    iconW, iconH, COLORS.iconOn)

                local text = "--"
                local v = d[c.field]
                if v then
                    text = self:formatBareSetting(c.param, v, mt)
                end

                local valX = cx + iconW + cellW * 0.04
                local valW = cellW - (valX - cx) - cellW * 0.04
                local tx, ty  = self:toScreen(valX, ry + rowH * 0.5 + rowH * 0.30)
                local sw, _   = self:toScreenSize(valW, rowH)
                local _, rowPx = self:toScreenSize(cellW, rowH)

                -- EN: Shrink to fit rather than overflow. The previous row overran its cells
                --     and painted over the icon of the neighbour, which is why the block
                --     looked broken; a value that will not fit is made smaller, never clipped.
                -- UA: Зменшуємо розмір, а не обрізаємо: попередній варіант налазив на сусідню
                --     іконку. Значення, що не вміщається, стає меншим.
                local size = rowPx * 0.52
                if getTextWidth ~= nil then
                    local tw = getTextWidth(size, text)
                    if tw > sw and tw > 0 then size = size * (sw / tw) end
                end

                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(COLORS.digit[1], COLORS.digit[2], COLORS.digit[3], 1)
                renderText(tx, ty, size, text)
            end
        end
    end

    -- EN: Restore global text state. renderText settings persist across the whole frame, so
    --     leaking bold, colour or alignment here would corrupt every later draw including
    --     the game's own UI.
    -- UA: Відновлюємо глобальний стан тексту — інакше зіпсуємо весь подальший рендер кадру.
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- ============================================================================
-- EN: Dragging and scaling.
-- UA: Перетягування та масштабування.
-- ============================================================================
function CornerPostHUD:isOver(x, y)
    local w = self:panelWidthNorm()
    local h = self:panelHeightNorm()
    return x >= self.posX and x <= self.posX + w
       and y <= self.posY and y >= self.posY - h
end

function CornerPostHUD:mouseEvent(posX, posY, isDown, isUp, button)
    if not (g_realisticHarvestManager and g_realisticHarvestManager.isCursorVisible) then
        return false
    end

    if isDown and button == 1 and self:isOver(posX, posY) then
        self.dragging = true
        -- EN: An explicit drag overrides the edge anchor; the user's placement wins.
        -- UA: Явне перетягування скасовує прив'язку до краю.
        self.anchorSide = nil
        self.dragDX = posX - self.posX
        self.dragDY = posY - self.posY
        return true
    end

    if isUp and button == 1 and self.dragging then
        self.dragging = false
        return true
    end

    if self.dragging then
        self.posX = posX - self.dragDX
        self.posY = posY - self.dragDY
        return true
    end

    return false
end

function CornerPostHUD:setScale(s)
    self.scale = math.max(0.20, math.min(1.30, s))
    self:applyAnchor()
    return self.scale
end

-- EN: Pins the panel to an edge, or frees it. Also the recovery route after a drag has left
--     it somewhere unhelpful — "free" keeps it where it is, an edge snaps it back.
-- UA: Притискає панель до краю або звільняє її. Також спосіб відновлення після перетягування.
function CornerPostHUD:setAnchorSide(side)
    if side == "left" or side == "right" then
        self.anchorSide = side
    else
        self.anchorSide = nil
    end
    self:applyAnchor()
    return self.anchorSide
end

-- EN: Console: rhmPostSide left|right|free
-- UA: Консоль: rhmPostSide left|right|free
function CornerPostHUD:consoleSide(side)
    if side == nil or side == "" then
        return string.format("Corner post is anchored: %s (x = %.3f). Usage: rhmPostSide left|right|free",
            tostring(self.anchorSide or "free"), self.posX)
    end

    local s = tostring(side):lower()
    if s ~= "left" and s ~= "right" and s ~= "free" then
        return "Usage: rhmPostSide left|right|free"
    end

    self:setAnchorSide(s)
    return string.format("Corner post anchored %s (x = %.3f)",
        tostring(self.anchorSide or "free"), self.posX)
end

-- ============================================================================
-- EN: LIVE LAYOUT EDITOR
--     Positioning a panel by editing constants, restarting the game, looking, and repeating
--     is a miserable loop — and it is the reason getting a layout to match a reference is so
--     painful. These commands mutate LAYOUT in place while the game runs, so an element can
--     be nudged into place by eye, and then dumped as a paste-ready table.
--
--     Nothing here is needed at runtime by the display; it exists purely to author the
--     layout. Values live only in memory until dumped and pasted back into the source, which
--     is deliberate — an accidental nudge should never silently become permanent.
--
--       rhmPostList                       what elements exist, and their current geometry
--       rhmPostSet   <elem> <x> <y> [w] [h]   absolute placement
--       rhmPostNudge <elem> <dx> <dy>     relative move (w/h unchanged)
--       rhmPostSize  <elem> <dw> <dh>     relative resize
--       rhmPostDump                       print a paste-ready LAYOUT table
--
-- UA: РЕДАКТОР РОЗМІТКИ НАЖИВО.
--     Правити константи, перезапускати гру, дивитись і повторювати — виснажливий цикл, і
--     саме через нього так важко підігнати розмітку під референс. Ці команди змінюють LAYOUT
--     під час гри, тож елемент можна поставити на око, а потім вивести готову таблицю.
--     Значення живуть лише в пам'яті до виводу — випадковий зсув не стане постійним.
-- ============================================================================

-- EN: Fields that are geometry rather than configuration. Only these are editable and dumped
--     as numbers; count/gap/digits/label are carried through untouched.
-- UA: Поля геометрії — лише вони редагуються; count/gap/digits/label переносяться без змін.
local GEOM_FIELDS = { "x", "y", "w", "h" }

local function sortedLayoutKeys()
    local keys = {}
    for k, v in pairs(CornerPostHUD.LAYOUT) do
        if type(v) == "table" then table.insert(keys, k) end
    end
    table.sort(keys)
    return keys
end

local function findElement(name)
    if not name then return nil end
    local want = tostring(name):lower()
    for _, k in ipairs(sortedLayoutKeys()) do
        if k:lower() == want then return k, CornerPostHUD.LAYOUT[k] end
    end
    return nil
end

function CornerPostHUD:consoleList()
    local out = { string.format("Corner post layout — canvas %d x %d, origin TOP-LEFT:", PANEL_W, PANEL_H) }
    for _, k in ipairs(sortedLayoutKeys()) do
        local e = CornerPostHUD.LAYOUT[k]
        table.insert(out, string.format("  %-12s x=%-6s y=%-6s w=%-6s h=%-6s",
            k, tostring(e.x or "-"), tostring(e.y or "-"),
            tostring(e.w or "-"), tostring(e.h or "-")))
    end
    table.insert(out, "  rhmPostSet/Nudge/Size <element> ...   then rhmPostDump")
    return table.concat(out, "\n")
end

function CornerPostHUD:consoleSet(name, x, y, w, h)
    local key, e = findElement(name)
    if not e then
        return "Unknown element. Try rhmPostList."
    end

    local applied = {}
    local vals = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
    for _, f in ipairs(GEOM_FIELDS) do
        if vals[f] ~= nil then
            e[f] = vals[f]
            table.insert(applied, string.format("%s=%.1f", f, vals[f]))
        end
    end

    if #applied == 0 then
        return string.format("Usage: rhmPostSet %s <x> <y> [w] [h]", key)
    end
    return string.format("%s  %s", key, table.concat(applied, " "))
end

function CornerPostHUD:consoleNudge(name, dx, dy)
    local key, e = findElement(name)
    if not e then return "Unknown element. Try rhmPostList." end

    local ddx, ddy = tonumber(dx) or 0, tonumber(dy) or 0
    if e.x then e.x = e.x + ddx end
    if e.y then e.y = e.y + ddy end
    return string.format("%s  x=%.1f y=%.1f", key, e.x or 0, e.y or 0)
end

function CornerPostHUD:consoleSize(name, dw, dh)
    local key, e = findElement(name)
    if not e then return "Unknown element. Try rhmPostList." end

    local ddw, ddh = tonumber(dw) or 0, tonumber(dh) or 0
    -- EN: Keep dimensions positive; a negative width silently renders nothing, which reads
    --     as "the element vanished" and wastes time to diagnose.
    -- UA: Тримаємо розміри додатними — від'ємна ширина малює порожнечу і виглядає як
    --     "елемент зник", що марно згаює час на діагностику.
    if e.w then e.w = math.max(0.5, e.w + ddw) end
    if e.h then e.h = math.max(0.5, e.h + ddh) end
    return string.format("%s  w=%.1f h=%.1f", key, e.w or 0, e.h or 0)
end

-- EN: Emits the table in source form, ready to paste over the LAYOUT literal. Non-geometry
--     fields are preserved so a dump never quietly drops count/gap/digits/label.
-- UA: Виводить таблицю у вигляді коду, готовому до вставки. Негеометричні поля зберігаються.
function CornerPostHUD:consoleDump()
    local out = { "CornerPostHUD.LAYOUT = {" }
    for _, k in ipairs(sortedLayoutKeys()) do
        local e = CornerPostHUD.LAYOUT[k]
        local parts = {}
        for _, f in ipairs(GEOM_FIELDS) do
            if e[f] ~= nil then
                table.insert(parts, string.format("%s = %s", f, tostring(e[f])))
            end
        end
        for _, f in ipairs({ "gap", "count", "digits" }) do
            if e[f] ~= nil then
                table.insert(parts, string.format("%s = %s", f, tostring(e[f])))
            end
        end
        if e.label ~= nil then
            table.insert(parts, string.format('label = "%s"', tostring(e.label)))
        end
        table.insert(out, string.format("    %-12s = { %s },", k, table.concat(parts, ", ")))
    end
    table.insert(out, "}")

    local text = table.concat(out, "\n")
    print(text)   -- EN: also to the log, so it can be copied out of log.txt
    return text
end
