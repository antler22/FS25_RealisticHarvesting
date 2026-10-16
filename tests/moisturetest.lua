-- Headless harness for src/fork/MoistureModel.lua.
-- Loads the REAL model and config loader, reads the REAL cropThroughput.xml through tests/xmlstub.lua,
-- and drives the hooks against stubs shaped like upstream's load calculator and settings database.
-- Run from the mod root:  lua tests/moisturetest.lua
--
-- Carries over what the fork's old simcoretest guarded about this model (absolute multipliers, long-grain
-- rice resolving to its own thresholds) and adds checks for how it now plugs into upstream.

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }
g_currentModDirectory = "./"
local xmlstub = loadfile("tests/xmlstub.lua")()
xmlstub.install("cropThroughput.xml")

-- ---- upstream-shaped stubs ----
local UP = { enableMoistureSeen = {} }
g_realisticHarvestManager = { settings = { enableMoisture = true } }

RHM_LoadCalculator = {}
function RHM_LoadCalculator:calculateEngineLoad(vehicle)
    UP.enableMoistureSeen.engine = g_realisticHarvestManager.settings.enableMoisture
    self.lastE = self:getCropSpecificEnergy(0, 0, self._machine or "grain", false, self._forageCutter)
    if self._explode then error("boom in engine load") end
end
function RHM_LoadCalculator:getCropSpecificEnergy() return 5.0 end
function RHM_LoadCalculator:calculateTotalCropLoss(vehicle)
    UP.enableMoistureSeen.loss = g_realisticHarvestManager.settings.enableMoisture
    self.settingsAddedLoss = self._settingsLoss or 2.0
    self.moistureLoss = 0
    self.cropLoss, self.totalLoss, self.totalCropLoss = 4.0, 4.0, 4.0
    if self._explode then error("boom in loss") end
    return 4.0
end
function RHM_LoadCalculator:calculateSpeedLimit(vehicle) self.speedLimit = self._rawLimit or 15 end

RHM_CombineSettingsDatabase = {}
function RHM_CombineSettingsDatabase:applyEnvironmentalOffsets(baseTemplate, context, cropName)
    UP.templateLimitSeen = baseTemplate and baseTemplate.moistureLimit
    if self._explode then error("boom in offsets") end
    return { copiedLimit = baseTemplate and baseTemplate.moistureLimit }
end

RHM_Api = {
    findCombine = function(v) return v end,
    getCurrentCrop = function(c) return c._crop end,
    getMoistureLimit = function() return 14.0 end,
}

