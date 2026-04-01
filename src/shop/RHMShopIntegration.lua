-- EN: RHMShopIntegration — Injects RH upgrade tier configurations into all combine store items.
--     Registers a "rhm_upgradeTier" vehicle configuration type with the FS25 shop system so
--     players can purchase upgrade tiers directly from the vehicle store (like any other
--     factory option such as wheel width or color). The price shown in the store raises the
--     vehicle's total purchase cost by the cumulative upgrade amount.
--
--     Tier pricing (one-time purchase on top of base vehicle price) + annual subscription:
--       Tier 0  (No upgrades)         $0        |   $0/yr upkeep
--       Tier 1  (Loss Catch Pan)      $2,500    | ~$100/yr hardware maintenance
--       Tier 2  (Settings Monitoring) $7,500    | ~$250/yr hardware + calibration
--       Tier 3  (Speed Automation)   $17,500    |  $2,000/yr software subscription
--       Tier 4  (Full Automation)    $37,500    |  $5,000/yr software subscription
--
-- UA: RHMShopIntegration — Вбудовує конфігурації рівнів апгрейду RH у магазинні позиції
--     всіх комбайнів. Реєструє тип конфігурації "rhm_upgradeTier" у системі крамниці FS25.

RHMShopIntegration = {}

-- ============================================================================
-- EN: Shorthand debug logger — only prints when Shop module is enabled.
-- UA: Скорочений логер — друкує лише коли модуль Shop увімкнено.
-- ============================================================================
local function dbg(msg)
    if RHM_Debug and RHM_Debug.isEnabled("Shop") then
        print("RHM [Shop]: " .. tostring(msg))
    end
end

local function dbgf(fmt, ...)
    if RHM_Debug and RHM_Debug.isEnabled("Shop") then
        print("RHM [Shop]: " .. string.format(fmt, ...))
    end
end

-- ============================================================================
-- EN: Upgrade tier definitions. nameKey resolves via g_i18n at inject time.
-- UA: Визначення рівнів апгрейду. nameKey перекладається через g_i18n.
-- ============================================================================
-- EN: Daily upkeep math — FS25 charges dailyUpkeep × timeAdjustment each game day,
--     where timeAdjustment = 1 / daysPerPeriod. A full FS25 year is always 12 periods,
--     so yearly cost = 12 × dailyUpkeep regardless of the player's time speed setting.
--
--     Tier 0 — no hardware, no subscription:         $0/yr      →   $0/day
--     Tier 1 — physical hardware maintenance:        ~$100/yr   →   $8/day
--     Tier 2 — hardware + annual calibration:        ~$250/yr   →  $21/day
--     Tier 3 — Speed Automation software sub (JD):  $2,000/yr  → $167/day
--     Tier 4 — Full Automation software sub (JD):   $5,000/yr  → $417/day
local RHM_UPGRADE_TIERS = {
    { nameKey = "rhm_upgrade_tier0_name", price = 0,     dailyUpkeep = 0,   isDefault = true  },
    { nameKey = "rhm_upgrade_tier1_name", price = 2500,  dailyUpkeep = 8,   isDefault = false },
    { nameKey = "rhm_upgrade_tier2_name", price = 7500,  dailyUpkeep = 21,  isDefault = false },
    { nameKey = "rhm_upgrade_tier3_name", price = 17500, dailyUpkeep = 167, isDefault = false },
    { nameKey = "rhm_upgrade_tier4_name", price = 37500, dailyUpkeep = 417, isDefault = false },
}

-- EN: Categories from storeCategories.xml that receive the upgrade tier config.
--     IMPORTANT: categoryName is stored ALL-CAPS in the FS25 store system.
--     Confirmed from log: 'HARVESTERS', 'FORAGEHARVESTERS', 'RICEHARVESTERS'.
--     COTTONHARVESTERS added for completeness (cotton pickers share the combine spec).
local RHM_COMBINE_CATEGORIES = {
    HARVESTERS       = true,
    FORAGEHARVESTERS = true,
    RICEHARVESTERS   = true,
    COTTONHARVESTERS = true,
}

-- ============================================================================
-- STEP 1 — Register the configuration TYPE with the vehicle configuration manager.
--          This tells the shop how to label the panel and which class to use for items.
--          Must succeed before any injection is useful.
-- ============================================================================
dbg("=== SHOP INTEGRATION INIT ===")
dbgf("g_vehicleConfigurationManager present: %s", tostring(g_vehicleConfigurationManager ~= nil))
dbgf("g_vehicleConfigurationManager.addConfigurationType present: %s",
    tostring(g_vehicleConfigurationManager and g_vehicleConfigurationManager.addConfigurationType ~= nil))
dbgf("VehicleConfigurationItem present: %s", tostring(VehicleConfigurationItem ~= nil))

