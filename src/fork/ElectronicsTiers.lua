-- EN: Electronics tiers - the fork's purchasable "Harvest Technology" ladder, layered over
--     upstream WITHOUT editing upstream's files.
--
--     Upstream already has a four-level package system: a store configuration "rhmPackage" whose
--     chosen index becomes spec.packageLevel (1-4), which every upstream gate then reads (loss
--     sensor, optimal-setting hints, stats panel, Opti-Harvest AUTO). The fork has its own ladder:
--     five tiers (0-4) with different names, prices and DAILY UPKEEP, and one gate upstream does
--     not have (automatic speed control is a tier-3 feature). This module replaces upstream's
--     ladder in the shop with the fork's and feeds upstream's gates from it.
--
--       tier 0  No upgrades            $0         $0/day     -> package level 1  (nothing)
--       tier 1  Loss Catch Pan         $2,500     $8/day     -> package level 2  (loss readout)
--       tier 2  Settings Monitoring    $7,500     $21/day    -> package level 2  (+ optimal hints)
--       tier 3  Speed Automation       $17,500    $167/day   -> package level 3  (+ stats, + automatic speed)
--       tier 4  Full Automation        $37,500    $417/day   -> package level 4  (+ AUTO, live trim)
--
--     How it works
--       1. Shop: wraps ConfigurationUtil.getConfigurationsFromXML outside upstream's own wrapper.
--          Where upstream decided "this is a combine" (it added rhmPackage), the rhmPackage list is
--          replaced by the fork's "rhm_upgradeTier" list. Upstream's combine detection is reused,
--          so a vehicle class it learns to recognise later is picked up automatically. Config ids
--          ("0".."4") are the fork's, so saves made on the fork keep their tiers.
--       2. Gates: rhm_Combine:onLoad reads self.configurations["rhmPackage"] to set the package
--          level. For the duration of that call the mapped level is placed there, then removed, so
--          upstream computes spec.packageLevel itself, at the right moment, and the stand-in is
--          never saved.
--       3. Two differences upstream cannot express are added as small wrappers:
--            - tier 3 gates automatic speed control: below it upstream's own "speed limiting off"
--              switch is held off for that vehicle's calls (the advisory speed readout stays);
--            - tier 1 shows the loss readout but not the optimal-setting hints, which upstream's
--              level 2 would give together (the calibration terminal is told level 1 for those rows).
--
--     Not carried over: the fork's in-game "purchase an upgrade" function (CombineMemory:
--     purchaseUpgrade). It had no caller anywhere in the fork - the shop was the only way to buy.
--
-- UA: Електронні рівні - купована драбина "Harvest Technology" форку поверх оригіналу БЕЗ правок його
--     файлів. Оригінал має власну драбину з 4 пакетів (rhmPackage -> spec.packageLevel); форк має 5
--     рівнів (0-4) з іншими назвами, цінами та ЩОДЕННИМ утриманням і ще одним обмеженням:
--     автоматичне керування швидкістю доступне з 3-го рівня. Цей модуль підміняє драбину оригіналу в
--     магазині драбиною форку та живить обмеження оригіналу з неї.
ElectronicsTiers = {}

ElectronicsTiers.CONFIG_NAME = "rhm_upgradeTier"
ElectronicsTiers.UPSTREAM_CONFIG = "rhmPackage"

-- EN: nameKey resolves through the translation files at inject time. packageLevel is the level
--     upstream's gates see (1-4). Daily upkeep: FS25 charges dailyUpkeep x (1 / daysPerPeriod) per
--     game day and a year is always 12 periods, so yearly cost = 12 x dailyUpkeep regardless of
--     the player's time-scale setting.
-- UA: nameKey перекладається під час ін'єкції. packageLevel - рівень, який бачать обмеження
--     оригіналу. Щоденне утримання: річна вартість = 12 x dailyUpkeep.
ElectronicsTiers.TIERS = {
    [0] = { nameKey = "rhm_upgrade_tier0_name", price = 0,     dailyUpkeep = 0,   isDefault = true,  packageLevel = 1 },
    [1] = { nameKey = "rhm_upgrade_tier1_name", price = 2500,  dailyUpkeep = 8,   isDefault = false, packageLevel = 2 },
    [2] = { nameKey = "rhm_upgrade_tier2_name", price = 7500,  dailyUpkeep = 21,  isDefault = false, packageLevel = 2 },
    [3] = { nameKey = "rhm_upgrade_tier3_name", price = 17500, dailyUpkeep = 167, isDefault = false, packageLevel = 3 },
    [4] = { nameKey = "rhm_upgrade_tier4_name", price = 37500, dailyUpkeep = 417, isDefault = false, packageLevel = 4 },
}
ElectronicsTiers.FORAGE_TIER1_NAME_KEY = "rhm_upgrade_tier1_forage_name"   -- no grain to catch on a chopper
ElectronicsTiers.SPEED_AUTOMATION_TIER = 3
ElectronicsTiers.MAX_TIER = 4

