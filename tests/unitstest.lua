-- Headless harness for src/fork/Units.lua against the REAL upstream RHM_UnitConverter.
-- Run from the mod root:  lua tests/unitstest.lua
local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end, error = function() end, info = function() end }
local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end
FruitType = { WHEAT = 1, GRASS = 2, ALFALFA = 3, MAIZE = 4 }
RHM_RealisticHarvestManager = { new = function() return {} end }
RHMDraggableHUD = { buildActiveCells = function(self)
    local mass, s1 = RHM_UnitConverter.convertMass(10, nil, nil, 1000)
    local flow, s2 = RHM_UnitConverter.convertFlowRate(36, nil, nil, 36000)
    return s1, s2
end }
g_realisticHarvestManager = { settings = { unitSystem = 2 } }

dofile("src/utils/RHM_UnitConverter.lua")
RHM_UnitConverter.initBushelCoefficients()
dofile("src/fork/Units.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-70s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-70s %s", name, detail or "")) end
end
local function near(a, b, t) return math.abs(a - b) <= (t or 1e-6) end
local U, F = RHM_UnitConverter, RHM_ForkUnits

print("=== 1. loads cleanly ===")
check("no warnings", #warnings == 0, warnings[1] or "")

print("=== 2. grain is bushels, in both US systems ===")
for _, sys in ipairs({ 2, 3 }) do
    local v, s = U.convertMass(10, sys, FruitType.WHEAT, 3523.91)
    check("mass, system " .. sys, s == "bu" and near(v, 100, 1e-3))
    v, s = U.convertProductivity(10, sys, FruitType.WHEAT, 7047.82)
    check("productivity, system " .. sys, s == "bu/h" and near(v, 200, 1e-3))
    v, s = U.convertFlowRate(10, sys, FruitType.WHEAT, 7047.82)
    check("flow rate, system " .. sys .. " (no lbs/s)", s == "bu/min" and near(v, 200 / 60, 1e-3))
    v, s = U.convertYield(8, sys, FruitType.WHEAT)
    check("yield, system " .. sys, s == "bu/ac" and v > 0)
end
check("no 'lb' unit anywhere in the grain results", not (select(2, U.convertFlowRate(5, 2, FruitType.WHEAT, 4000)):find("lb")))

print("=== 3. forage is US short tons ===")
local v, s = U.convertMass(10, 2, FruitType.ALFALFA)
check("alfalfa mass -> tn", s == "tn" and near(v, 11.0231))
v, s = U.convertMass(10, 3, FruitType.GRASS)
check("grass mass -> tn even in the Bushels system", s == "tn" and near(v, 11.0231))
v, s = U.convertFlowRate(36, 2, FruitType.GRASS)
check("forage flow -> tn/h, not lbs/s", s == "tn/h" and near(v, 36 * 1.10231))
v, s = U.convertProductivity(36, 3, FruitType.ALFALFA)
check("forage productivity -> tn/h", s == "tn/h" and near(v, 36 * 1.10231))
v, s = U.convertYield(20, 2, FruitType.GRASS)
check("forage yield -> tn/ac (short tons, not metric)", s == "tn/ac" and near(v, 20 * 1.10231 / 2.47105, 1e-4))
check("silage maize is NOT forage by crop alone (grain maize stays bushels)", select(2, U.convertMass(10, 2, FruitType.MAIZE, 1000)) == "bu")

print("=== 4. the machine context decides for forage machines ===")
local s1, s2 = RHMDraggableHUD.buildActiveCells({ vehicle = { spec_rhm_Combine = { machineType = "forage" } } })
check("a forage machine's HUD reads tons", s1 == "tn" and s2 == "tn/h")
s1, s2 = RHMDraggableHUD.buildActiveCells({ vehicle = { spec_rhm_Combine = { machineType = "grain" } } })
check("a grain machine's HUD reads bushels", s1 == "bu" and s2 == "bu/min")
check("the context does not leak out", F.forageContext == false and select(2, U.convertMass(10, 2, nil, 1000)) == "bu")
local ok = pcall(function() RHMDraggableHUD.buildActiveCells(nil) end)
RHMDraggableHUD.buildActiveCells({ vehicle = { spec_rhm_Combine = { machineType = "forage" } } })
check("an error inside still restores the context", F.forageContext == false)

print("=== 5. the default (active system) path ===")
g_realisticHarvestManager.settings.unitSystem = 2
check("no system passed: uses the active one and applies the policy", select(2, U.convertFlowRate(5, nil, FruitType.WHEAT, 4000)) == "bu/min")

print("=== 6. metric is untouched ===")
v, s = U.convertMass(10, 1, FruitType.WHEAT); check("mass", s == "t" and v == 10)
v, s = U.convertFlowRate(36, 1); check("flow", s == "kg/s" and near(v, 10))
v, s = U.convertYield(8, 1); check("yield", s == "t/ha" and v == 8)
g_realisticHarvestManager.settings.unitSystem = 1
check("active metric: untouched", select(2, U.convertMass(10, nil, FruitType.GRASS)) == "t")
g_realisticHarvestManager.settings.unitSystem = 2

print("=== 7. switch off, console ===")
F.enabled = false
check("off: upstream's own lbs/s comes back", select(2, U.convertFlowRate(5, 2, FruitType.WHEAT)) == "lbs/s")
F.enabled = true
RHM_RealisticHarvestManager.new()
check("rhmUnits registered", commands[#commands] == "rhmUnits")
check("status / usage", F.consoleCommand(nil, "status"):find("ON") ~= nil and F.consoleCommand(nil, "zz"):find("Usage") ~= nil)

print("=== 8. formatters pick the policy up ===")
check("formatMass grain: whole bushels", U.formatMass(10, 2, FruitType.WHEAT, 3523.91) == "100 bu")
check("formatMass forage: short tons", U.formatMass(10, 2, FruitType.GRASS) == "11.0 tn")
check("formatFlowRate forage", U.formatFlowRate(36, 2, FruitType.GRASS) == "39.7 tn/h")

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