if g_vehicleConfigurationManager
        and g_vehicleConfigurationManager.addConfigurationType
        and VehicleConfigurationItem then

    local configTitle = (g_i18n and g_i18n:getText("rhm_upgrade_section_title")) or "Harvest Technology"
    dbgf("Registering type 'rhm_upgradeTier' with title '%s'", configTitle)

    local ok, err = pcall(function()
        g_vehicleConfigurationManager:addConfigurationType(
            "rhm_upgradeTier",
            configTitle,
            nil,
            VehicleConfigurationItem
        )
    end)

    if ok then
        dbg("addConfigurationType: SUCCESS")
        -- EN: Verify the type is now actually known to the manager.
        if g_vehicleConfigurationManager.getConfigurationType then
            local registered = g_vehicleConfigurationManager:getConfigurationType("rhm_upgradeTier")
            dbgf("getConfigurationType verify: %s", tostring(registered))
        else
            dbg("getConfigurationType method not available — cannot verify registration")
        end
    else
        dbgf("addConfigurationType: FAILED — %s", tostring(err))
    end

    print("RHM: [Shop] Registered rhm_upgradeTier configuration type")
else
    print("RHM: [Shop] WARNING — could not register rhm_upgradeTier (VehicleConfigurationItem unavailable at load time)")
    dbgf("  g_vehicleConfigurationManager = %s", tostring(g_vehicleConfigurationManager))
    dbgf("  VehicleConfigurationItem      = %s", tostring(VehicleConfigurationItem))
end

-- ============================================================================
-- STEP 2 — Hook StoreManager:addItem — fires once per item as each finishes
--          loading, whether synchronous (base-game storeItems.xml) or async
--          (mod vehicles via g_asyncTaskManager subtasks).
--          This replaces the old loadMapData hook, which ran before async mod
--          items were loaded and therefore always saw an empty items table.
-- ============================================================================

-- EN: Verify addItem exists before hooking — if nil, appendedFunction silently
--     produces a no-op and we'd never see any injection logs at all.
dbgf("StoreManager.addItem type before hook: %s", type(StoreManager.addItem))
if type(StoreManager.addItem) ~= "function" then
    print("RHM: [Shop] WARNING — StoreManager.addItem is not a function, per-item injection will NOT fire")
end

-- EN: Running total so we can print a summary after the map finishes loading.
local _rhmInjectCount = 0

dbg("Hooking StoreManager:addItem for per-item injection")

