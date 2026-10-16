-- EN: Manual work width - the fork's forage-header use case, layered over upstream WITHOUT editing
--     upstream's files.
--
--     The problem: the area behind yield (t/ha), hectares per hour and the trip odometer comes from
--     the engine's cutter pixel callbacks. A windrow pickup reports its own narrow work area (about
--     12 ft) while the swath it collects can be four times that, so yield reads several times too high.
--     The fix, as in the fork: the operator sets the real working width, and while it is set the area
--     credited each frame is   distance travelled x working width   instead of the pixel count.
--
--     What is here
--       - the setting, kept where the fork kept it (spec.combineMemory.swathWidth, metres, nil = auto);
--       - the area rule, applied just before upstream's onUpdateTick reads and consumes its per-frame area;
--       - a "Working Width" row with - / + buttons, drawn under the calibration terminal (Shift+K) using the
--         terminal's own button system; steps are 0.5 m or 1 ft, as in the fork; - at the first step returns
--         to Auto; cap 50 m;
--       - rhmWorkWidth <value|auto> on the console;
--       - what the fork did not do: the width is saved with the game and synchronised in multiplayer
--         (a small event for changes, and appended to upstream's initial stream for players who join).
--
--     Hooks (verified against upstream v1.6.4.0):
--       rhm_Combine.onUpdateTick          - area correction (reads spec.lastRawArea at the top of its area step)
--       rhm_Combine.registerXMLPaths      - schema path for the saved value
--       rhm_Combine.saveToXMLFile / loadFromSavegame - persistence (engine dispatches by table lookup)
--       rhm_Combine.onWriteStream / onReadStream     - initial sync for joining players
--       RHMCombineCalibrationGUI.draw     - the row; clicks use the terminal's own button list
--
-- UA: Ручна робоча ширина - сценарій форку для форажних жаток, поверх оригіналу БЕЗ правок його файлів.
--     Підбирач валків повідомляє вузьку власну робочу зону, тож урожайність (т/га) завищується в рази.
--     Поки задано ширину, площа за кадр = пройдена відстань x робоча ширина. Додатково (чого не було у
--     форку): збереження у грі та синхронізація в мультиплеєрі.
WorkWidth = {}

local MOD_NAME = g_currentModName or "FS25_RealisticHarvesting"

WorkWidth.MAX_METRES      = 50.0
WorkWidth.MIN_METRES      = 0.3        -- just under one foot: the first imperial step must be a valid width
WorkWidth.STEP_METRIC     = 0.5
WorkWidth.STEP_IMPERIAL   = 0.3048      -- one foot
local FEET_PER_METRE      = 1 / 0.3048

local warned = {}
local function reportOnce(key, err)
    if warned[key] then return end
    warned[key] = true
    Logging.warning("[RHM-fork] WorkWidth %s failed: %s", tostring(key), tostring(err))
end

-- ============================================================================
-- EN: The setting
-- UA: Налаштування
-- ============================================================================

local function memoryOf(vehicle)
    local spec = vehicle and vehicle.spec_rhm_Combine
    return spec and spec.combineMemory or nil, spec
end

-- EN: nil / zero / out-of-range -> a sane value or nil (Auto).
function WorkWidth.normalize(metres)
    metres = tonumber(metres)
    if not metres or metres <= 0 then return nil end
    metres = math.min(WorkWidth.MAX_METRES, metres)
    if metres < WorkWidth.MIN_METRES then return nil end
    -- EN: Rounded to 0.1 mm, not centimetres: a foot is 0.3048 m, and rounding each press to 0.30 would
    --     make 48 presses come out at 47 ft instead of 48.
    -- UA: Округлення до 0.1 мм, а не до сантиметрів: інакше 48 натискань по футу дадуть 47 футів.
    return math.floor(metres * 10000 + 0.5) / 10000
end

function WorkWidth.get(vehicle)
    local mem = memoryOf(vehicle)
    local w = mem and mem.swathWidth
    if w and w > 0 then return w end
    return nil
end

-- EN: Local state only; used by the event, by loading and by the stream.
function WorkWidth.apply(vehicle, metres)
    local mem = memoryOf(vehicle)
    if not mem then return false end
    mem.swathWidth = WorkWidth.normalize(metres)
    return true
end

local function isImperial()
    local sys = RHM_UnitConverter and RHM_UnitConverter.getActiveSystem and RHM_UnitConverter.getActiveSystem() or 1
    return sys ~= 1
end

function WorkWidth.stepSize()
    return isImperial() and WorkWidth.STEP_IMPERIAL or WorkWidth.STEP_METRIC
end

function WorkWidth.format(metres)
    if not metres or metres <= 0 then return "Auto" end
    if isImperial() then return string.format("%.0f ft", metres * FEET_PER_METRE) end
    return string.format("%.1f m", metres)
end

-- ============================================================================
-- EN: Area rule
-- UA: Правило площі
-- ============================================================================

-- EN: Upstream's addCutterArea accumulates the engine's pixel area into spec.lastRawArea (and lastArea);
--     onUpdateTick then reads lastRawArea as the area for yield, the trip tracker and ha/h, and clears it.
--     While a width is set, replace a frame's area by distance x width. Only a positive result replaces
--     it, so "is something being harvested" checks that look at lastRawArea > 0 keep seeing what they saw.
-- UA: addCutterArea накопичує піксельну площу в spec.lastRawArea; onUpdateTick читає її як площу для
--     урожайності, трекера та га/год. Поки ширину задано, площа кадру = відстань x ширина.
function WorkWidth.correctArea(vehicle)
    local spec = vehicle.spec_rhm_Combine
    if not spec then return end
    local width = WorkWidth.get(vehicle)
    if not width then return end
    if (spec.lastRawArea or 0) <= 0 and (spec.lastLiters or 0) <= 0 and (spec._fallbackLiters or 0) <= 0 then return end

    local area = (vehicle.lastMovedDistance or 0) * width
    if area > 0 then
        spec.lastRawArea = area
        spec.lastArea = area * (spec.lastMultiplier or 1)
    end
end

-- ============================================================================
-- EN: Network
-- UA: Мережа
-- ============================================================================

ForkWorkWidthEvent = {}
local ForkWorkWidthEvent_mt = Class(ForkWorkWidthEvent, Event)
InitEventClass(ForkWorkWidthEvent, "ForkWorkWidthEvent")

function ForkWorkWidthEvent.emptyNew()
    return Event.new(ForkWorkWidthEvent_mt)
end

function ForkWorkWidthEvent.new(vehicle, metres)
    local self = ForkWorkWidthEvent.emptyNew()
    self.vehicle = vehicle
    self.metres = metres or 0
    return self
end

function ForkWorkWidthEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteFloat32(streamId, self.metres or 0)
end

function ForkWorkWidthEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.metres = streamReadFloat32(streamId)
    self:run(connection)
end

-- EN: A client may change a machine its farm owns.
function WorkWidth.canModify(connection, vehicle)
    if connection == nil or connection:getIsServer() then return true end
    local user = g_currentMission and g_currentMission.userManager and g_currentMission.userManager:getUserByConnection(connection)
    if not user then return false end
    if g_currentMission.isMasterUser and connection == g_currentMission.connectionToMasterUser then return true end
    local farm = g_farmManager and g_farmManager:getFarmForUniqueUserId(user:getUniqueUserId())
    return farm ~= nil and farm.farmId == vehicle:getOwnerFarmId()
end

function ForkWorkWidthEvent:run(connection)
    local vehicle = self.vehicle
    if not vehicle or vehicle.isDeleted or not vehicle.spec_rhm_Combine then return end
    if not connection:getIsServer() then
        -- server, from a client: check, apply, tell everyone else
        if not WorkWidth.canModify(connection, vehicle) then return end
        WorkWidth.apply(vehicle, self.metres)
        g_server:broadcastEvent(ForkWorkWidthEvent.new(vehicle, self.metres), nil, connection, vehicle)
    else
        WorkWidth.apply(vehicle, self.metres)
    end
end

-- EN: UI / console entry. Single-player and the host apply and broadcast; a client applies for instant
--     feedback and asks the server.
function WorkWidth.request(vehicle, metres)
    if not (vehicle and vehicle.spec_rhm_Combine) then return false end
    metres = WorkWidth.normalize(metres) or 0
    WorkWidth.apply(vehicle, metres)
    if g_server ~= nil then
        g_server:broadcastEvent(ForkWorkWidthEvent.new(vehicle, metres), nil, nil, vehicle)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(ForkWorkWidthEvent.new(vehicle, metres))
    end
    return true
end

-- EN: One - or + press. At or below one step, - returns to Auto.
function WorkWidth.step(vehicle, direction)
    local cur = WorkWidth.get(vehicle) or 0
    local step = WorkWidth.stepSize()
    local new
    if direction < 0 then
        new = cur - step
        if new < step * 0.5 then new = 0 end
    else
        new = math.max(step, cur + step)
    end
    return WorkWidth.request(vehicle, new)
end

-- ============================================================================
-- EN: Hooks
-- UA: Хуки
-- ============================================================================

local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] WorkWidth: %s.%s not found - that part of the feature is inactive", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end
-- EN: rhm_Combine is re-sourced by the engine, which replaces the table (see SpecHooks.lua), so hooks on it
--     are registered with the installer rather than applied here.
-- UA: rhm_Combine Ð¿ÐµÑ€ÐµÐ·Ð°Ð²Ð°Ð½Ñ‚Ð°Ð¶ÑƒÑ”Ñ‚ÑŒÑÑ Ñ€ÑƒÑˆÑ–Ñ”Ð¼ Ñ– Ð¿Ñ–Ð´Ð¼Ñ–Ð½ÑÑ”Ñ‚ÑŒÑÑ (Ð´Ð¸Ð². SpecHooks.lua), Ñ‚Ð¾Ð¼Ñƒ Ñ…ÑƒÐºÐ¸ Ñ€ÐµÑ”ÑÑ‚Ñ€ÑƒÑŽÑ‚ÑŒÑÑ Ð²
--     Ñ–Ð½ÑÑ‚Ð°Ð»ÐµÑ€Ñ–, Ð° Ð½Ðµ Ð·Ð°ÑÑ‚Ð¾ÑÐ¾Ð²ÑƒÑŽÑ‚ÑŒÑÑ Ñ‚ÑƒÑ‚.
local function hookSpec(method, wrapper)
    ForkSpecHooks.add("work width: " .. method, function()
        wrapMethod(rhm_Combine, "rhm_Combine", method, wrapper)
    end)
