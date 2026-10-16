-- Checks the corner post layout for canvas overflow, column overlap and panel collision.
--
-- Loads the real module with FS25 globals stubbed rather than scraping the source with a
-- pattern. The scrape approach broke the moment LAYOUT was renamed for the live editor, and
-- would keep breaking on every refactor — loading the module means this test tracks the code
-- automatically and can never silently check a stale copy.
g_currentMission   = { time = 0 }
Logging            = { warning = function() end, error = function() end }
g_screenAspectRatio = 1.7777
function addConsoleCommand() end
Overlay = { new = function()
    return { setPosition = function() end, setDimension = function() end,
             setColor = function() end, render = function() end, delete = function() end }
end }

dofile("src/training/TrainingMode.lua")
dofile("src/training/SignalConditioner.lua")
dofile("src/training/TelemetryProvider.lua")
dofile("src/hud/CornerPostHUD.lua")

local L = CornerPostHUD.LAYOUT

-- PANEL_W/H are file-locals, so read them back through the module's own conversion:
-- a full-canvas element maps to the whole panel, which recovers the canvas dimensions.
local src = io.open("src/hud/CornerPostHUD.lua"):read("*a")
local PANEL_W = tonumber(src:match("local PANEL_W = (%d+)"))
local PANEL_H = tonumber(src:match("local PANEL_H = (%d+)"))
assert(PANEL_W and PANEL_H, "could not read PANEL_W / PANEL_H")

print(string.format("Panel canvas: %d x %d  (aspect 1 : %.2f)", PANEL_W, PANEL_H, PANEL_H/PANEL_W))
print()

local fail = 0
local function within(name, x, y, w, h)
    local ok = x >= 0 and y >= 0 and (x+w) <= PANEL_W and (y+h) <= PANEL_H
    if not ok then fail = fail + 1 end
    print(string.format("  %-12s x=%5.1f y=%5.1f w=%5.1f h=%5.1f  ->  %s",
        name, x, y, w, h, ok and "inside" or "*** OVERFLOWS ***"))
end

-- EN: Every LAYOUT.<key> the draw code touches must exist in the table.
--     This is not hypothetical: removing `rightIcons` from LAYOUT while leaving its draw
--     block in place threw inside draw(), and because the error aborted the whole callback
--     the ENTIRE upper panel silently vanished — reported as "my gauges are missing", not as
--     a crash. One undefined key takes the display down. Catch it here instead.
-- UA: Кожен ключ LAYOUT.<key>, який використовує код малювання, має існувати в таблиці.
--     Видалення `rightIcons` з LAYOUT із залишеним блоком малювання валило draw(), і через
--     це ЗНИКАЛА вся верхня панель — про це повідомили як "немає датчиків", а не як збій.
do
    local defined = {}
    for k, v in pairs(L) do if type(v) == "table" then defined[k] = true end end

    local missing = {}
    for key in src:gmatch("LAYOUT%.(%w+)") do
        if not defined[key] and not missing[key] then missing[key] = true end
    end

    local names = {}
    for k in pairs(missing) do table.insert(names, k) end
    table.sort(names)

    print("LAYOUT key reference check:")
    if #names == 0 then
        print("  every LAYOUT key used by the draw code is defined")
    else
        fail = fail + #names
        for _, n in ipairs(names) do
            print(string.format("  *** LAYOUT.%s is USED BUT NOT DEFINED — draw() will throw ***", n))
        end
    end
    print()
end

