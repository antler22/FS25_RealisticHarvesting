-- EN: RHMShopIntegration — Injects RH upgrade tier configurations into all combine store items.
--     Registers a "rhm_upgradeTier" vehicle configuration type with the FS25 shop system so
--     players can purchase upgrade tiers directly from the vehicle store (like any other
--     factory option such as wheel width or color). The price shown in the store raises the
--     vehicle's total purchase cost by the cumulative upgrade amount.
--
--     Tier pricing (cumulative, added on top of base vehicle price):
--       Tier 0  (No Upgrade)          $0
--       Tier 1  (Loss Catch Pan)      $2,500
--       Tier 2  (Settings Monitoring) $7,500
--       Tier 3  (Speed Automation)   $17,500
--       Tier 4  (Full Automation)    $37,500
--
-- UA: RHMShopIntegration — Вбудовує конфігурації рівнів апгрейду RH у магазинні позиції
--     всіх комбайнів. Реєструє тип конфігурації "rhm_upgradeTier" у системі крамниці FS25,
--     щоб гравці могли купувати рівні апгрейду безпосередньо в магазині транспортних засобів.

RHMShopIntegration = {}

-- EN: Cumulative upgrade costs matching CombineMemory.UPGRADE_COSTS.
--     Index aligns with tier level (0 = no upgrade, 1-4 = upgrade tiers).
-- UA: Кумулятивні ціни апгрейду, що відповідають CombineMemory.UPGRADE_COSTS.
local RHM_UPGRADE_TIERS = {
    { nameKey = "rhm_upgrade_tier0_name", price = 0,     dailyUpkeep = 0.0, isDefault = true  },
    { nameKey = "rhm_upgrade_tier1_name", price = 2500,  dailyUpkeep = 0.5, isDefault = false },
    { nameKey = "rhm_upgrade_tier2_name", price = 7500,  dailyUpkeep = 1.0, isDefault = false },
    { nameKey = "rhm_upgrade_tier3_name", price = 17500, dailyUpkeep = 1.5, isDefault = false },
    { nameKey = "rhm_upgrade_tier4_name", price = 37500, dailyUpkeep = 2.0, isDefault = false },
}

-- EN: Register the "rhm_upgradeTier" configuration type with the vehicle configuration manager.
--     Must be called before StoreManager.loadMapData so the shop knows how to render the panel.
--     Safe to call at mod load time — g_vehicleConfigurationManager is initialized before mods.
-- UA: Реєструємо тип конфігурації "rhm_upgradeTier" у менеджері конфігурацій транспортних засобів.
if g_vehicleConfigurationManager
        and g_vehicleConfigurationManager.addConfigurationType
        and VehicleConfigurationItem then

    local configTitle = (g_i18n and g_i18n:getText("rhm_upgrade_section_title"))
                        or "RH Upgrade"

    g_vehicleConfigurationManager:addConfigurationType(
        "rhm_upgradeTier",   -- configuration type identifier
        configTitle,         -- display header in shop panel
        nil,                 -- no XML key (items are injected programmatically, not from vehicle XML)
        VehicleConfigurationItem
    )
    print("RHM: [Shop] Registered rhm_upgradeTier configuration type")
else
    print("RHM: [Shop] WARNING — could not register rhm_upgradeTier (VehicleConfigurationItem unavailable at load time)")
end

-- EN: Hook StoreManager.loadMapData to inject our tier configurations into all combine storeItems
--     AFTER the base game has finished loading XML-defined configurations.  Using appendedFunction
--     guarantees our injection runs last and is never overwritten by the base loading pass.
-- UA: Підключаємося до StoreManager.loadMapData, щоб вставити конфігурації рівнів у всі
--     магазинні позиції комбайнів ПІСЛЯ того, як базова гра завантажила XML-конфігурації.
StoreManager.loadMapData = Utils.appendedFunction(StoreManager.loadMapData, function(storeManager)
    RHMShopIntegration.injectAllCombineConfigs(storeManager)
end)