end

-- Area rule: just before upstream's own onUpdateTick consumes the frame's area.
hookSpec("onUpdateTick", function(orig, self, ...)
    if self.isServer then
        local ok, err = pcall(WorkWidth.correctArea, self)
        if not ok then reportOnce("correctArea", err) end
    end
    return orig(self, ...)
end)

-- Persistence. The path sits beside upstream's own saved machine settings.
local SAVE_PATH = ".combineMemory.current#workWidth"

hookSpec("registerXMLPaths", function(orig, schema, basePath)
    orig(schema, basePath)
    schema:register(XMLValueType.FLOAT, basePath .. SAVE_PATH, "Manual work width in metres (0 = auto)", 0)
end)

hookSpec("saveToXMLFile", function(orig, self, xmlFile, key, usedModNames)
    local r = orig(self, xmlFile, key, usedModNames)
    local width = WorkWidth.get(self)
    if width then
        xmlFile:setValue(key .. SAVE_PATH, width)
    end
    return r
end)

hookSpec("loadFromSavegame", function(orig, self, savegame)
    local r = orig(self, savegame)
    if savegame and savegame.xmlFile and savegame.key and not savegame.resetVehicles then
        local path = string.format("%s.%s.rhm_Combine%s", savegame.key, MOD_NAME, SAVE_PATH)
        if savegame.xmlFile:hasProperty(path) then
            WorkWidth.apply(self, savegame.xmlFile:getValue(path))
        end
    end
    return r
end)

