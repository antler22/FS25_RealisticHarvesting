-- EN: The fork's moisture model, replacing upstream's moisture effects WITHOUT editing upstream's files.
--
--     The model (carried over from the fork's MoistureCalculator, unchanged in behaviour):
--       - per-crop harvest moisture TARGET and MAX (USDA / industry figures), in the <moistureSettings>
--         block of cropThroughput.xml;
--       - a 1.5-point dead band above target where nothing happens;
--       - three independent effects, each with its own enable flag:
--           load   x1.00 -> x1.30 at max moisture   (wet crop is harder to thresh)  linear
--           loss   x1.00 -> x2.00 at max moisture   (wet grain separates badly)      ^1.5 curve
--           speed  x1.00 -> x0.65 at max moisture   (wet standing crop resists the header)  linear
--       - a slight bonus (up to 5 %) when the crop is drier than target.
--     The factors are ABSOLUTE multipliers: 1.30 means "x1.30 at max moisture", not "+130 %".
--
--     Upstream has its own moisture handling - a flat 14 % default limit with a per-percent penalty
--     in the engine-load and crop-loss calculations, a halved penalty at package level 4, and a
--     rain surcharge. Both cannot act at once, so for the duration of those two calculations
--     upstream's own switch (settings.enableMoisture) is held off and the fork's factors are
--     applied instead, at the matching points:
--       load   -> multiplies the crop's specific energy (RHM_LoadCalculator:getCropSpecificEnergy)
--       loss   -> scales the settings-driven part of the loss (calculateTotalCropLoss)
--       speed  -> caps the speed controller's ceiling (calculateSpeedLimit)
--       optimum-> the live optimal-setting shift is measured from the crop's target, not upstream's
--                 template limit (RHM_CombineSettingsDatabase:applyEnvironmentalOffsets)
--     The player's "Moisture simulation" setting stays the master switch for all of it. Grain
--     machines only, as in the fork; forage, root and specialty machines keep upstream's behaviour.
--
--     Not carried over because upstream's HUD draws it inline: moisture colouring. The cab HUD keeps
--     upstream's fixed bands (blue to 14 %, amber to 20 %, red above).
--
-- UA: Модель вологості форку замість ефектів вологості оригіналу, БЕЗ правок його файлів. Цільова та
--     максимальна вологість по культурах, мертва зона 1.5 п.п., три незалежні ефекти (навантаження
--     x1.30, втрати x2.00, обмеження швидкості -35 % при максимумі) і невеликий бонус для сухої культури.
--     Власні ефекти оригіналу вимикаються на час відповідних розрахунків його ж перемикачем.
MoistureModel = {}

-- ---------------------------------------------------------------------------
-- EN: Built-in thresholds (USDA / industry harvest moisture, %). XML overrides them per crop.
-- UA: Вбудовані пороги вологості. XML перевизначає їх для кожної культури.
-- ---------------------------------------------------------------------------
local DEFAULT_THRESHOLDS = {
    WHEAT = { target = 13.5, max = 22.0 }, BARLEY = { target = 13.5, max = 20.0 }, OAT = { target = 13.0, max = 20.0 },
    RYE = { target = 13.5, max = 20.0 }, SPELT = { target = 13.5, max = 20.0 }, TRITICALE = { target = 13.5, max = 20.0 },
    MILLET = { target = 13.0, max = 18.0 },                       -- small-seeded, shatters above 18 %
    MAIZE = { target = 15.5, max = 35.0 }, CORN = { target = 15.5, max = 35.0 },
    SORGHUM = { target = 14.0, max = 28.0 },
    SOYBEAN = { target = 13.0, max = 22.0 }, CANOLA = { target = 9.0, max = 20.0 }, SUNFLOWER = { target = 9.0, max = 20.0 },
    -- The engine spells the fill type RICELONGGRAIN; upstream's database calls the crop RICE_LONG_GRAIN.
    -- Both must be present or long-grain rice falls back to wheat and reads "wet" at its normal 18 %.
    RICE = { target = 18.0, max = 26.0 }, RICELONGGRAIN = { target = 18.0, max = 26.0 }, RICE_LONG_GRAIN = { target = 18.0, max = 26.0 },
    PEA = { target = 13.0, max = 18.0 },
    LENTIL = { target = 13.0, max = 16.0 },                       -- very fragile
    CHICKPEA = { target = 13.0, max = 16.0 },                     -- cracks badly above 16 %
    COTTON = { target = 8.0, max = 14.0 },
    -- Added by the port for the crops given anchors in cropThroughput.xml. Typical safe-harvest figures,
    -- judgment calls like those anchors; without an entry a crop falls back to wheat's thresholds.
    BUCKWHEAT = { target = 16.0, max = 22.0 }, LINSEED = { target = 9.0, max = 14.0 }, FLAX = { target = 9.0, max = 14.0 },
    MUSTARD = { target = 9.0, max = 14.0 }, SAFFLOWER = { target = 8.0, max = 14.0 }, POPPY = { target = 8.0, max = 14.0 },
    HEMP = { target = 12.0, max = 20.0 }, GRASS_SEED = { target = 12.0, max = 20.0 }, CLOVER = { target = 12.0, max = 18.0 },
    BEANS = { target = 15.0, max = 22.0 }, BEAN = { target = 15.0, max = 22.0 },
}

-- EN: Names that mean the same crop; tried only when the name itself is not listed.
local ALIASES = {
    OATS = "OAT", PEAS = "PEA", CORN = "MAIZE", MAIZE = "CORN",
    RICELONGGRAIN = "RICE_LONG_GRAIN", RICE_LONG_GRAIN = "RICELONGGRAIN",
    FLAX = "LINSEED", LINSEED = "FLAX", GRASSSEED = "GRASS_SEED",
}

local function copyThresholds()
    local t = {}
    for k, v in pairs(DEFAULT_THRESHOLDS) do t[k] = { target = v.target, max = v.max } end
    return t
end

MoistureModel.CROP_THRESHOLDS = copyThresholds()
MoistureModel.enableLoad  = true
MoistureModel.enableLoss  = true
MoistureModel.enableSpeed = true
MoistureModel.maxLoadFactor     = 1.30
MoistureModel.maxLossFactor     = 2.00
MoistureModel.maxSpeedReduction = 0.35
MoistureModel.dryBonusFactor    = 0.05
MoistureModel.DEADBAND = 1.5          -- percentage points above target where nothing happens

-- ---------------------------------------------------------------------------
-- EN: Lookup. The XML is read lazily, on first use, so main.lua needs no hook.
-- UA: Пошук. XML читається ліниво, під час першого використання.
-- ---------------------------------------------------------------------------
function MoistureModel.ensureLoaded()
    if RealThroughputConfig and not RealThroughputConfig._loaded then
        RealThroughputConfig.load()      -- calls MoistureModel.loadFromXML while the file is open
    end
end

local function findEntry(name)
    if not name then return nil end
    local key = tostring(name):upper()
    local t = MoistureModel.CROP_THRESHOLDS
    local bare = key:gsub("_", "")
    for _, c in ipairs({ key, bare }) do
        if t[c] then return t[c] end
    end
    for _, c in ipairs({ key, bare }) do
        local alias = ALIASES[c]
        if alias and t[alias] then return t[alias] end
    end
    return nil
end

-- EN: Thresholds for a crop; wheat's if it is not listed (the fork's behaviour).
function MoistureModel.getThresholds(cropName)
    MoistureModel.ensureLoaded()
    return findEntry(cropName) or MoistureModel.CROP_THRESHOLDS.WHEAT