dofile("src/fork/RealThroughputConfig.lua")
dofile("src/fork/MoistureModel.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-66s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-66s %s", name, detail or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
local M = MoistureModel
local S = g_realisticHarvestManager.settings

local function calc(crop, machine, extra)
    local c = setmetatable({ currentCrop = crop, combineMemory = { machineType = machine or "grain", currentCrop = crop } },
        { __index = RHM_LoadCalculator })
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end
local function vehicle(moisture) return { spec_rhm_Combine = { data = { moisture = moisture } } } end

print("=== 1. the XML loads through the real config loader ===")
RealThroughputConfig.load()
check("config source is the bundled file", RealThroughputConfig._source == "bundled", RealThroughputConfig._source)
check("no warnings", #warnings == 0, warnings[1] or "")
check("global factors read from the XML", M.maxLoadFactor == 1.30 and M.maxLossFactor == 2.00 and M.maxSpeedReduction == 0.35 and M.dryBonusFactor == 0.05)
check("all three effects enabled", M.enableLoad and M.enableLoss and M.enableSpeed)
local w = M.getThresholds("wheat")
check("wheat 13.5 / 22.0 from the XML", w.target == 13.5 and w.max == 22.0)
local corn = M.getThresholds("CORN")
check("corn 15.5 / 35.0 (US harvests wet)", corn.target == 15.5 and corn.max == 35.0)
check("crops added by the port are in the XML", M.getThresholds("buckwheat").target == 16.0 and M.getThresholds("LINSEED").max == 14.0)

print("=== 2. the model (what the fork's old suite guarded) ===")
local ceil = corn.target + M.DEADBAND
check("at the end of the dead band the load factor is exactly 1.0", near(M.getLoadFactor("MAIZE", ceil), 1.0))
check("load factor at/above max moisture equals maxLoadFactor (absolute x1.30, not +130%)", near(M.getLoadFactor("MAIZE", corn.max + 10), 1.30))
check("loss factor at/above max equals maxLossFactor (x2.00)", near(M.getLossFactor("MAIZE", corn.max + 10), 2.00))
check("speed factor at max is 1 - maxSpeedReduction", near(M.getSpeedFactor("MAIZE", corn.max + 10), 0.65))
check("load penalty stays below loss penalty at max moisture", M.getLoadFactor("MAIZE", 99) < M.getLossFactor("MAIZE", 99))
local dryLoad = M.getLoadFactor("MAIZE", corn.target - 0.5)
check("dry crop: a mild bonus, never below 1 - dryBonusFactor", dryLoad < 1.0 and dryLoad >= 0.95, string.format("%.3f", dryLoad))
check("dry crop never RAISES the speed cap (upstream's vanilla ceiling)", M.getSpeedFactor("MAIZE", corn.target - 3) == 1.0)
local mid = (ceil + corn.max) / 2
check("mid-way: loss ramp (^1.5) is below the linear half", M.getLossFactor("MAIZE", mid) < 1.0 + (2.0 - 1.0) * 0.5)
check("no moisture reading -> neutral", M.getLoadFactor("MAIZE", 0) == 1.0 and M.getLossFactor("MAIZE", nil) == 1.0 and M.getSpeedFactor("MAIZE", -1) == 1.0)
local mono = true
local prev = 0
for m = 10, 40, 0.5 do local f = M.getLoadFactor("MAIZE", m); if f < prev - 1e-12 then mono = false end; prev = f end
check("load factor never decreases as moisture rises", mono)

print("=== 3. crop-name resolution ===")
local rice = M.getThresholds("RICE")
check("RICELONGGRAIN has its own thresholds, not wheat's", M.getThresholds("RICELONGGRAIN").target == rice.target and rice.target == 18.0)
check("RICE_LONG_GRAIN (upstream's database spelling) too", M.getThresholds("RICE_LONG_GRAIN").target == 18.0)
check("OATS resolves to oat", M.getThresholds("OATS") == M.getThresholds("OAT"))
check("an unlisted crop falls back to wheat", M.getThresholds("UNOBTANIUM") == M.CROP_THRESHOLDS.WHEAT)
check("...but has no EXPLICIT target", M.getExplicitTarget("UNOBTANIUM") == nil and M.getExplicitTarget("MAIZE") == 15.5)
check("nil crop falls back to wheat", M.getThresholds(nil) == M.CROP_THRESHOLDS.WHEAT)

print("=== 4. engine load: upstream's term off, the fork's factor on the specific energy ===")
S.enableMoisture = true
local c1 = calc("MAIZE")
c1:calculateEngineLoad(vehicle(30))
check("upstream's moisture switch was OFF during the calculation", UP.enableMoistureSeen.engine == false)
check("...and is restored afterwards", S.enableMoisture == true)
check("specific energy = upstream's 5.0 x the fork's load factor", near(c1.lastE, 5.0 * M.getLoadFactor("MAIZE", 30)), string.format("%.3f", c1.lastE))
c1:calculateEngineLoad(vehicle(0))
check("no moisture reading -> energy untouched", near(c1.lastE, 5.0))
local cf = calc("GRASS", "forage"); cf._machine = "forage"; cf:calculateEngineLoad(vehicle(40))
check("forage machine: untouched", near(cf.lastE, 5.0))
local cc = calc("MAIZE"); cc._forageCutter = true; cc:calculateEngineLoad(vehicle(40))
check("forage cutter on a grain machine: untouched", near(cc.lastE, 5.0))
M.enableLoad = false; c1:calculateEngineLoad(vehicle(30)); M.enableLoad = true
check("enableLoad=false in the XML -> untouched", near(c1.lastE, 5.0))
local ce = calc("MAIZE"); ce._explode = true
local ok, err = pcall(ce.calculateEngineLoad, ce, vehicle(30))
check("an error inside upstream propagates...", not ok and tostring(err):find("boom") ~= nil)
check("...and the switch is still restored", S.enableMoisture == true)

print("=== 5. the player's switch is the master ===")
S.enableMoisture = false
UP.enableMoistureSeen.engine = nil
local c2 = calc("MAIZE"); c2:calculateEngineLoad(vehicle(30))
check("moisture simulation OFF: energy untouched", near(c2.lastE, 5.0))
check("...and upstream's switch is left as the player set it", S.enableMoisture == false and UP.enableMoistureSeen.engine == false)
local l2 = calc("MAIZE"):calculateTotalCropLoss(vehicle(30))
check("moisture simulation OFF: loss untouched", near(l2, 4.0))
S.enableMoisture = true

print("=== 6. crop loss: upstream's moisture loss off, the fork's multiplier on the settings part ===")
local c3 = calc("MAIZE", "grain", { _settingsLoss = 2.0 })
local total = c3:calculateTotalCropLoss(vehicle(30))
local f = M.getLossFactor("MAIZE", 30)
check("upstream's moisture switch was OFF during the loss calculation", UP.enableMoistureSeen.loss == false and S.enableMoisture == true)
check("total = upstream 4.0 + settings loss 2.0 x (factor - 1)", near(total, 4.0 + 2.0 * (f - 1)), string.format("%.3f vs factor %.3f", total, f))
check("fields upstream's breakdown reads are updated", near(c3.moistureLoss, 2.0 * (f - 1)) and near(c3.cropLoss, total) and near(c3.totalLoss, total) and near(c3.totalCropLoss, total))
check("no settings loss -> nothing to scale", near(calc("MAIZE", "grain", { _settingsLoss = 0 }):calculateTotalCropLoss(vehicle(30)), 4.0))
check("no moisture reading -> untouched", near(calc("MAIZE"):calculateTotalCropLoss(vehicle(0)), 4.0))
check("forage machine: untouched", near(calc("GRASS", "forage"):calculateTotalCropLoss(vehicle(30)), 4.0))
check("total stays inside upstream's 50 % cap", calc("MAIZE", "grain", { _settingsLoss = 60 }):calculateTotalCropLoss(vehicle(99)) <= 50)
local dry = calc("MAIZE"):calculateTotalCropLoss(vehicle(corn.target - 0.5))
check("dry crop: a small loss bonus on the settings part", dry < 4.0 and dry >= 4.0 - 2.0 * 0.05 - 1e-9, string.format("%.3f", dry))
local cl = calc("MAIZE"); cl._explode = true
check("error inside upstream propagates, switch restored", not pcall(cl.calculateTotalCropLoss, cl, vehicle(30)) and S.enableMoisture == true)
M.enableLoss = false
check("enableLoss=false -> untouched", near(calc("MAIZE"):calculateTotalCropLoss(vehicle(30)), 4.0))
M.enableLoss = true

print("=== 7. speed: only ever lowers the ceiling ===")
local c4 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, genuineSpeedLimit = 10, _rawLimit = 15 })
c4:calculateSpeedLimit(vehicle(corn.max + 5))
check("wet at max: capped to min(ceiling) x 0.65", near(c4.speedLimit, 10 * 0.65), string.format("%.2f", c4.speedLimit))
local c5 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, genuineSpeedLimit = 10, _rawLimit = 5 })
c5:calculateSpeedLimit(vehicle(corn.max + 5))
check("a limit already below the cap is left alone", near(c5.speedLimit, 5))
local c6 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, _rawLimit = 15 }); c6:calculateSpeedLimit(vehicle(corn.max + 5))
check("without a genuine limit the work speed is the ceiling", near(c6.speedLimit, 12 * 0.65), string.format("%.2f", c6.speedLimit))
local c7 = calc("MAIZE", "grain", { maxWorkingSpeed = 4, _rawLimit = 15 }); c7:calculateSpeedLimit(vehicle(corn.max + 5))
check("never below upstream's 3.5 km/h floor", c7.speedLimit >= 3.5)
local c8 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, _rawLimit = math.huge }); c8:calculateSpeedLimit(vehicle(corn.max + 5))
check("an unlimited speed limit (arcade / tier gate) is left alone", c8.speedLimit == math.huge)
local c9 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, _rawLimit = 15 }); c9:calculateSpeedLimit(vehicle(corn.target))
check("dry or on-target crop: not lowered", near(c9.speedLimit, 15))
local c10 = calc("GRASS", "forage", { maxWorkingSpeed = 12, _rawLimit = 15 }); c10:calculateSpeedLimit(vehicle(40))
check("forage machine: untouched", near(c10.speedLimit, 15))
M.enableSpeed = false
local c11 = calc("MAIZE", "grain", { maxWorkingSpeed = 12, _rawLimit = 15 }); c11:calculateSpeedLimit(vehicle(40))
M.enableSpeed = true
check("enableSpeed=false -> untouched", near(c11.speedLimit, 15))