-- Initial sync for a player who joins: appended to upstream's own stream, written and read in the same
-- order on both ends. Always written, whatever upstream did, so the two ends cannot drift apart.
hookSpec("onWriteStream", function(orig, self, streamId, connection)
    orig(self, streamId, connection)
    local width = WorkWidth.get(self)
    streamWriteBool(streamId, width ~= nil)
    if width then streamWriteFloat32(streamId, width) end
end)

hookSpec("onReadStream", function(orig, self, streamId, connection)
    orig(self, streamId, connection)
    local has = streamReadBool(streamId)
    local width = has and streamReadFloat32(streamId) or nil
    WorkWidth.apply(self, width)
end)

-- ============================================================================
-- EN: The row under the calibration terminal. Uses the terminal's own drawing helpers and button list
--     (draw() rebuilds the list each frame; mouseEvent dispatches clicks from it wherever they land).
-- UA: Рядок під терміналом калібрування; використовує його власні допоміжні функції та список кнопок.
-- ============================================================================
function WorkWidth.drawRow(gui)
    local vehicle = gui.activeVehicle
    local mem = memoryOf(vehicle)
    if not mem then return end

    local ui = gui.ui
    local colors = ui.colors or {}
    local h, gap = 0.032, 0.004
    local x, w = ui.x, ui.w
    local y = ui.y - gap - h
    if y < 0.005 then y = ui.y + ui.h + gap end          -- no room below: sit above the terminal

    gui:drawRect(x, y, w, h, colors.bg or { 0.012, 0.015, 0.020, 0.68 })
    gui:drawBorder(x, y, w, h, colors.outerBorder or { 1, 1, 1, 0.10 }, 1)

    local textY = y + h * 0.5 - ui.fontSize * 0.36
    local btnW, btnH = ui.buttonW or 0.017, ui.buttonH or 0.017
    local plusX = x + w - ui.margin - btnW
    local minusX = plusX - btnW - 0.004
    local valueRight = minusX - 0.010

    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    local dim = colors.textDim or { 0.70, 0.74, 0.80, 1 }
    setTextColor(dim[1], dim[2], dim[3], dim[4] or 1)
    renderText(x + ui.margin, textY, ui.fontSize, "Working Width")

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    local txt = colors.text or { 1, 1, 1, 1 }
    setTextColor(txt[1], txt[2], txt[3], txt[4] or 1)
    renderText(valueRight, textY, ui.fontSize, WorkWidth.format(mem.swathWidth))
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)

    local by = y + (h - btnH) * 0.5
    gui:drawButton(minusX, by, btnW, btnH, "-", function() WorkWidth.step(vehicle, -1) end, colors.button)
    gui:drawButton(plusX,  by, btnW, btnH, "+", function() WorkWidth.step(vehicle, 1)  end, colors.button)
    if gui._resetTextState then gui:_resetTextState() end
