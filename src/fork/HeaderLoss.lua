-- EN: Ground-speed header loss - the fork's third loss source, folded into upstream's crop-loss total
--     WITHOUT editing upstream's files.
--
--     Driving a grain header fast shatters pods and heads and knocks kernels off at the cutterbar, before
--     anything reaches the threshing system. Upstream's losses cover overload, settings, moisture, wear and
--     slope; none of them depends on ground speed as such, so a machine held at a good engine load in a light
--     crop can run fast and lose nothing at the header. This adds it, as in the fork:
--
--         loss % = (speed - 9.65 km/h) ^ 1.35 x 0.28 x cropFactor        capped at 8 %
--
--     9.65 km/h is 6 mph. The crop factor is the susceptibility to shatter: canola 2.0, soybean 1.8, pea 1.7 ...
--     wheat and barley 1.0, sorghum 0.8, corn 0.25.
--
--     It is added to upstream's total (still capped at upstream's 50 %) and to its "speed" bucket (baseLoss), which
--     is what upstream's loss breakdown, harvest tracker and history analytics report as speed loss, so lost grain
--     is attributed to speed everywhere. Because upstream removes grain from the tank by the total, the loss is
--     physical, not just displayed.
--
--     Same gating as upstream's own loss: nothing when crop loss is disabled or the loss difficulty is Arcade;
--     grain machines only; and nothing in Training mode (that sandbox suppresses all loss physics).
--
-- UA: Втрати від швидкості на жатці - третє джерело втрат форку, додане до загальних втрат оригіналу БЕЗ правок
--     його файлів. Швидка їзда з жаткою обсипає стручки й кошики ще до молотарки. Втрати = (швидкість - 9.65 км/год)
--     ^ 1.35 x 0.28 x коефіцієнт культури, максимум 8 %. Додаються до загальних втрат і до категорії "швидкість".
HeaderLoss = {}

HeaderLoss.enabled       = true
HeaderLoss.THRESHOLD_KMH = 9.65        -- 6 mph
HeaderLoss.EXPONENT      = 1.35
HeaderLoss.SCALE         = 0.28
HeaderLoss.CAP           = 8.0         -- percent

-- EN: Susceptibility to shatter at the header, by crop (lower-case; substring match, longest key first).
--     The first block is the fork's own table. "maize" is the same crop as its "corn". The last block is
--     added by the port for the crops given anchors - judgment calls in the same spirit; others use 1.0.
-- UA: Схильність до осипання на жатці. Перший блок - таблиця форку; останній додано для нових культур.
HeaderLoss.CROP_FACTORS = {
    canola = 2.0, soybean = 1.8, pea = 1.7, lentil = 1.6, chickpea = 1.5, sunflower = 1.5,
    oat = 1.2, rice = 1.1, wheat = 1.0, barley = 1.0, sorghum = 0.8, corn = 0.25, maize = 0.25,
    mustard = 2.0, beans = 1.8, bean = 1.8, linseed = 1.4, flax = 1.4, buckwheat = 1.4,
}

local order = {}
local function rebuildOrder()
    order = {}
    for k in pairs(HeaderLoss.CROP_FACTORS) do order[#order + 1] = k end
    table.sort(order, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b                      -- stable tiebreak, independent of hash layout
    end)
end
rebuildOrder()

function HeaderLoss.cropFactor(cropName)
    if not cropName then return 1.0 end
    local key = tostring(cropName):lower()
    local exact = HeaderLoss.CROP_FACTORS[key]
    if exact then return exact end
    for _, k in ipairs(order) do
        if key:find(k, 1, true) then return HeaderLoss.CROP_FACTORS[k] end
    end
    return 1.0
end

-- EN: Pure: loss in percent for a crop at a ground speed.
function HeaderLoss.compute(cropName, speedKmh)
    if not speedKmh or speedKmh <= HeaderLoss.THRESHOLD_KMH then return 0 end
    local raw = ((speedKmh - HeaderLoss.THRESHOLD_KMH) ^ HeaderLoss.EXPONENT) * HeaderLoss.SCALE * HeaderLoss.cropFactor(cropName)
    return math.min(HeaderLoss.CAP, raw)
end

-- ============================================================================
-- EN: Hook - outside upstream's loss total and outside the moisture model, so the header loss is a plain
--     addition that moisture does not scale.
-- UA: Хук - поза загальними втратами та моделлю вологості, тож втрати від жатки додаються і не масштабуються вологістю.
-- ============================================================================
local function lossActive()
    local s = g_realisticHarvestManager and g_realisticHarvestManager.settings
    if not s then return false end
    return s.enableCropLoss ~= false and s.difficultyLoss ~= 1
end

local orig = RHM_LoadCalculator and RHM_LoadCalculator.calculateTotalCropLoss
if type(orig) ~= "function" then
    Logging.warning("[RHM-fork] HeaderLoss: RHM_LoadCalculator.calculateTotalCropLoss not found - header loss inactive")
else
    RHM_LoadCalculator.calculateTotalCropLoss = function(self, vehicle)
        local total = orig(self, vehicle)
        self.headerLoss = 0

        if not HeaderLoss.enabled or not lossActive() then return total end
        if TrainingMode and TrainingMode.suppressLossPhysics and TrainingMode.suppressLossPhysics() then return total end
        if ((self.combineMemory and self.combineMemory.machineType) or "grain") ~= "grain" then return total end
        if not (vehicle and vehicle.getLastSpeed) then return total end

        local crop = self.currentCrop or (self.combineMemory and self.combineMemory.currentCrop)
        local loss = HeaderLoss.compute(crop, vehicle:getLastSpeed())
        self.headerLoss = loss
        if loss <= 0 then return total end

        local newTotal = math.min(50, total + loss)
        self.baseLoss = (self.baseLoss or 0) + loss          -- upstream's "speed" bucket
        self.overloadLoss = self.baseLoss
        self.totalLoss, self.totalCropLoss, self.cropLoss = newTotal, newTotal, newTotal
        return newTotal
    end
end

-- ============================================================================
-- EN: Console
-- UA: Консоль
-- ============================================================================
function HeaderLoss.consoleCommand(_, arg)
    local a = arg and tostring(arg):lower() or ""
    if a == "on" or a == "1" then HeaderLoss.enabled = true
    elseif a == "off" or a == "0" then HeaderLoss.enabled = false
    elseif a ~= "" and a ~= "status" then return "Usage: rhmHeaderLoss [on|off|status]" end

    local out = string.format("Header loss: %s (over %.1f km/h, cap %.0f %%)",
        HeaderLoss.enabled and "ON" or "OFF", HeaderLoss.THRESHOLD_KMH, HeaderLoss.CAP)
    local veh = g_realisticHarvestManager and g_realisticHarvestManager.lastActiveCombine
    local calc = veh and veh.spec_rhm_Combine and veh.spec_rhm_Combine.loadCalculator
    if calc then
        out = out .. string.format("\n  active machine: %.2f %% now", calc.headerLoss or 0)
    end
    return out
end

if RHM_RealisticHarvestManager and type(RHM_RealisticHarvestManager.new) == "function" then
    local origNew = RHM_RealisticHarvestManager.new
    RHM_RealisticHarvestManager.new = function(...)
        local self = origNew(...)
        addConsoleCommand("rhmHeaderLoss", "rhmHeaderLoss [on|off|status] - ground-speed header loss",
            "consoleCommand", HeaderLoss)
        return self
    end
end