-- EN: Every self:method() the file calls must actually be defined on the class.
--     luac -p cannot catch this: deleting a function leaves the file perfectly valid Lua, and
--     the failure only appears at runtime as "attempt to call missing method". That is exactly
--     what happened — an edit removed loadIcons and drawIcon, the panel threw on every frame,
--     AND because load() calls loadIcons before applyAnchor the panel silently stopped pinning
--     to the right edge. One deletion, two seemingly unrelated symptoms.
-- UA: Кожен виклик self:method() має бути визначений у класі. luac -p цього не ловить:
--     видалення функції лишає файл синтаксично коректним, а помилка з'являється лише під час
--     виконання. Саме так зникли loadIcons і drawIcon — панель падала щокадру і водночас
--     переставала притискатись до правого краю, бо load() викликає loadIcons до applyAnchor.
do
    local defined = {}
    for name in src:gmatch("function%s+CornerPostHUD[:%.](%w+)") do
        defined[name] = true
    end

    local called, missing = {}, {}
    for name in src:gmatch("self:(%w+)%s*%(") do
        called[name] = true
        if not defined[name] then missing[name] = true end
    end

    local names = {}
    for k in pairs(missing) do table.insert(names, k) end
    table.sort(names)

    print("Method reference check:")
    if #names == 0 then
        local n = 0
        for _ in pairs(called) do n = n + 1 end
        print(string.format("  all %d self:method() calls resolve to a definition", n))
    else
        fail = fail + #names
        for _, n in ipairs(names) do
            print(string.format("  *** self:%s() is CALLED BUT NOT DEFINED — draw() will throw ***", n))
        end
    end
    print()
end

