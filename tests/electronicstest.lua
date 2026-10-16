-- Headless harness for src/fork/ElectronicsTiers.lua and src/fork/Defaults.lua.
-- Loads the REAL modules against stubs shaped like the engine's configuration system and
-- upstream's classes. Run from the mod root:  lua tests/electronicstest.lua
--
-- What this CANNOT prove: that the engine renders and saves the configuration as expected.
-- That part rests on engine source read directly (ConfigurationManager.lua:24-66,
-- ConfigurationUtil.lua:324-452, TypeManager.lua:207-245) and needs an in-game check.

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }

-- ---- engine stubs ----
-- Matches the engine exactly (utils/Utils.lua:459-467): the wrapper receives (self, oldFunc, ...) with
-- the RAW old function; callers pass `self` to it themselves, as upstream's own wrapper does.
Utils = {
    appendedFunction = function(old, new)
        return function(...) local r = old(...); new(...); return r end
    end,
    overwrittenFunction = function(old, new)
        return old == nil and function(self, ...) return new(self, nil, ...) end
            or function(self, ...) return new(self, old, ...) end
    end,
}

local texts = {
    rhm_upgrade_section_title = "Harvest Technology",
    rhm_upgrade_tier0_name = "No upgrades", rhm_upgrade_tier1_name = "Loss Catch Pan",
    rhm_upgrade_tier1_forage_name = "Chop Quality Monitoring", rhm_upgrade_tier2_name = "Settings Monitoring",
    rhm_upgrade_tier3_name = "Speed Automation", rhm_upgrade_tier4_name = "Full Automation",
}
g_i18n = { hasText = function(_, k) return texts[k] ~= nil end, getText = function(_, k) return texts[k] or k end }

VehicleConfigurationItem = {}
VehicleConfigurationItem.__index = VehicleConfigurationItem
function VehicleConfigurationItem.new(name) return setmetatable({ configName = name }, VehicleConfigurationItem) end
function VehicleConfigurationItem:setIndex(i) self.index = i end

