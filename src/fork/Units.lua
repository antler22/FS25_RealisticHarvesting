-- EN: Fork unit policy, layered over upstream's RHM_UnitConverter WITHOUT editing it.
--
--     Upstream's Imperial setting shows mass flow as lbs/s and yield as metric t/ac, and its Bushels setting
--     shows everything as bushels, forage included. The fork's rule, for either US setting (Imperial or
--     Bushels - Metric is left alone):
--         grain  -> bushels   (bu, bu/h, bu/min, bu/ac)
--         silage / forage -> US short tons   (tn, tn/h, tn/ac)
--     so no pounds anywhere.
--
--     "Forage" means the machine you are in is a forage machine (the HUD builds its cells inside a scoped
--     flag set from spec_rhm_Combine.machineType), or the crop passed in is a forage crop. Screens that pass
--     neither (the harvest history totals) are treated as grain.
--
-- UA: Політика одиниць форку поверх RHM_UnitConverter без правок оригіналу. Для американських систем:
--     зерно - бушелі, силос / фураж - короткі американські тонни, без фунтів.
RHM_ForkUnits = {}

RHM_ForkUnits.enabled = true
RHM_ForkUnits.SHORT_TON_PER_TONNE = 1.10231
RHM_ForkUnits.forageContext = false

local FORAGE_CROP_NAMES = { "GRASS", "DRYGRASS", "ALFALFA", "CLOVER", "SILAGE", "CHAFF", "HAY", "WINDROW" }

local warned = {}
local function reportOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    Logging.warning("[RHM-fork] Units: %s", msg)
end

local function isUsSystem(system)
    local U = RHM_UnitConverter
    return system == U.SYSTEM_IMPERIAL or system == U.SYSTEM_BUSHELS
end

-- EN: Is this crop (a FruitType index) forage? Resolved lazily - FruitType is filled after mission load.
local function isForageCrop(fruitType)
    if not fruitType or not FruitType then return false end
    for _, name in ipairs(FORAGE_CROP_NAMES) do
        if FruitType[name] == fruitType then return true end
    end
    return false
end

function RHM_ForkUnits.isForage(fruitType)
    return RHM_ForkUnits.forageContext or isForageCrop(fruitType)
end

-- EN: Does the policy apply to this call? Only for the US systems, and only if enabled.
local function applies(system)
    return RHM_ForkUnits.enabled and isUsSystem(system)
end

local function hook(name, wrapper)
    local U = RHM_UnitConverter
    local orig = U and U[name]
    if type(orig) ~= "function" then
        reportOnce(name, "RHM_UnitConverter." .. name .. " not found - unit policy inactive for it")
        return
    end
    U[name] = function(...) return wrapper(orig, ...) end
end

local function resolve(system)
    return system or RHM_UnitConverter.getActiveSystem()
end

hook("convertMass", function(orig, tonnes, system, fruitType, liters)
    system = resolve(system)
    if applies(system) then
        if RHM_ForkUnits.isForage(fruitType) then
            return (tonnes or 0) * RHM_ForkUnits.SHORT_TON_PER_TONNE, "tn"
        end
        return orig(tonnes, RHM_UnitConverter.SYSTEM_BUSHELS, fruitType, liters)
    end
    return orig(tonnes, system, fruitType, liters)
end)

hook("convertProductivity", function(orig, tph, system, fruitType, litersPerHour)
    system = resolve(system)
    if applies(system) then
        if RHM_ForkUnits.isForage(fruitType) then
            return (tph or 0) * RHM_ForkUnits.SHORT_TON_PER_TONNE, "tn/h"
        end
        return orig(tph, RHM_UnitConverter.SYSTEM_BUSHELS, fruitType, litersPerHour)
    end
    return orig(tph, system, fruitType, litersPerHour)
end)

-- Upstream's Imperial flow rate is lbs/s; the US policy replaces it.
hook("convertFlowRate", function(orig, tph, system, fruitType, litersPerHour)
    system = resolve(system)
    if applies(system) then
        if RHM_ForkUnits.isForage(fruitType) then
            return (tph or 0) * RHM_ForkUnits.SHORT_TON_PER_TONNE, "tn/h"
        end
        return orig(tph, RHM_UnitConverter.SYSTEM_BUSHELS, fruitType, litersPerHour)
    end
    return orig(tph, system, fruitType, litersPerHour)
end)

-- Upstream's Imperial yield is "t/ac" in metric tonnes; the US policy makes it bu/ac or short tons/acre.
hook("convertYield", function(orig, tPerHa, system, fruitType)
    system = resolve(system)
    if applies(system) then
        if RHM_ForkUnits.isForage(fruitType) then
            return (tPerHa or 0) * RHM_ForkUnits.SHORT_TON_PER_TONNE / RHM_UnitConverter.HECTARE_TO_ACRE, "tn/ac"
        end
        return orig(tPerHa, RHM_UnitConverter.SYSTEM_BUSHELS, fruitType)
    end
    return orig(tPerHa, system, fruitType)
end)

-- EN: The HUD builds its cells for one vehicle; mark forage machines for the duration of that call.
local hud = RHMDraggableHUD
if hud and type(hud.buildActiveCells) == "function" then
    local origBuild = hud.buildActiveCells
    hud.buildActiveCells = function(self, ...)
        local v = self.vehicle
        local spec = v and v.spec_rhm_Combine
        local previous = RHM_ForkUnits.forageContext
        RHM_ForkUnits.forageContext = (spec and spec.machineType == "forage") or false
        local ok, a, b, c = pcall(origBuild, self, ...)
        RHM_ForkUnits.forageContext = previous
        if not ok then error(a, 0) end
        return a, b, c
    end
else
    reportOnce("hud", "RHMDraggableHUD.buildActiveCells not found - the HUD will treat forage as grain")
end

function RHM_ForkUnits.consoleCommand(_, arg)
    local a = arg and tostring(arg):lower() or ""
    if a == "on" or a == "1" then RHM_ForkUnits.enabled = true
    elseif a == "off" or a == "0" then RHM_ForkUnits.enabled = false
    elseif a ~= "" and a ~= "status" then return "Usage: rhmUnits [on|off|status]" end
    local sys = RHM_UnitConverter.getActiveSystem()
    return string.format("Fork units: %s (grain in bushels, silage in US tons; active system %d - applies to 2 and 3 only)",
        RHM_ForkUnits.enabled and "ON" or "OFF", sys)
end

if RHM_RealisticHarvestManager and type(RHM_RealisticHarvestManager.new) == "function" then
    local origNew = RHM_RealisticHarvestManager.new
    RHM_RealisticHarvestManager.new = function(...)
        local self = origNew(...)
        addConsoleCommand("rhmUnits", "rhmUnits [on|off|status] - grain in bushels, silage in US tons",
            "consoleCommand", RHM_ForkUnits)
        return self
    end
end