--- EN: Iterates all storeItems and injects rhm_upgradeTier into each combine vehicle storeItem.
--- UA: Ітерує всі storeItems і вставляє rhm_upgradeTier у кожну позицію комбайна в магазині.
function RHMShopIntegration.injectAllCombineConfigs(storeManager)
    -- StoreManager stores items in self.items (not self.storeItems)
    local storeItems = storeManager and storeManager.items
    if not storeItems then
        print("RHM: [Shop] WARNING — storeManager.items is nil, skipping injection")
        return
    end

    local count = 0
    for _, storeItem in pairs(storeItems) do
        if RHMShopIntegration.isCombineStoreItem(storeItem) then
            RHMShopIntegration.injectIntoStoreItem(storeItem)
            count = count + 1
        end
    end
    print(string.format("RHM: [Shop] Injected rhm_upgradeTier into %d combine storeItem(s)", count))
end

-- EN: Category names from storeCategories.xml that RH upgrade tiers apply to.
--     "harvesters" = grain combines, "forageHarvesters" = forage combines,
--     "riceHarvesters" = rice combines. storeItem.categoryName is a plain string
--     field set during StoreManager.loadMapData — no XML parsing required.
local RHM_COMBINE_CATEGORIES = {
    harvesters     = true,
    forageHarvesters = true,
    riceHarvesters = true,
}

--- EN: Returns true if the storeItem is a combine vehicle by checking its store category name.
---     Using storeItem.categoryName avoids XML file parsing and specialization lookups,
---     which are unreliable from within the loadMapData hook context.
--- UA: Повертає true якщо storeItem є комбайном, перевіряючи назву категорії в магазині.
function RHMShopIntegration.isCombineStoreItem(storeItem)
    if not storeItem then return false end
    return RHM_COMBINE_CATEGORIES[storeItem.categoryName] == true
end

--- EN: Builds and injects the rhm_upgradeTier configuration item list into a combine storeItem.
---     Items MUST be proper VehicleConfigurationItem instances (not plain tables) — the shop UI
---     calls methods like :getNeedsRenaming(), :setIndex(), :onPreLoad() on them and will crash
---     with "missing argument" errors if given plain tables instead.
--- UA: Будує і вставляє список елементів rhm_upgradeTier у storeItem комбайна.
---     Елементи МАЮТЬ бути справжніми VehicleConfigurationItem — магазин викликає методи на них.
function RHMShopIntegration.injectIntoStoreItem(storeItem)
    storeItem.configurations        = storeItem.configurations        or {}
    storeItem.defaultConfigurationIds = storeItem.defaultConfigurationIds or {}

    local tierItems = {}
    for i, tier in ipairs(RHM_UPGRADE_TIERS) do
        local item = VehicleConfigurationItem.new("rhm_upgradeTier")
        item:setIndex(i)
        item.name        = (g_i18n and g_i18n:getText(tier.nameKey)) or tier.nameKey
        item.price       = tier.price
        item.dailyUpkeep = tier.dailyUpkeep
        item.isDefault   = tier.isDefault
        item.isSelectable = true
        item.saveId      = tostring(i - 1)  -- 0-based tier level for save/load
        tierItems[i] = item
    end

    storeItem.configurations["rhm_upgradeTier"]        = tierItems
    storeItem.defaultConfigurationIds["rhm_upgradeTier"] = 1  -- index 1 = No Upgrade
end

--- EN: Returns the upgrade level (0–4) derived from the vehicle's store configuration selection,
---     or nil if no rhm_upgradeTier configuration is present on the vehicle.
---     The FS25 shop stores selected configuration as a 1-based index, so we subtract 1.
---
---     Call from rhm_Combine:onLoad and rhm_Combine:loadFromXMLFile to blend store purchases
---     with the legacy in-GUI purchase path (always take the higher of the two values).
---
--- UA: Повертає рівень апгрейду (0–4) з вибраної конфігурації транспортного засобу в магазині,
---     або nil якщо rhm_upgradeTier відсутній у конфігурації. Вибір у магазині — 1-based індекс.
function RHMShopIntegration.getUpgradeLevelFromConfig(vehicle)
    if not vehicle or not vehicle.configurations then return nil end

    local configIndex = vehicle.configurations["rhm_upgradeTier"]
    if type(configIndex) ~= "number" or configIndex < 1 then return nil end

    -- Clamp to valid range: index 1 → level 0, index 5 → level 4
    local level = configIndex - 1
    if level < 0 then level = 0 end
    if level > 4 then level = 4 end
    return level
end