local function log(fmt, ...)
    if rhm_log then rhm_log(string.format("RHM [Tiers]: " .. fmt, ...)) end
end

-- ============================================================================
-- EN: Level lookup
-- UA: Визначення рівня
-- ============================================================================

-- EN: Tier 0-4 of a vehicle, from the store configuration the engine saves and syncs for us.
--     A vehicle with no such configuration (e.g. bought before this existed) is tier 0.
-- UA: Рівень 0-4 з конфігурації магазину, яку рушій сам зберігає та синхронізує.
function ElectronicsTiers.getLevel(vehicle)
    local cfg = vehicle and vehicle.configurations
    local idx = cfg and tonumber(cfg[ElectronicsTiers.CONFIG_NAME])
    if not idx then return 0 end
    return math.max(0, math.min(ElectronicsTiers.MAX_TIER, math.floor(idx) - 1))
end

function ElectronicsTiers.packageLevelFor(level)
    local t = ElectronicsTiers.TIERS[level]
    return t and t.packageLevel or 1
end

-- EN: The tier cached on the spec at load, falling back to a fresh lookup.
function ElectronicsTiers.getTier(vehicle)
    local spec = vehicle and vehicle.spec_rhm_Combine
    if spec and spec.forkTier ~= nil then return spec.forkTier end
    return ElectronicsTiers.getLevel(vehicle)
end

function ElectronicsTiers.isSpeedAutomationLocked(vehicle)
    local spec = vehicle and vehicle.spec_rhm_Combine
    if not spec or spec.isRhmCombine ~= true then return false end
    return ElectronicsTiers.getTier(vehicle) < ElectronicsTiers.SPEED_AUTOMATION_TIER
end

-- ============================================================================
-- EN: Shop
-- UA: Магазин
-- ============================================================================

-- EN: Register the configuration type. Passing a nil xmlKey is supported by the engine
--     (ConfigurationManager.lua:44-48); the type name is the fork's, so saved ids still resolve.
--     128 types are allowed and the base game uses about 50, so this and upstream's own coexist.
if g_vehicleConfigurationManager and g_vehicleConfigurationManager.configurations
    and g_vehicleConfigurationManager.configurations[ElectronicsTiers.CONFIG_NAME] == nil
    and VehicleConfigurationItem then
    local title = (g_i18n and g_i18n:hasText("rhm_upgrade_section_title") and g_i18n:getText("rhm_upgrade_section_title"))
        or "Harvest Technology"
    g_vehicleConfigurationManager:addConfigurationType(ElectronicsTiers.CONFIG_NAME, title, nil, VehicleConfigurationItem)
end

-- EN: Build the five items for one store entry. Returns nil on any failure so the caller can
--     leave upstream's package list untouched instead of leaving a vehicle with neither.
-- UA: Будує п'ять пунктів для однієї позиції магазину. nil при будь-якій помилці - тоді список
--     оригіналу лишається, і машина не залишається без жодного.
function ElectronicsTiers.buildItems(manager, isForage)
    local descs = manager and manager.getConfigurations and manager:getConfigurations()
    local desc = descs and descs[ElectronicsTiers.CONFIG_NAME]
    if not (desc and desc.itemClass) then return nil end

    local items = {}
    for level = 0, ElectronicsTiers.MAX_TIER do
        local tier = ElectronicsTiers.TIERS[level]
        local ok, item = pcall(desc.itemClass.new, ElectronicsTiers.CONFIG_NAME)
        if not ok or not item then return nil end

        local nameKey = tier.nameKey
        if level == 1 and isForage then nameKey = ElectronicsTiers.FORAGE_TIER1_NAME_KEY end

        item:setIndex(level + 1)
        item.name         = (g_i18n and g_i18n:hasText(nameKey) and g_i18n:getText(nameKey)) or nameKey
        item.price        = tier.price
        item.dailyUpkeep  = tier.dailyUpkeep
        item.isDefault    = tier.isDefault
        item.isSelectable = true
        item.saveId       = tostring(level)       -- the fork's ids: "0".."4"
        items[level + 1]  = item
    end
    return items