end

if RHMCombineCalibrationGUI and type(RHMCombineCalibrationGUI.draw) == "function" then
    wrapMethod(RHMCombineCalibrationGUI, "RHMCombineCalibrationGUI", "draw", function(orig, self, ...)
        local r = orig(self, ...)
        if self.isOpen then
            local ok, err = pcall(WorkWidth.drawRow, self)
            if not ok then reportOnce("drawRow", err) end
        end
        return r
    end)
else
    Logging.warning("[RHM-fork] WorkWidth: RHMCombineCalibrationGUI.draw not found - no on-screen row (use rhmWorkWidth)")
end

-- ============================================================================
-- EN: Console + API
-- UA: Консоль та API
-- ============================================================================

-- EN: "14.6", "14.6m", "48ft", "auto".
function WorkWidth.parse(text)
    if text == nil then return nil, "missing" end
    local s = tostring(text):lower():gsub("%s+", "")
    if s == "auto" or s == "0" or s == "off" then return 0 end
    local num, unit = s:match("^([%d%.]+)(%a*)$")
    num = tonumber(num)
    if not num then return nil, "bad" end
    if unit == "ft" or unit == "feet" or unit == "'" then return num * 0.3048 end
    if unit == "" or unit == "m" then return num end
    return nil, "bad"
end

function WorkWidth.consoleCommand(_, arg)
    local mgr = g_realisticHarvestManager
    local vehicle = mgr and mgr.lastActiveCombine
    if not (vehicle and vehicle.spec_rhm_Combine) then
        return "Working width: climb into a combine first"
    end
    if arg == nil or arg == "" or tostring(arg):lower() == "status" then
        return "Working width: " .. WorkWidth.format(WorkWidth.get(vehicle))
    end
    local metres, why = WorkWidth.parse(arg)
    if metres == nil then
        return "Usage: rhmWorkWidth <metres | 48ft | auto>"
    end
    WorkWidth.request(vehicle, metres)
    return "Working width: " .. WorkWidth.format(WorkWidth.get(vehicle))
end

if RHM_RealisticHarvestManager and type(RHM_RealisticHarvestManager.new) == "function" then
    local origNew = RHM_RealisticHarvestManager.new
    RHM_RealisticHarvestManager.new = function(...)
        local self = origNew(...)
        addConsoleCommand("rhmWorkWidth", "rhmWorkWidth <metres|48ft|auto> - manual working width for yield and work rate",
            "consoleCommand", WorkWidth)
        return self
    end
end

-- The fork's accessor, kept for anything written against it.
if RHM_Api and RHM_Api.getSwathWidth == nil then
    ---@return number metres 0 when automatic
    function RHM_Api.getSwathWidth(vehicle)
        local combine = vehicle and (vehicle.spec_rhm_Combine and vehicle or vehicle.rootVehicle) or nil
        return WorkWidth.get(combine) or 0
    end
end
