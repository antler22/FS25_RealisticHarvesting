-- EN: Real-throughput overlay. Imposes the fork's real-world throughput anchors on upstream's
--     power-balance model WITHOUT editing upstream's files.
--
--     How upstream decides what a machine can swallow
--     Upstream's engine load is a horsepower balance:  P_total = P_base + P_header + P_process,
--     with P_process = tons/hour x E, where E is the crop's specific energy (HP per t/h) from
--     RHM_LoadCalculator:getCropSpecificEnergy. Its speed controller then solves for the ground
--     speed that holds a target engine load from that same balance. So E is the single number
--     that fixes a machine's capacity, and upstream's E is a per-crop CONSTANT: capacity scales
--     linearly with horsepower and a Class 6 and a Class 11 convert HP into grain identically.
--
--     What this overlay changes
--     For crops that cropThroughput.xml anchors, E is derived from the anchor instead:
--
--         E = (1 - base - headerRef) x HP / tph_rated(HP, crop)        tph_rated = A x HP^B
--
--     i.e. exactly the energy that makes a CLASS-MATCHED machine read 100 % engine load at its
--     rated throughput. A header that draws more than the class reference pushes the gauge past
--     100 % at rated throughput and the speed controller backs off (the oversized-header effect);
--     a lighter header leaves headroom. Because B > 1 for most crops, big machines are
--     proportionally more productive per horsepower than small ones - the property the anchors
--     exist to encode. Everything downstream (load gauge, speed equilibrium, overload loss,
--     moisture penalties, tier effects) is upstream's own code reading a different E.
--
--     What is left alone
--       * Crops with no anchor, and root / cotton / grape / olive machines: upstream's E, unchanged.
--       * Grain combines on a windrow pickup: upstream's E.
--       * Upstream's yield adaptation (harvest-index curve). It is extracted by calling upstream's
--         own function twice (with and without the live yield), so it cannot drift from it.
--
--     Hook points (verified against upstream v1.6.4.0):
--       RHM_LoadCalculator:calculateEngineLoad   - records which vehicle the tick is for
--       RHM_LoadCalculator:getCropSpecificEnergy - the capacity seam; has no vehicle argument
--
--     Runtime switch for A/B comparison against upstream's native model:  rhmRealThroughput on|off|status
--
-- UA: Накладка реальної продуктивності. Накладає реальні опорні точки форку на баланс потужностей
--     оригіналу БЕЗ правок його файлів. Питома енергія E (к.с. на т/год) — єдине число, що задає
--     пропускну здатність машини в оригіналі; для культур з опорними точками E виводиться з них:
--     це та енергія, за якої машина з жаткою свого класу показує 100 % навантаження на рейтинговій
--     продуктивності. Без опорних точок і для не-зернових/не-форажних машин E оригіналу не чіпаємо.
RealThroughput = {}

RealThroughput.enabled = true

-- EN: Share of rated power a CLASS-MATCHED header takes at working speed. Linear between a
--     Class 5 (250 hp, ~30 %) and a Class 11 (775 hp, ~15 %), clamped outside. It fixes what
--     "100 % engine load" means: with a matched header, rated throughput reads 100 %.
-- UA: Частка потужності, яку бере жатка свого класу на робочій швидкості. Лінійно між 250 к.с.
--     (~30 %) та 775 к.с. (~15 %). Визначає, що означає "100 %" на індикаторі.
RealThroughput.HEADER_REF_HP_LOW,  RealThroughput.HEADER_REF_FRAC_LOW  = 250.0, 0.30
RealThroughput.HEADER_REF_HP_HIGH, RealThroughput.HEADER_REF_FRAC_HIGH = 775.0, 0.15

-- EN: Sanity window for the derived E (HP per t/h). Upstream's own constants span 1.65 (carrots)
--     to 55 (cotton); a typo in cropThroughput.xml should not be able to produce a machine that
--     swallows a field in a second or one that cannot move. Outside the window the overlay
--     steps aside and upstream's E is used.
-- UA: Розумні межі для E. Опечатка в XML не повинна давати нереальну машину; поза межами
--     накладка поступається значенню оригіналу.
RealThroughput.E_MIN, RealThroughput.E_MAX = 0.5, 60.0

local LBS_PER_KG = 2.20462

function RealThroughput.headerRefFraction(hp)
    local h0, f0 = RealThroughput.HEADER_REF_HP_LOW,  RealThroughput.HEADER_REF_FRAC_LOW
    local h1, f1 = RealThroughput.HEADER_REF_HP_HIGH, RealThroughput.HEADER_REF_FRAC_HIGH
    local t = ((hp or h0) - h0) / (h1 - h0)
    t = math.max(0.0, math.min(1.0, t))
    return f0 + (f1 - f0) * t