end

-- EN: The crop's own target, or nil when the crop has no entry of its own.
function MoistureModel.getExplicitTarget(cropName)
    MoistureModel.ensureLoaded()
    local e = findEntry(cropName)
    return e and e.target or nil
end

-- 0 = at the end of the dead band, 1 = at max, negative = below target (dry).
local function moistureRatio(moisture, t)
    return (moisture - (t.target + MoistureModel.DEADBAND)) / math.max(0.1, t.max - t.target)
end

local function dryRatio(ratio) return math.min(1.0, -ratio) end

function MoistureModel.getLoadFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local ratio = moistureRatio(moisture, MoistureModel.getThresholds(cropName))
    if ratio <= 0 then
        return math.max(1.0 - MoistureModel.dryBonusFactor, 1.0 - MoistureModel.dryBonusFactor * dryRatio(ratio))
    end
    return 1.0 + (MoistureModel.maxLoadFactor - 1.0) * math.min(1.0, ratio)
end

function MoistureModel.getLossFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local ratio = moistureRatio(moisture, MoistureModel.getThresholds(cropName))
    if ratio <= 0 then
        return math.max(1.0 - MoistureModel.dryBonusFactor, 1.0 - MoistureModel.dryBonusFactor * dryRatio(ratio))
    end
    return 1.0 + (MoistureModel.maxLossFactor - 1.0) * (math.min(1.0, ratio) ^ 1.5)
end