end

-- EN: Sits OUTSIDE upstream's wrapper (same signature), so `superFunc` already includes
--     upstream's rhmPackage. Its presence is the signal that upstream judged this a combine.
-- UA: Стоїть ЗОВНІ обгортки оригіналу (той самий підпис), тож superFunc уже містить rhmPackage.
local function injectTiers(manager, superFunc, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)
    local configurations, defaultIds = superFunc(manager, xmlFile, key, baseDir, customEnvironment, isMod, storeItem)

    if configurations and configurations[ElectronicsTiers.UPSTREAM_CONFIG] ~= nil
        and configurations[ElectronicsTiers.CONFIG_NAME] == nil then

        local isForage = false
        if xmlFile and xmlFile.hasProperty and xmlFile:hasProperty("vehicle.forageHarvester") then
            isForage = true
        elseif storeItem and storeItem.categoryName and tostring(storeItem.categoryName):upper() == "FORAGEHARVESTERS" then
            isForage = true
        end

        local items = ElectronicsTiers.buildItems(manager, isForage)
        if items then
            configurations[ElectronicsTiers.UPSTREAM_CONFIG] = nil
            if defaultIds then defaultIds[ElectronicsTiers.UPSTREAM_CONFIG] = nil end
            configurations[ElectronicsTiers.CONFIG_NAME] = items
            if defaultIds then
                defaultIds[ElectronicsTiers.CONFIG_NAME] = ConfigurationUtil.getDefaultConfigIdFromItems(items)
            end
        else
            Logging.warning("[RHM-fork] ElectronicsTiers: could not build tier items — upstream's packages left in place")
        end
    end
    return configurations, defaultIds
end

if ConfigurationUtil and type(ConfigurationUtil.getConfigurationsFromXML) == "function" then
    ConfigurationUtil.getConfigurationsFromXML = Utils.overwrittenFunction(
        ConfigurationUtil.getConfigurationsFromXML, injectTiers)
else
    Logging.warning("[RHM-fork] ElectronicsTiers: ConfigurationUtil.getConfigurationsFromXML not found — shop tiers inactive")
end

-- ============================================================================
-- EN: Feeding upstream's gates
-- UA: Живлення обмежень оригіналу
-- ============================================================================

local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] ElectronicsTiers: %s.%s not found — that tier effect is inactive", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end

-- EN: Upstream's onLoad derives spec.packageLevel from self.configurations["rhmPackage"]. The
--     mapped level is put there for exactly that call and removed afterwards, so it is never
--     written to a savegame and upstream computes the field itself at the usual moment.
-- UA: onLoad оригіналу виводить spec.packageLevel з configurations["rhmPackage"]. Зіставлений рівень
--     кладемо туди лише на час цього виклику й прибираємо - у збереження він не потрапляє.
wrapMethod(rhm_Combine, "rhm_Combine", "onLoad", function(orig, self, savegame)
    local cfg = self.configurations
    local level = ElectronicsTiers.getLevel(self)
    local key = ElectronicsTiers.UPSTREAM_CONFIG
    local previous = cfg and cfg[key]

    if cfg then cfg[key] = ElectronicsTiers.packageLevelFor(level) end
    local ok, err = pcall(orig, self, savegame)
    if cfg then cfg[key] = previous end
    if not ok then error(err, 0) end

    local spec = self.spec_rhm_Combine
    if spec then
        spec.forkTier = level
        log("%s -> tier %d, package level %s", tostring(self.getFullName and self:getFullName() or "?"),
            level, tostring(spec.packageLevel))
    end
end)