local registered = {}
g_vehicleConfigurationManager = {
    configurations = { rhmPackage = { name = "rhmPackage", itemClass = VehicleConfigurationItem } },
    addConfigurationType = function(self, name, title, xmlKey, itemClass)
        registered[#registered + 1] = { name = name, title = title, xmlKey = xmlKey }
        self.configurations[name] = { name = name, title = title, itemClass = itemClass }
    end,
    getConfigurations = function(self) return self.configurations end,
}

ConfigurationUtil = {}
function ConfigurationUtil.getDefaultConfigIdFromItems(items)
    for i, it in ipairs(items) do if it.isDefault then return i end end
    return 1
end
-- stand-in for what UPSTREAM's wrapper returns: rhmPackage present only for combines
local upstreamCalls = 0
function ConfigurationUtil.getConfigurationsFromXML(manager, xmlFile, key, baseDir, env, isMod, storeItem)
    upstreamCalls = upstreamCalls + 1
    local cfgs, defs = {}, {}
    if xmlFile and xmlFile.isCombine then
        cfgs.rhmPackage = { {}, {}, {}, {} }
        defs.rhmPackage = 1
    end
    cfgs.color = { {} }; defs.color = 1                      -- an unrelated configuration must survive
    return cfgs, defs
end

-- ---- upstream class stubs ----
rhm_Combine = {}
function rhm_Combine:onLoad(savegame)
    self.sawPackageConfig = self.configurations and self.configurations.rhmPackage
    if self.explode then error("boom in onLoad") end
    self.spec_rhm_Combine = { isRhmCombine = true, packageLevel = tonumber(self.sawPackageConfig) or 1 }
end
rhm_Combine.speedCalls = {}
function rhm_Combine:getSpeedLimit(superFunc, onlyIfWorking)
    rhm_Combine.speedCalls[#rhm_Combine.speedCalls + 1] = g_realisticHarvestManager.settings.enableSpeedLimit
    if self.explodeSpeed then error("boom in getSpeedLimit") end
    return 12.5, true
end
function rhm_Combine:onUpdateTick(dt)
    rhm_Combine.speedCalls[#rhm_Combine.speedCalls + 1] = g_realisticHarvestManager.settings.enableSpeedLimit
end

RHMCombineCalibrationGUI = {}
function RHMCombineCalibrationGUI:drawParameterRow(x, y, w, param, label, memory, ui, machineType, packageLevel, cached)
    self.lastLevel = packageLevel
end

RHM_Api = {}
local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end
RHM_RealisticHarvestManager = { new = function() return {} end }
RHM_CombineMemory = { new = function() return { currentSettings = { fan = 50, targetEngineLoad = 80 } } end }
g_realisticHarvestManager = { settings = { enableSpeedLimit = true } }

-- rhm_Combine hooks go through the installer (the engine replaces that table when it re-sources the
-- specialization - see bridgetest.lua section 11); ForkLoader runs install() after every module.
SpecializationManager = { addSpecialization = function() return true end }
dofile("src/fork/SpecHooks.lua")
dofile("src/fork/Defaults.lua")
dofile("src/fork/ElectronicsTiers.lua")
ForkSpecHooks.install()

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-62s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-62s %s", name, detail or "")) end
end
local T = ElectronicsTiers

print("=== 1. loads cleanly and registers the configuration type ===")
check("no warnings at load", #warnings == 0, warnings[1] or "")
check("type 'rhm_upgradeTier' registered once", #registered == 1 and registered[1].name == "rhm_upgradeTier")
check("registered with a nil xmlKey (engine supports it)", registered[1].xmlKey == nil)
check("title comes from the translation", registered[1].title == "Harvest Technology")

print("=== 2. shop: five tiers replace upstream's packages on combines ===")
local manager = g_vehicleConfigurationManager
local cfgs, defs = ConfigurationUtil.getConfigurationsFromXML(manager, { isCombine = true }, "k", "", "", false, { categoryName = "HARVESTERS" })
check("upstream's wrapper was still called (we sit outside it)", upstreamCalls == 1)
check("rhmPackage removed from configurations and defaults", cfgs.rhmPackage == nil and defs.rhmPackage == nil)
local items = cfgs.rhm_upgradeTier
check("five tier items", items and #items == 5)
local want = { { "No upgrades", 0, 0 }, { "Loss Catch Pan", 2500, 8 }, { "Settings Monitoring", 7500, 21 },
               { "Speed Automation", 17500, 167 }, { "Full Automation", 37500, 417 } }
local itemsOk = true
for i, w in ipairs(want) do
    local it = items[i]
    if not (it.name == w[1] and it.price == w[2] and it.dailyUpkeep == w[3] and it.index == i
            and it.saveId == tostring(i - 1) and it.isSelectable) then itemsOk = false end
end
check("names, prices, daily upkeep, index and saveId \"0\"..\"4\" match the fork", itemsOk)
check("only tier 0 is the default", items[1].isDefault and not items[2].isDefault and not items[5].isDefault)
check("default configuration id points at tier 0", defs.rhm_upgradeTier == 1)
check("unrelated configurations are untouched", cfgs.color and defs.color == 1)

local _, _ = nil, nil
local fcfgs = ConfigurationUtil.getConfigurationsFromXML(manager, { isCombine = true, hasProperty = function(_, p) return p == "vehicle.forageHarvester" end }, "k", "", "", false, {})
check("forage harvester: tier 1 renamed (no grain to catch)", fcfgs.rhm_upgradeTier[2].name == "Chop Quality Monitoring")
local fcfgs2 = ConfigurationUtil.getConfigurationsFromXML(manager, { isCombine = true }, "k", "", "", false, { categoryName = "forageHarvesters" })
check("forage detected from the store category too", fcfgs2.rhm_upgradeTier[2].name == "Chop Quality Monitoring")
check("other tiers keep their names on forage", fcfgs.rhm_upgradeTier[3].name == "Settings Monitoring")

local ncfgs, ndefs = ConfigurationUtil.getConfigurationsFromXML(manager, { isCombine = false }, "k", "", "", false, {})
check("non-combine vehicle gets nothing added", ncfgs.rhm_upgradeTier == nil and ncfgs.rhmPackage == nil)

print("=== 3. fail-safe: a build failure leaves upstream's packages in place ===")
local savedNew = VehicleConfigurationItem.new
VehicleConfigurationItem.new = function() error("engine says no") end
local wcfgs, wdefs = ConfigurationUtil.getConfigurationsFromXML(manager, { isCombine = true }, "k", "", "", false, {})
VehicleConfigurationItem.new = savedNew
check("upstream's rhmPackage kept when ours cannot be built", wcfgs.rhmPackage ~= nil and wcfgs.rhm_upgradeTier == nil and wdefs.rhmPackage == 1)
check("...and it is logged", warnings[#warnings] and warnings[#warnings]:find("could not build") ~= nil)

print("=== 4. level lookup ===")
check("no configuration -> tier 0", T.getLevel({}) == 0 and T.getLevel({ configurations = {} }) == 0 and T.getLevel(nil) == 0)
for i = 1, 5 do check("configuration index " .. i .. " -> tier " .. (i - 1), T.getLevel({ configurations = { rhm_upgradeTier = i } }) == i - 1) end
check("out-of-range index clamps", T.getLevel({ configurations = { rhm_upgradeTier = 99 } }) == 4 and T.getLevel({ configurations = { rhm_upgradeTier = -3 } }) == 0)
local mapped = { [0] = 1, [1] = 2, [2] = 2, [3] = 3, [4] = 4 }
local mapOk = true
for lvl, pkg in pairs(mapped) do if T.packageLevelFor(lvl) ~= pkg then mapOk = false end end
check("tier -> upstream package level: 0->1, 1->2, 2->2, 3->3, 4->4", mapOk)

print("=== 5. upstream's onLoad sees the mapped level, and it never persists ===")
for tier = 0, 4 do
    local veh = setmetatable({ configurations = { rhm_upgradeTier = tier + 1 } }, { __index = rhm_Combine })
    rhm_Combine.onLoad(veh, nil)
    check(string.format("tier %d: upstream computed packageLevel %d", tier, mapped[tier]),
        veh.spec_rhm_Combine.packageLevel == mapped[tier] and veh.spec_rhm_Combine.forkTier == tier)
    check(string.format("tier %d: stand-in removed afterwards", tier), veh.configurations.rhmPackage == nil)
end
do
    local veh = setmetatable({ configurations = { rhm_upgradeTier = 4, rhmPackage = 2 } }, { __index = rhm_Combine })
    rhm_Combine.onLoad(veh, nil)
    check("a pre-existing rhmPackage value is restored, not lost", veh.configurations.rhmPackage == 2)
    local boom = setmetatable({ configurations = { rhm_upgradeTier = 3 }, explode = true }, { __index = rhm_Combine })
    local ok, err = pcall(rhm_Combine.onLoad, boom, nil)
    check("an error inside upstream's onLoad still propagates", not ok and tostring(err):find("boom") ~= nil)
    check("...and the stand-in is cleaned up even then", boom.configurations.rhmPackage == nil)
    local bare = setmetatable({}, { __index = rhm_Combine })
    check("a vehicle with no configurations table does not crash", pcall(rhm_Combine.onLoad, bare, nil))
end

print("=== 6. speed automation is a tier-3 feature ===")
local function vehicleAt(tier, extra)
    local v = setmetatable({ configurations = { rhm_upgradeTier = tier + 1 } }, { __index = rhm_Combine })
    for k, val in pairs(extra or {}) do v[k] = val end
    rhm_Combine.onLoad(v, nil)
    return v
end
for tier = 0, 4 do
    local v = vehicleAt(tier)
    check("tier " .. tier .. ": speed automation " .. (tier < 3 and "locked" or "available"),
        T.isSpeedAutomationLocked(v) == (tier < 3))
end
check("a non-RHM vehicle is never locked", T.isSpeedAutomationLocked({}) == false)
do
    local settings = g_realisticHarvestManager.settings
    rhm_Combine.speedCalls = {}
    local low = vehicleAt(1)
    local a, b = rhm_Combine.getSpeedLimit(low, function() end, true)
    check("tier 1: getSpeedLimit ran with speed limiting OFF", rhm_Combine.speedCalls[1] == false)
    check("...results pass through unchanged", a == 12.5 and b == true)
    check("...and the global switch is restored", settings.enableSpeedLimit == true)
    rhm_Combine.onUpdateTick(low, 16)
    check("tier 1: onUpdateTick ran with speed limiting OFF", rhm_Combine.speedCalls[2] == false and settings.enableSpeedLimit == true)

    rhm_Combine.speedCalls = {}
    local high = vehicleAt(3)
    rhm_Combine.getSpeedLimit(high, function() end, true)
    rhm_Combine.onUpdateTick(high, 16)
    check("tier 3: speed limiting left ON for both calls", rhm_Combine.speedCalls[1] == true and rhm_Combine.speedCalls[2] == true)

    local boom = vehicleAt(0, { explodeSpeed = true })
    local ok, err = pcall(rhm_Combine.getSpeedLimit, boom, function() end, true)
    check("an error inside the call propagates", not ok and tostring(err):find("boom") ~= nil)
    check("...and the global switch is restored even then", settings.enableSpeedLimit == true)

    settings.enableSpeedLimit = false          -- the player turned speed limiting off globally
    rhm_Combine.speedCalls = {}
    rhm_Combine.getSpeedLimit(low, function() end, true)
    check("already off globally: stays off and is not flipped back on", rhm_Combine.speedCalls[1] == false and settings.enableSpeedLimit == false)
    settings.enableSpeedLimit = true
end

print("=== 7. tier 1 shows loss but not the optimal-setting hints ===")
do
    local gui = setmetatable({}, { __index = RHMCombineCalibrationGUI })
    local function levelSeen(tier, pkg)
        local v = vehicleAt(tier)
        gui:drawParameterRow(0, 0, 1, "fan", "Fan", { combine = v }, {}, "grain", pkg, nil)
        return gui.lastLevel
    end
    check("tier 1 on package level 2: told level 1 (no hints)", levelSeen(1, 2) == 1)
    check("tier 2 on package level 2: hints kept", levelSeen(2, 2) == 2)
    check("tier 3 / 4 untouched", levelSeen(3, 3) == 3 and levelSeen(4, 4) == 4)
    check("tier 0 untouched", levelSeen(0, 1) == 1)
    gui:drawParameterRow(0, 0, 1, "fan", "Fan", nil, {}, "grain", 2, nil)
    check("no memory object: passed through, no crash", gui.lastLevel == 2)
end

print("=== 8. API ===")
check("RHM_Api.getUpgradeLevel returns the fork's 0..4", RHM_Api.getUpgradeLevel(vehicleAt(2)) == 2 and RHM_Api.getUpgradeLevel(vehicleAt(4)) == 4)
check("...and tolerates nil", RHM_Api.getUpgradeLevel(nil) == 0)

print("=== 8b. console status ===")
do
    RHM_RealisticHarvestManager.new()
    local has = false
    for _, c in ipairs(commands) do if c == "rhmTier" then has = true end end
    check("rhmTier registered with the manager", has)
    g_realisticHarvestManager.lastActiveCombine = nil
    check("no active combine -> says so", T.consoleStatus():find("no RHM combine") ~= nil)
    g_realisticHarvestManager.lastActiveCombine = vehicleAt(2)
    local s2 = T.consoleStatus()
    check("tier 2: reports tier, package level 2, speed LOCKED, $21/day",
        s2:find("tier 2", 1, true) and s2:find("package level 2", 1, true) and s2:find("LOCKED", 1, true) and s2:find("$21/day", 1, true))
    g_realisticHarvestManager.lastActiveCombine = vehicleAt(4)
    local s4 = T.consoleStatus()
    check("tier 4: speed available, $417/day", s4:find("available", 1, true) and s4:find("$417/day", 1, true))
    g_realisticHarvestManager.lastActiveCombine = nil
end

print("=== 9. default target engine load is 95 % ===")
local mem = RHM_CombineMemory.new({}, "grain")
check("new machine memory starts at 95", mem.currentSettings.targetEngineLoad == 95)
check("other settings untouched", mem.currentSettings.fan == 50)
check("the default is exposed for other code", ForkDefaults.TARGET_ENGINE_LOAD == 95)
-- a saved value must win: upstream's load code assigns after construction, so the player's value replaces 95
mem.currentSettings.targetEngineLoad = 82
check("a value set afterwards (saved game / player) is not overridden", mem.currentSettings.targetEngineLoad == 82)

print("=== 10. missing upstream pieces disable, never throw ===")
do
    local w0 = #warnings
    local savedGet = ConfigurationUtil.getConfigurationsFromXML
    local savedMem = RHM_CombineMemory
    local savedGui = RHMCombineCalibrationGUI
    ConfigurationUtil.getConfigurationsFromXML = nil
    RHM_CombineMemory = nil
    RHMCombineCalibrationGUI = nil
    local ok = pcall(function()
        g_vehicleConfigurationManager.configurations.rhm_upgradeTier = nil     -- allow re-registration
        dofile("src/fork/Defaults.lua")
        dofile("src/fork/ElectronicsTiers.lua")
    end)
    ConfigurationUtil.getConfigurationsFromXML = savedGet
    RHM_CombineMemory = savedMem
    RHMCombineCalibrationGUI = savedGui
    check("re-loading with pieces missing does not throw", ok)
    check("each absent piece is logged", #warnings >= w0 + 2, (#warnings - w0) .. " new warnings")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