-- EN: Speed-cap multiplier. The fork let a very dry crop raise the cap by up to 5 %; this layer only
--     ever applies reductions, because upstream never lets the cap exceed the vanilla game limit.
function MoistureModel.getSpeedFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local ratio = moistureRatio(moisture, MoistureModel.getThresholds(cropName))
    if ratio <= 0 then return 1.0 end
    return math.max(1.0 - MoistureModel.maxSpeedReduction, 1.0 - MoistureModel.maxSpeedReduction * math.min(1.0, ratio))
end

-- ---------------------------------------------------------------------------
-- EN: XML (<moistureSettings> inside cropThroughput.xml). Called by RealThroughputConfig.load while
--     the file is open. Resets to the built-in defaults first so a reload never keeps stale overrides.
-- UA: XML (<moistureSettings>). Спочатку скидає до вбудованих значень, щоб перезавантаження не лишало старих.
-- ---------------------------------------------------------------------------
function MoistureModel.loadFromXML(xmlFile)
    local M = MoistureModel
    M.CROP_THRESHOLDS = copyThresholds()
    M.enableLoad, M.enableLoss, M.enableSpeed = true, true, true
    M.maxLoadFactor, M.maxLossFactor, M.maxSpeedReduction, M.dryBonusFactor = 1.30, 2.00, 0.35, 0.05
    if not xmlFile then return end

    local base = "cropThroughput.moistureSettings"
    if not hasXMLProperty(xmlFile, base) then return end

    local enLoad, enLoss, enSpeed = getXMLBool(xmlFile, base .. "#enableLoad"), getXMLBool(xmlFile, base .. "#enableLoss"), getXMLBool(xmlFile, base .. "#enableSpeed")
    if enLoad  ~= nil then M.enableLoad  = enLoad  end
    if enLoss  ~= nil then M.enableLoss  = enLoss  end
    if enSpeed ~= nil then M.enableSpeed = enSpeed end

    local mxLoad, mxLoss = getXMLFloat(xmlFile, base .. "#maxLoadFactor"), getXMLFloat(xmlFile, base .. "#maxLossFactor")
    local mxSpeed, dry = getXMLFloat(xmlFile, base .. "#maxSpeedReduction"), getXMLFloat(xmlFile, base .. "#dryBonusFactor")
    if mxLoad  and mxLoad  > 0  then M.maxLoadFactor     = mxLoad  end
    if mxLoss  and mxLoss  > 0  then M.maxLossFactor     = mxLoss  end
    if mxSpeed and mxSpeed >= 0 then M.maxSpeedReduction = mxSpeed end
    if dry     and dry     >= 0 then M.dryBonusFactor    = dry     end

    local i = 0
    while true do
        local key = string.format("%s.crop(%d)", base, i)
        if not hasXMLProperty(xmlFile, key) then break end
        local name, target, maxVal = getXMLString(xmlFile, key .. "#name"), getXMLFloat(xmlFile, key .. "#target"), getXMLFloat(xmlFile, key .. "#max")
        if name and target and maxVal and maxVal > target then
            M.CROP_THRESHOLDS[name:upper()] = { target = target, max = maxVal }
        end
        i = i + 1
    end
end

-- ============================================================================
-- EN: Hooks
-- UA: Хуки
-- ============================================================================

local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] MoistureModel: %s.%s not found - that moisture effect is inactive", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end

local function settings() return g_realisticHarvestManager and g_realisticHarvestManager.settings end

-- EN: The player's "Moisture simulation" setting is the master switch.
function MoistureModel.isEnabled()
    local s = settings()
    return not s or s.enableMoisture ~= false
end

-- EN: Run fn with upstream's own moisture handling switched off, restoring the setting even if fn
--     throws. Upstream reads the switch only inside the two calculations this wraps.
-- UA: Виконує fn з вимкненою власною обробкою вологості оригіналу; налаштування відновлюється навіть при помилці.
function MoistureModel.callWithUpstreamMoistureOff(fn, ...)
    local s = settings()
    if not s or s.enableMoisture == false then return fn(...) end
    local previous = s.enableMoisture
    s.enableMoisture = false
    local ok, a, b, c = pcall(fn, ...)
    s.enableMoisture = previous
    if not ok then error(a, 0) end
    return a, b, c
end

-- EN: Grain moisture (%) and crop for a vehicle, from the same live values upstream's HUD shows.
local function readMoisture(calc, vehicle)
    local spec = vehicle and vehicle.spec_rhm_Combine
    local m = spec and spec.data and spec.data.moisture
    if not m or m <= 0 then m = calc.currentMoisture end
    return m or 0