-- EN: Below tier 3 upstream's speed enforcement must stay out of the way. Upstream has a global
--     "speed limiting" switch that it checks at exactly the enforcement points (the vehicle's
--     getSpeedLimit and the per-frame motor limiter in onUpdateTick), with a documented "never
--     touches the motor" branch. Holding that switch off for just this vehicle's calls gives
--     "no automatic speed control" without faking a value; the advisory recommended-speed readout
--     is computed independently and stays. The switch is restored even if the call throws.
-- UA: Нижче 3-го рівня примус швидкості не діє. Тримаємо глобальний вимикач оригіналу вимкненим лише
--     на час викликів цієї машини; рекомендована швидкість лишається. Вимикач відновлюється навіть
--     при помилці.
local function callWithSpeedLimitOff(vehicle, fn, ...)
    local settings = g_realisticHarvestManager and g_realisticHarvestManager.settings
    if not (settings and settings.enableSpeedLimit and ElectronicsTiers.isSpeedAutomationLocked(vehicle)) then
        return fn(...)
    end
    settings.enableSpeedLimit = false
    local ok, a, b, c = pcall(fn, ...)
    settings.enableSpeedLimit = true
    if not ok then error(a, 0) end
    return a, b, c
end

wrapMethod(rhm_Combine, "rhm_Combine", "getSpeedLimit", function(orig, self, superFunc, onlyIfWorking)
    return callWithSpeedLimitOff(self, orig, self, superFunc, onlyIfWorking)
end)

wrapMethod(rhm_Combine, "rhm_Combine", "onUpdateTick", function(orig, self, ...)
    return callWithSpeedLimitOff(self, orig, self, ...)
end)

-- EN: Tier 1 sees the loss readout but not the optimal-setting hints. Upstream's calibration
--     terminal draws the optimal band, status pill and OPTIMAL/LOW/HIGH text per parameter row
--     from a package level passed in as an argument; telling it level 1 for tier-1 machines holds
--     those back while everything else on the terminal follows level 2.
-- UA: Рівень 1 бачить втрати, але не підказки оптимуму. Термінал малює смугу оптимуму та статус за
--     рівнем пакета з аргументу; для машин 1-го рівня передаємо 1.
if RHMCombineCalibrationGUI then
    wrapMethod(RHMCombineCalibrationGUI, "RHMCombineCalibrationGUI", "drawParameterRow",
        function(orig, self, x, y, w, param, label, memory, ui, machineType, packageLevel, cachedCropSettings)
            local combine = memory and memory.combine
            local spec = combine and combine.spec_rhm_Combine
            if spec and spec.forkTier == 1 and packageLevel and packageLevel >= 2 then
                packageLevel = 1
            end
            return orig(self, x, y, w, param, label, memory, ui, machineType, packageLevel, cachedCropSettings)
        end)
end

-- ============================================================================
-- EN: Console: what tier is the machine I'm sitting in, and what does upstream see?
-- UA: Консоль: який рівень у машини, в якій я сиджу, і що бачить оригінал?
-- ============================================================================
function ElectronicsTiers.consoleStatus()
    local mgr = g_realisticHarvestManager
    local veh = mgr and mgr.lastActiveCombine
    local spec = veh and veh.spec_rhm_Combine
    if not spec then
        return "Electronics tiers: no RHM combine is active - climb into one first"
    end
    local tier = ElectronicsTiers.getTier(veh)
    local def = ElectronicsTiers.TIERS[tier]
    return string.format("Electronics tier %d | upstream package level %s | speed automation %s | upkeep $%d/day",
        tier, tostring(spec.packageLevel),
        ElectronicsTiers.isSpeedAutomationLocked(veh) and "LOCKED (tier 3 needed)" or "available",
        def and def.dailyUpkeep or 0)
end

if RHM_RealisticHarvestManager and type(RHM_RealisticHarvestManager.new) == "function" then
    local origNew = RHM_RealisticHarvestManager.new
    RHM_RealisticHarvestManager.new = function(...)
        local self = origNew(...)
        addConsoleCommand("rhmTier", "rhmTier - electronics tier of the active combine", "consoleStatus", ElectronicsTiers)
        return self
    end
end

-- ============================================================================
-- EN: Public API - the fork's accessor, kept for anything written against it.
-- UA: Публічний API - метод форку, збережений для сумісності.
-- ============================================================================
if RHM_Api and RHM_Api.getUpgradeLevel == nil then
    ---@return integer upgradeLevel 0..4 (the fork's ladder; RHM_Api.getPackageLevel gives upstream's 1..4)
    function RHM_Api.getUpgradeLevel(vehicle)
        local combine = vehicle and (vehicle.spec_rhm_Combine and vehicle or vehicle.rootVehicle) or nil
        return ElectronicsTiers.getTier(combine)
    end
end