-- EN: Colours left behind by removed features are invisible rot — nothing breaks, the file
--     just accumulates constants nobody can safely delete later because it is no longer
--     obvious which are live. `marker` and `schematic` outlived their draw code this way.
--     Gauge zones name their colour as a STRING, so both forms have to count as a use.
-- UA: Кольори, що лишились від видалених функцій, — невидиме сміття. `marker` і `schematic`
--     пережили свій код малювання саме так. Зони датчиків задають колір РЯДКОМ, тож
--     враховуються обидві форми звертання.
do
    local block = src:match("local COLORS%s*=%s*{(.-)\n}")
    assert(block, "could not find the COLORS table")

    local dead = {}
    for key in block:gmatch("\n%s*(%w+)%s*=") do
        local byField  = src:find("COLORS%." .. key .. "%f[%W]")
        local byString = src:find('"' .. key .. '"')
        if not byField and not byString then dead[#dead + 1] = key end
    end

    print("Colour usage check:")
    if #dead == 0 then
        print("  every COLORS entry is referenced")
    else
        fail = fail + #dead
        for _, k in ipairs(dead) do
            print(string.format("  *** COLORS.%s is DEFINED BUT NEVER USED ***", k))
        end
    end
    print()
end

-- EN: COLUMNS, GAUGES and SETTING_ROWS address LAYOUT, the telemetry contract, GAUGE_SPECS
--     and the icon registry BY STRING. That indirection is what lets the live editor mutate
--     LAYOUT in place, but it means a typo is not a load error — it is a nil at 60 Hz, and
--     the element just quietly stops being drawn. Resolve every name here instead.
-- UA: COLUMNS, GAUGES і SETTING_ROWS звертаються до LAYOUT, телеметрії, GAUGE_SPECS та
--     реєстру іконок РЯДКАМИ. Це потрібно редактору, але помилка в назві не впаде під час
--     завантаження — елемент просто тихо зникне. Перевіряємо кожну назву тут.
do
    local telemetry = TelemetryProvider.data
    local icons     = CornerPostHUD.ICON_FILES
    local specs     = CornerPostHUD.GAUGE_SPECS

    local bad = {}
    local function need(cond, what)
        if not cond then bad[#bad + 1] = what end
    end

    for key, c in pairs(CornerPostHUD.COLUMNS) do
        need(L[c.geom] ~= nil,          string.format("COLUMNS.%s.geom -> LAYOUT.%s", key, c.geom))
        need(telemetry[c.seg] ~= nil,   string.format("COLUMNS.%s.seg -> telemetry.%s", key, c.seg))
        need(icons[c.icon] ~= nil,      string.format("COLUMNS.%s.icon -> icon %q", key, c.icon))
    end

    -- EN: Every column the panel draws must be defined, and every definition must be drawn.
    --     A stray entry either way is a column that silently does not appear.
    for _, col in ipairs(TrainingMode.BAR_LAYOUT) do
        need(CornerPostHUD.COLUMNS[col.key] ~= nil,
            string.format("BAR_LAYOUT %q has no COLUMNS entry — it will not be drawn", col.key))
    end
    for key in pairs(CornerPostHUD.COLUMNS) do
        local found = false
        for _, col in ipairs(TrainingMode.BAR_LAYOUT) do
            if col.key == key then found = true break end
        end
        need(found, string.format("COLUMNS.%s is defined but not in BAR_LAYOUT", key))
    end

    for _, g in ipairs(CornerPostHUD.GAUGES) do
        need(L[g.geom] ~= nil,          string.format("GAUGES %s.geom -> LAYOUT.%s", g.icon, g.geom))
        need(specs[g.spec] ~= nil,      string.format("GAUGES %s.spec -> GAUGE_SPECS.%s", g.icon, g.spec))
        need(telemetry[g.field] ~= nil, string.format("GAUGES %s.field -> telemetry.%s", g.icon, g.field))
        need(icons[g.icon] ~= nil,      string.format("GAUGES icon %q", g.icon))
    end

    for ri, row in ipairs(CornerPostHUD.SETTING_ROWS) do
        for ci, c in ipairs(row) do
            local at = string.format("SETTING_ROWS[%d][%d]", ri, ci)
            need(icons[c.icon] ~= nil,      string.format("%s icon %q", at, c.icon))
            need(telemetry[c.field] ~= nil, string.format("%s field -> telemetry.%s", at, c.field))
        end
    end

    print("Renderer name-reference check:")
    if #bad == 0 then
        print("  every LAYOUT / telemetry / spec / icon name resolves")
    else
        fail = fail + #bad
        table.sort(bad)
        for _, b in ipairs(bad) do print("  *** UNRESOLVED: " .. b .. " ***") end
    end
    print()
end

print("Bounds check (every element must fit the canvas):")
-- EN: Iterate whatever LAYOUT actually contains, sorted, so adding or renaming an element
--     can never silently escape the bounds check.
local keys = {}
for k, e in pairs(L) do
    if type(e) == "table" and e.x and e.y and e.w and e.h then table.insert(keys, k) end
end
table.sort(keys)
for _, k in ipairs(keys) do
    local e = L[k]; within(k, e.x, e.y, e.w, e.h)
end

-- EN: Fitting the CANVAS is not enough — every element also has to fit the PANEL it belongs
--     to. The speed readout sat at y 80..94 while the upper panel ends at 89, so the bottom
--     of the digits was painted outside the black onto the field. The canvas bounds check
--     above passed the whole time, because 94 is comfortably inside 214.
-- UA: Вписатися в КАНВУ недостатньо — кожен елемент має вписатися і в свою ПАНЕЛЬ. Показник
--     швидкості був на 80..94, а верхня панель закінчується на 89, тож низ цифр малювався
--     поза чорним тлом. Перевірка канви цього не ловила: 94 цілком уміщається в 214.
print()
print("Panel containment (each element must fit the panel it sits on):")
do
    local members = {
        upper = { "gaugeLoad", "gaugeCoolant", "gaugeFuel", "gaugeDef", "gaugeIcons",
                  "rpm", "speed" },
        lower = { "moisture", "tankBar", "tankIcon", "settingsRow",
                  "colShoe", "colTotal", "colSep", "colTail", "markerL", "markerR" },
    }
    for panelKey, list in pairs(members) do
        local p = L[panelKey]
        for _, k in ipairs(list) do
            local e = L[k]
            if e == nil then
                fail = fail + 1
                print(string.format("  *** %s is listed here but missing from LAYOUT ***", k))
            else
                local ok = e.x >= p.x - 1e-9 and e.y >= p.y - 1e-9
                       and (e.x + e.w) <= p.x + p.w + 1e-9
                       and (e.y + e.h) <= p.y + p.h + 1e-9
                if not ok then fail = fail + 1 end
                print(string.format("  %-12s in %-5s  y %5.1f..%5.1f vs %5.1f..%5.1f  %s",
                    k, panelKey, e.y, e.y + e.h, p.y, p.y + p.h,
                    ok and "" or "*** ESCAPES ITS PANEL ***"))
            end
        end
    end
end

-- loss columns: explicit per-column geometry now, not a uniform stride
print()
print("Loss columns (SHOE / TOTAL / SEP / TAIL) + threshold strips, checking overlap:")
local cols = {
    {name="SHOE",  g=L.colShoe},
    {name="MARK-L",g=L.markerL},
    {name="TOTAL", g=L.colTotal},
    {name="MARK-R",g=L.markerR},
    {name="SEP",   g=L.colSep},
    {name="TAIL",  g=L.colTail},
}
for _, c in ipairs(cols) do
    within("col "..c.name, c.g.x, c.g.y, c.g.w, c.g.h)
end
for i = 1, #cols-1 do
    local a, c = cols[i], cols[i+1]
    local gap = c.g.x - (a.g.x + a.g.w)
    local ok = gap >= -0.01
    if not ok then fail = fail + 1 end
    print(string.format("  gap %-6s -> %-6s = %6.2f  %s", a.name, c.name, gap,
        ok and "" or "*** OVERLAP ***"))
end
local totalW, shoeW = L.colTotal.w, L.colShoe.w
print(string.format("  TOTAL is %.2fx the width of SHOE  %s", totalW/shoeW,
    totalW > shoeW * 1.3 and "(wider, as on the real panel)" or "*** should be clearly wider ***"))
if not (totalW > shoeW * 1.3) then fail = fail + 1 end

-- machine settings row: five icon+value cells replacing the old bar stack
print()
print("Machine settings row (chaffer / sieve / fan / rotor / concave):")
local sr = L.settingsRow
within("settingsRow", sr.x, sr.y, sr.w, sr.h)
do
    local cellW = sr.w / 5
    print(string.format("  5 cells of %.1f units each", cellW))
    -- EN: The row must not collide with the loss columns below it, or the icons and the
    --     bars will overlap and both become unreadable.
    local colTop = L.colShoe.y
    local gap = colTop - (sr.y + sr.h)
    local ok = gap > 0
    if not ok then fail = fail + 1 end
    print(string.format("  gap to loss columns = %.1f  %s", gap,
        ok and "" or "*** SETTINGS ROW OVERLAPS THE COLUMNS ***"))

    -- EN: The row shares its vertical band with the grain tank bar on the left. If it starts
    --     too far left the first setting icon is drawn straight over the tank segments and
    --     both become unreadable — the sort of collision that looks like a rendering bug.
    -- UA: Рядок ділить вертикальну смугу з індикатором бункера ліворуч. Якщо почати надто
    --     ліворуч, перша іконка накладеться на сегменти бункера.
    local tk = L.tankBar
    local vOverlap = not (sr.y + sr.h <= tk.y or tk.y + tk.h <= sr.y)
    local hGap = sr.x - (tk.x + tk.w)
    local clear = (not vOverlap) or hGap >= 0
    if not clear then fail = fail + 1 end
    print(string.format("  gap to tank bar = %.1f  %s", hGap,
        clear and "" or "*** SETTINGS ROW OVERLAPS THE TANK BAR ***"))
end

-- upper/lower panel separation
print()
local up, lo = L.upper, L.lower
local panelGap = lo.y - (up.y + up.h)
print(string.format("Gap between upper and lower panel: %.1f units  %s",
    panelGap, panelGap > 0 and "ok" or "*** PANELS OVERLAP ***"))
if panelGap <= 0 then fail = fail + 1 end

-- screen footprint
print()
print("On-screen footprint (width as fraction of screen width):")
for _, ar in ipairs({{"16:9",16/9},{"16:10",16/10},{"21:9",21/9},{"4:3",4/3}}) do
    for _, sc in ipairs({0.45, 0.62, 0.80}) do
        local w = sc * (PANEL_W/PANEL_H) / ar[2]
        print(string.format("  %-6s scale %.2f -> %.1f%% of width, %.0f%% of height",
            ar[1], sc, w*100, sc*100))
    end
end

print()
print(fail == 0 and "GEOMETRY OK - no overflow, no overlap" or ("*** "..fail.." GEOMETRY PROBLEMS ***"))
os.exit(fail == 0 and 0 or 1)