print("=== 8. live optimal-setting shift is measured from the crop's own target ===")
local db = setmetatable({}, { __index = RHM_CombineSettingsDatabase })
local tpl = { moistureLimit = 99 }
local r = db:applyEnvironmentalOffsets(tpl, { machineType = "grain", moisture = 20 }, "MAIZE")
check("upstream saw the corn target as the reference", UP.templateLimitSeen == 15.5)
check("...the template is restored afterwards", tpl.moistureLimit == 99)
check("...and the returned copy carries the target", r.copiedLimit == 15.5)
db:applyEnvironmentalOffsets(tpl, { machineType = "forage", moisture = 20 }, "MAIZE")
check("forage context: upstream's reference untouched", UP.templateLimitSeen == 99)
db:applyEnvironmentalOffsets(tpl, { machineType = "grain", moisture = 20 }, "UNOBTANIUM")
check("unlisted crop: upstream's reference untouched", UP.templateLimitSeen == 99)
S.enableMoisture = false
db:applyEnvironmentalOffsets(tpl, { machineType = "grain", moisture = 20 }, "MAIZE")
S.enableMoisture = true
check("moisture simulation off: upstream's reference untouched", UP.templateLimitSeen == 99)
db._explode = true
local ok2 = pcall(db.applyEnvironmentalOffsets, db, tpl, { machineType = "grain" }, "MAIZE")
db._explode = nil
check("error inside upstream propagates, template restored", not ok2 and tpl.moistureLimit == 99)
check("no template: passes straight through", (pcall(db.applyEnvironmentalOffsets, db, nil, { machineType = "grain" }, "MAIZE")))

print("=== 9. public API reports the target ===")
check("getMoistureLimit -> corn target", RHM_Api.getMoistureLimit({ _crop = "MAIZE" }) == 15.5)
check("unlisted crop -> upstream's answer", RHM_Api.getMoistureLimit({ _crop = "UNOBTANIUM" }) == 14.0)

print("=== 10. reload restores the file's values ===")
M.CROP_THRESHOLDS.WHEAT = { target = 1, max = 2 }; M.maxLossFactor = 9
RealThroughputConfig.load()
check("a reload drops stale in-memory changes", M.getThresholds("WHEAT").target == 13.5 and M.maxLossFactor == 2.00)

print("=== 11. every crop that has a throughput anchor also has moisture thresholds ===")
do
    local missing = {}
    for name in pairs(RealThroughputConfig._grain) do
        if M.getExplicitTarget(name) == nil then missing[#missing + 1] = name end
    end
    table.sort(missing)
    check("no anchored grain crop silently falls back to wheat", #missing == 0, #missing > 0 and ("falls back: " .. table.concat(missing, ", ")) or "")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