end

-- EN: Mirrors the base-loss fractions upstream uses for P_base in calculateEngineLoad (v1.6.4.0).
--     The derived E is only exact if both sides use the same fraction, so this must track it.
-- UA: Дзеркалить частки базових втрат P_base з calculateEngineLoad оригіналу. E точний лише
--     за однакових часток, тож це має слідувати за оригіналом.
function RealThroughput.baseLossFraction(calc, vehicle, machineType)
    local rhmSpec = vehicle and vehicle.spec_rhm_Combine
    local threshType = (calc and calc.threshingType) or (rhmSpec and rhmSpec.threshingType) or "walker"
    if machineType == "root" then return 0.10 end
    if machineType == "forage" then return 0.09 end
    if machineType == "grain" then
        if threshType == "rotor" then return 0.11 end
        if threshType == "hybrid" then return 0.095 end
        return 0.08
    end
    return 0.08
end

-- EN: Pure function: the specific energy (HP per t/h) at which a machine reads 100 % engine load
--     when it is processing exactly its rated throughput.
-- UA: Чиста функція: питома енергія, за якої машина на рейтинговій продуктивності показує 100 %.
function RealThroughput.processingEnergy(ratedKgPerSec, hp, baseFrac, headerHp)
    local tphRated = math.max(0.1, ratedKgPerSec * 3.6)
    local headerRef = math.min(RealThroughput.headerRefFraction(hp), (headerHp or 0) / hp)
    local available = math.max(0.05, 1.0 - baseFrac - headerRef)
    return available * hp / tphRated
end

-- EN: Same name resolution upstream uses: fruit type, else fill type, else the tracked crop.
local function resolveCropName(calc, fruitTypeIndex, fillTypeIndex)
    if g_fruitTypeManager and fruitTypeIndex and fruitTypeIndex ~= 0
        and (FruitType == nil or fruitTypeIndex ~= FruitType.UNKNOWN) then
        local d = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        if d and d.name then return d.name end
    end
    if g_fillTypeManager and fillTypeIndex and fillTypeIndex ~= 0
        and (FillType == nil or fillTypeIndex ~= FillType.UNKNOWN) then
        local d = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if d and d.name then return d.name end
    end
    return calc.currentCrop
end

-- ============================================================================
-- EN: Hooks
-- UA: Хуки
-- ============================================================================

local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] RealThroughput: %s.%s not found — overlay inactive", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end

-- EN: getCropSpecificEnergy takes no vehicle, but the derivation needs the engine's horsepower
--     and the attached header's draw. calculateEngineLoad has the vehicle and calls
--     getCropSpecificEnergy synchronously after it has set self.headerHp, so it is stashed here.
-- UA: getCropSpecificEnergy не отримує машину, а виведенню потрібні к.с. двигуна та жатка.
--     calculateEngineLoad має машину і викликає її синхронно — запам'ятовуємо тут.
wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "calculateEngineLoad", function(orig, self, vehicle)
    self._rtVehicle = vehicle
    return orig(self, vehicle)
end)

wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "getCropSpecificEnergy",
    function(orig, self, fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
        local eUpstream = orig(self, fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
        if not RealThroughput.enabled then return eUpstream end

        local vehicle = self._rtVehicle
        if not vehicle then return eUpstream end

        local mt = machineType or "grain"
        local isForage = (mt == "forage") or (isForageCutter == true)
        if not isForage and (mt ~= "grain" or isPickup) then return eUpstream end

        local cropName = resolveCropName(self, fruitTypeIndex, fillTypeIndex)
        local curve = isForage and RealThroughputConfig.getForageCurve(cropName)
                                or RealThroughputConfig.getGrainCurve(cropName)
        if not curve then return eUpstream end

        local hp = self:getEnginePowerHp(vehicle)
        if not hp or hp <= 0 then return eUpstream end

        local rated = RealThroughputConfig.curveKgPerSec(curve, hp)
        local baseFrac = RealThroughput.baseLossFraction(self, vehicle, mt)
        local eAnchor = RealThroughput.processingEnergy(rated, hp, baseFrac, self.headerHp)
        if eAnchor ~= eAnchor or eAnchor < RealThroughput.E_MIN or eAnchor > RealThroughput.E_MAX then
            return eUpstream
        end

        -- EN: Recover upstream's yield adaptation. With no live yield it falls back to the crop's
        --     reference yield, so the factor is exactly 1.0 and orig() returns the bare constant;
        --     the ratio of the two calls is therefore upstream's factor, whatever its formula.
        -- UA: Відновлюємо адаптацію до врожайності оригіналу: без живої врожайності множник
        --     дорівнює 1.0, тож відношення двох викликів — це множник оригіналу.
        local liveYield = self.currentYield
        self.currentYield = 0
        local eBare = orig(self, fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
        self.currentYield = liveYield
        local yieldFactor = (eBare and eBare > 0) and (eUpstream / eBare) or 1.0
        yieldFactor = math.max(0.3, math.min(1.5, yieldFactor))

        local e = eAnchor * yieldFactor

        -- EN: Remember what was applied, for the status command, and log when it changes.
        local last = self._rtLast
        if rhm_log and (not last or last.crop ~= cropName or last.hp ~= hp) then
            rhm_log(string.format("RHM [RealThroughput]: %s %s @ %.0f hp -> rated %.1f t/h, E %.2f HP/(t/h) (upstream %.2f)",
                isForage and "forage" or "grain", tostring(cropName), hp, rated * 3.6, eAnchor, eUpstream))
        end
        self._rtLast = { crop = cropName, hp = hp, ratedTph = rated * 3.6, eAnchor = eAnchor,
                         eUpstream = eUpstream, yieldFactor = yieldFactor, forage = isForage }
        return e
    end)

-- ============================================================================
-- EN: Console commands (registered once the manager exists, like upstream's own)
-- UA: Консольні команди
-- ============================================================================

function RealThroughput.consoleToggle(_, arg)
    local a = arg and tostring(arg):lower() or ""
    if a == "on" or a == "1" or a == "true" then
        RealThroughput.enabled = true
    elseif a == "off" or a == "0" or a == "false" then
        RealThroughput.enabled = false
    elseif a == "reload" then
        RealThroughputConfig.load()
        return "RealThroughput: cropThroughput.xml reloaded"
    elseif a ~= "" and a ~= "status" then
        return "Usage: rhmRealThroughput [on|off|status|reload]"
    end

    local C = RealThroughputConfig
    local nG, nF = 0, 0
    for _ in pairs(C._grain) do nG = nG + 1 end
    for _ in pairs(C._forage) do nF = nF + 1 end
    local out = string.format("RealThroughput: %s | config=%s | %d grain + %d forage curves",
        RealThroughput.enabled and "ON (fork anchors)" or "OFF (upstream native)", C._source, nG, nF)

    local mgr = g_realisticHarvestManager
    local veh = mgr and mgr.lastActiveCombine
    local calc = veh and veh.spec_rhm_Combine and veh.spec_rhm_Combine.loadCalculator
    local last = calc and calc._rtLast
    if last then
        out = out .. string.format("\n  active machine: %s %s @ %.0f hp  rated %.1f t/h  E=%.2f (upstream %.2f, yield x%.2f)",
            last.forage and "forage" or "grain", tostring(last.crop), last.hp, last.ratedTph,
            last.eAnchor, last.eUpstream, last.yieldFactor)
    else
        out = out .. "\n  active machine: no anchored crop applied yet"
    end
    return out
end

-- EN: Prints the rated throughput each anchored crop reaches at a given horsepower. Handy for
--     checking an edit to cropThroughput.xml without leaving the game.
-- UA: Показує рейтингову продуктивність кожної культури для заданих к.с.
function RealThroughput.consoleTable(_, arg)
    local hp = tonumber(arg) or 775
    local C = RealThroughputConfig
    C.ensureLoaded()
    local names = {}
    for k in pairs(C._grain) do names[#names + 1] = k end
    table.sort(names)
    local lines = { string.format("Rated throughput at %.0f hp (grain, peak = 100%% engine load):", hp) }
    for _, k in ipairs(names) do
        local kgs = C.curveKgPerSec(C._grain[k], hp)
        local buHr = kgs * 3600 * LBS_PER_KG / C.bushelLbs(k)
        lines[#lines + 1] = string.format("  %-14s %7.0f bu/hr  %6.1f t/h", k, buHr, kgs * 3.6)
    end
    return table.concat(lines, "\n")
end
wrapMethod(RHM_RealisticHarvestManager, "RHM_RealisticHarvestManager", "new", function(orig, mission, modDirectory, modName)
    local self = orig(mission, modDirectory, modName)
    addConsoleCommand("rhmRealThroughput", "rhmRealThroughput [on|off|status|reload] - fork throughput anchors vs upstream native",
        "consoleToggle", RealThroughput)
    addConsoleCommand("rhmThroughputTable", "rhmThroughputTable [hp] - rated throughput per anchored crop",
        "consoleTable", RealThroughput)
    return self
end)