end

local function currentCrop(calc)
    return calc.currentCrop or (calc.combineMemory and calc.combineMemory.currentCrop)
end

local function isGrain(calc)
    return ((calc.combineMemory and calc.combineMemory.machineType) or "grain") == "grain"
end

if RHM_LoadCalculator then
    -- 1. Engine load: upstream's term off; the fork's factor goes onto the specific energy.
    wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "calculateEngineLoad", function(orig, self, vehicle)
        self._moistVehicle = vehicle
        self._moistActive = MoistureModel.isEnabled()
        return MoistureModel.callWithUpstreamMoistureOff(orig, self, vehicle)
    end)

    wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "getCropSpecificEnergy",
        function(orig, self, fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
            local e = orig(self, fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
            if not (self._moistActive and MoistureModel.enableLoad) then return e end
            if (machineType or "grain") ~= "grain" or isForageCutter then return e end
            local m = readMoisture(self, self._moistVehicle)
            if m <= 0 then return e end
            return e * MoistureModel.getLoadFactor(currentCrop(self), m)
        end)

    -- 2. Crop loss: upstream's moisture loss off; the fork's multiplier scales the settings-driven part.
    wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "calculateTotalCropLoss", function(orig, self, vehicle)
        local active = MoistureModel.isEnabled()
        local total = MoistureModel.callWithUpstreamMoistureOff(orig, self, vehicle)
        if not (active and MoistureModel.enableLoss and isGrain(self)) then return total end

        local base = self.settingsAddedLoss or 0
        if base <= 0 then return total end
        local m = readMoisture(self, vehicle)
        if m <= 0 then return total end

        local extra = base * (MoistureModel.getLossFactor(currentCrop(self), m) - 1.0)
        local newTotal = math.min(50, math.max(0, total + extra))
        self.moistureLoss = math.max(0, extra)          -- shows in upstream's loss breakdown
        self.totalLoss, self.totalCropLoss, self.cropLoss = newTotal, newTotal, newTotal
        return newTotal
    end)

    -- 3. Speed: cap the controller's ceiling. Only ever lowers the limit.
    wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "calculateSpeedLimit", function(orig, self, vehicle)
        local r = orig(self, vehicle)
        if not (MoistureModel.isEnabled() and MoistureModel.enableSpeed and isGrain(self)) then return r end
        local limit = self.speedLimit
        if not limit or limit == math.huge then return r end
        local m = readMoisture(self, vehicle)
        if m <= 0 then return r end

        local factor = MoistureModel.getSpeedFactor(currentCrop(self), m)
        if factor >= 1.0 then return r end
        local ceiling = self.maxWorkingSpeed or 10.0
        if self.genuineSpeedLimit and self.genuineSpeedLimit > 0 then ceiling = math.min(ceiling, self.genuineSpeedLimit) end
        local cap = math.max(3.5, ceiling * factor)
        if limit > cap then self.speedLimit = cap end
        return r
    end)
end

-- 4. Live optimal-setting shift: measure moisture from the crop's own target. Upstream reads the
--    reference from the template it is handed; hand it ours for the duration of the call.
if RHM_CombineSettingsDatabase then
    wrapMethod(RHM_CombineSettingsDatabase, "RHM_CombineSettingsDatabase", "applyEnvironmentalOffsets",
        function(orig, self, baseTemplate, context, cropName)
            local target = MoistureModel.isEnabled() and MoistureModel.getExplicitTarget(cropName) or nil
            local machine = (context and context.machineType) or "grain"
            if not (target and baseTemplate and machine == "grain") then
                return orig(self, baseTemplate, context, cropName)
            end
            local previous = baseTemplate.moistureLimit
            baseTemplate.moistureLimit = target
            local ok, result = pcall(orig, self, baseTemplate, context, cropName)
            baseTemplate.moistureLimit = previous
            if not ok then error(result, 0) end
            return result
        end)
end

-- 5. Public API: report the crop's target as its moisture limit.
if RHM_Api and type(RHM_Api.getMoistureLimit) == "function" then
    local origLimit = RHM_Api.getMoistureLimit
    RHM_Api.getMoistureLimit = function(vehicle)
        local combine = RHM_Api.findCombine and RHM_Api.findCombine(vehicle)
        local crop = combine and RHM_Api.getCurrentCrop and RHM_Api.getCurrentCrop(combine)
        local target = MoistureModel.isEnabled() and crop and MoistureModel.getExplicitTarget(crop)
        return target or origLimit(vehicle)
    end
end