StoreManager.addItem = Utils.appendedFunction(StoreManager.addItem, function(self, storeItem)
    if not storeItem then return end

    local cat = tostring(storeItem.categoryName or "nil")
    dbgf("addItem fired: '%s'  category='%s'", tostring(storeItem.name or "?"), cat)

    if RHMShopIntegration.isCombineStoreItem(storeItem) then
        dbgf("  => combine detected, injecting rhm_upgradeTier")
        RHMShopIntegration.injectIntoStoreItem(storeItem)
        _rhmInjectCount = _rhmInjectCount + 1

        -- EN: Spot-check — verify the injection actually stuck.
        if RHM_Debug and RHM_Debug.isEnabled("Shop") then
            local cfgs = storeItem.configurations
            local tierCfg = cfgs and cfgs["rhm_upgradeTier"]
            if tierCfg then
                dbgf("  injection OK — %d tier items", #tierCfg)
                for i, item in ipairs(tierCfg) do
                    dbgf("    [%d] name='%s'  price=%s  hasGetNeedsRenaming=%s  hasOnPreLoad=%s",
                        i, tostring(item.name), tostring(item.price),
                        tostring(item.getNeedsRenaming ~= nil),
                        tostring(item.onPreLoad ~= nil))
                end
                dbgf("  defaultConfigurationIds[rhm_upgradeTier] = %s",
                    tostring(storeItem.defaultConfigurationIds and storeItem.defaultConfigurationIds["rhm_upgradeTier"]))
            else
                dbg("  WARNING — configurations[rhm_upgradeTier] is nil after injection!")
            end
        end
    end
end)

-- ============================================================================
-- STEP 3 — loadMapData summary hook.
--          All addItem calls are complete by the time loadMapData returns, so
--          this is the right place to print a final count and do a live table
--          spot-check to confirm injections survived the full load pass.
-- ============================================================================
StoreManager.loadMapData = Utils.appendedFunction(StoreManager.loadMapData, function(self)
    dbgf("=== loadMapData complete — %d combine(s) injected via addItem ===", _rhmInjectCount)

    if _rhmInjectCount == 0 then
        print("RHM: [Shop] WARNING — 0 combines were injected. addItem hook may not have fired.")
    else
        print(string.format("RHM: [Shop] %d combine storeItem(s) received rhm_upgradeTier config", _rhmInjectCount))
    end

    -- EN: Walk the live items table and verify the config survived on at least one combine.
    if RHM_Debug and RHM_Debug.isEnabled("Shop") and self.items then
        local checked = 0
        for _, item in pairs(self.items) do
            if RHMShopIntegration.isCombineStoreItem(item) then
                local tierCfg = item.configurations and item.configurations["rhm_upgradeTier"]
                dbgf("  post-load check '%s': rhm_upgradeTier=%s",
                    tostring(item.name or "?"),
                    tierCfg and string.format("%d items", #tierCfg) or "MISSING")
                checked = checked + 1
                if checked >= 3 then break end  -- EN: Sample first 3 only to keep log short.
            end
        end
        if checked == 0 then
            dbg("  post-load: no combine storeItems found in self.items — category names may not match")
            -- EN: Dump first 10 category names seen so we can cross-check our RHM_COMBINE_CATEGORIES table.
            local n = 0
            for _, item in pairs(self.items) do
                dbgf("  sample category: '%s'", tostring(item.categoryName or "nil"))
                n = n + 1
                if n >= 10 then break end
            end
        end
    end
end)

-- ============================================================================
-- STEP 3b — Hook g_vehicleConfigurationManager.getConfigurationType so we can
--           see whether the shop UI actually requests our type when it renders
--           the config panel for a combine. If this never fires for
--           "rhm_upgradeTier" then the type registration (STEP 1) is the failure.
-- ============================================================================
if g_vehicleConfigurationManager and g_vehicleConfigurationManager.getConfigurationType then
    dbg("Hooking g_vehicleConfigurationManager.getConfigurationType for render-time tracing")
    g_vehicleConfigurationManager.getConfigurationType = Utils.appendedFunction(
        g_vehicleConfigurationManager.getConfigurationType,
        function(self, configType)
            if configType == "rhm_upgradeTier" then
                dbg("getConfigurationType called for 'rhm_upgradeTier' — shop is trying to render our panel")
            end
        end
    )
else
    dbg("g_vehicleConfigurationManager.getConfigurationType not available — cannot trace shop render calls")
end

-- ============================================================================
-- STEP 4 — Category check.
-- ============================================================================
function RHMShopIntegration.isCombineStoreItem(storeItem)
    if not storeItem then return false end
    return RHM_COMBINE_CATEGORIES[storeItem.categoryName] == true
end

-- ============================================================================
-- STEP 5 — Build and inject VehicleConfigurationItem instances.
-- ============================================================================
function RHMShopIntegration.injectIntoStoreItem(storeItem)
    storeItem.configurations          = storeItem.configurations          or {}
    storeItem.defaultConfigurationIds = storeItem.defaultConfigurationIds or {}

    local tierItems = {}
    for i, tier in ipairs(RHM_UPGRADE_TIERS) do
        local item, createErr = nil, nil
        local ok = pcall(function()
            item = VehicleConfigurationItem.new("rhm_upgradeTier")
        end)
        if not ok or not item then
            dbgf("VehicleConfigurationItem.new FAILED for tier %d: %s", i, tostring(createErr))
        else
            item:setIndex(i)
            item.name         = (g_i18n and g_i18n:getText(tier.nameKey)) or tier.nameKey
            item.price        = tier.price
            item.dailyUpkeep  = tier.dailyUpkeep
            item.isDefault    = tier.isDefault
            item.isSelectable = true
            item.saveId       = tostring(i - 1)
            tierItems[i] = item
        end
    end

    storeItem.configurations["rhm_upgradeTier"]          = tierItems
    storeItem.defaultConfigurationIds["rhm_upgradeTier"] = 1
end

-- ============================================================================
-- STEP 6 — Read-back: called from rhm_Combine:onLoad to pull the selected tier.
-- ============================================================================
function RHMShopIntegration.getUpgradeLevelFromConfig(vehicle)
    dbgf("getUpgradeLevelFromConfig called for: %s", tostring(vehicle and vehicle.configFileName or "?"))
    dbgf("  vehicle.configurations type: %s", type(vehicle and vehicle.configurations))

    if not vehicle or not vehicle.configurations then
        dbg("  => nil (no vehicle.configurations)")
        return nil
    end

    -- EN: Dump all configuration keys on the vehicle so we can see what the shop stored.
    if RHM_Debug and RHM_Debug.isEnabled("Shop") then
        dbg("  vehicle.configurations keys:")
        for k, v in pairs(vehicle.configurations) do
            dbgf("    [%s] = %s (%s)", tostring(k), tostring(v), type(v))
        end
    end

    local configIndex = vehicle.configurations["rhm_upgradeTier"]
    dbgf("  raw configIndex for 'rhm_upgradeTier': %s (%s)", tostring(configIndex), type(configIndex))

    if type(configIndex) ~= "number" or configIndex < 1 then
        dbg("  => nil (configIndex not a valid number)")
        return nil
    end

    local level = math.max(0, math.min(4, configIndex - 1))
    dbgf("  => upgradeLevel %d", level)
    return level
end
