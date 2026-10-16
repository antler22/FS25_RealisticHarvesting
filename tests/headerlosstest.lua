-- Headless harness for src/fork/HeaderLoss.lua.
-- Loads the REAL module against a stub shaped like upstream's load calculator.
-- Run from the mod root:  lua tests/headerlosstest.lua

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }
local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end

-- ---- upstream-shaped stub: sets the fields upstream sets, returns its total ----
g_realisticHarvestManager = { settings = { enableCropLoss = true, difficultyLoss = 2 } }
RHM_LoadCalculator = {}
function RHM_LoadCalculator:calculateTotalCropLoss(vehicle)
    -- upstream recomputes these from scratch on every call
    self.baseLoss = self._base or 2.0
    self.overloadLoss = self.baseLoss
    local total = self._total or (self.baseLoss + 1.5)
    self.totalLoss, self.totalCropLoss, self.cropLoss = total, total, total
    return total
end
function RHM_LoadCalculator:getLossBreakdown() return { speedPct = self.baseLoss or 0 } end
RHM_RealisticHarvestManager = { new = function() return {} end }

dofile("src/fork/HeaderLoss.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-66s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-66s %s", name, detail or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end
local H = HeaderLoss

local function calc(crop, machine, extra)
    local c = setmetatable({ currentCrop = crop, combineMemory = { machineType = machine or "grain", currentCrop = crop } },
        { __index = RHM_LoadCalculator })
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end
local function at(speed) return { getLastSpeed = function() return speed end } end

print("=== 1. loads cleanly ===")
check("no warnings", #warnings == 0, warnings[1] or "")

print("=== 2. the formula ===")
check("at or below 9.65 km/h (6 mph): nothing", H.compute("WHEAT", 9.65) == 0 and H.compute("WHEAT", 5) == 0 and H.compute("WHEAT", 0) == 0)
check("no speed -> nothing", H.compute("WHEAT", nil) == 0)
local expect = (12 - 9.65) ^ 1.35 * 0.28
check("wheat at 12 km/h = (2.35)^1.35 x 0.28", near(H.compute("WHEAT", 12), expect), string.format("%.3f %%", expect))
check("grows with speed", H.compute("WHEAT", 14) > H.compute("WHEAT", 12) and H.compute("WHEAT", 12) > H.compute("WHEAT", 10))
check("capped at 8 %", H.compute("CANOLA", 60) == 8.0 and H.compute("WHEAT", 60) == 8.0)

print("=== 3. crop susceptibility ===")
check("canola twice as bad as wheat", near(H.compute("CANOLA", 12), 2.0 * H.compute("WHEAT", 12)))
check("corn a quarter (kernels sit in the husk)", near(H.compute("CORN", 12), 0.25 * H.compute("WHEAT", 12)))
check("MAIZE is corn (upstream's name for it)", H.cropFactor("MAIZE") == 0.25)
check("sorghum 0.8, oat 1.2, soybean 1.8, pea 1.7", H.cropFactor("SORGHUM") == 0.8 and H.cropFactor("OAT") == 1.2 and H.cropFactor("SOYBEAN") == 1.8 and H.cropFactor("PEA") == 1.7)
check("substring match: OATS, RICE_LONG_GRAIN, PEAS", H.cropFactor("OATS") == 1.2 and H.cropFactor("RICE_LONG_GRAIN") == 1.1 and H.cropFactor("PEAS") == 1.7)
check("longest key wins (sunflower is not 'flax' or 'sun')", H.cropFactor("SUNFLOWER") == 1.5)
check("an unlisted crop is 1.0", H.cropFactor("UNOBTANIUM") == 1.0 and H.cropFactor(nil) == 1.0)
check("crops added by the port: mustard like canola, beans like soybean", H.cropFactor("MUSTARD") == 2.0 and H.cropFactor("BEANS") == 1.8)

print("=== 4. folded into upstream's total and its 'speed' bucket ===")
local c = calc("WHEAT"); local total = c:calculateTotalCropLoss(at(12))
local hl = H.compute("WHEAT", 12)
check("total = upstream's 3.5 + header loss", near(total, 3.5 + hl), string.format("%.3f", total))
check("the speed bucket (baseLoss) carries it", near(c.baseLoss, 2.0 + hl) and near(c.overloadLoss, 2.0 + hl))
check("upstream's breakdown reports it as speed loss", near(c:getLossBreakdown().speedPct, 2.0 + hl))
check("all three total fields agree", near(c.totalLoss, total) and near(c.totalCropLoss, total) and near(c.cropLoss, total))
check("headerLoss field exposed", near(c.headerLoss, hl))
local again = c:calculateTotalCropLoss(at(12))
check("calling twice does not compound (upstream recomputes its fields)", near(again, total) and near(c.baseLoss, 2.0 + hl))
local slow = calc("WHEAT"); local t2 = slow:calculateTotalCropLoss(at(8))
check("below the threshold: upstream's total untouched, headerLoss 0", near(t2, 3.5) and slow.headerLoss == 0 and near(slow.baseLoss, 2.0))
local capped = calc("WHEAT", "grain", { _total = 48 }); local t3 = capped:calculateTotalCropLoss(at(60))
check("stays inside upstream's 50 % cap", t3 <= 50 and t3 > 48)

print("=== 5. same gating as upstream's own loss ===")
local s = g_realisticHarvestManager.settings
s.enableCropLoss = false
check("crop loss disabled: untouched", near(calc("WHEAT"):calculateTotalCropLoss(at(12)), 3.5))
s.enableCropLoss = true; s.difficultyLoss = 1
check("Arcade loss difficulty: untouched", near(calc("WHEAT"):calculateTotalCropLoss(at(12)), 3.5))
s.difficultyLoss = 2
check("forage machine: untouched", near(calc("GRASS", "forage"):calculateTotalCropLoss(at(12)), 3.5))
check("root machine: untouched", near(calc("POTATO", "root"):calculateTotalCropLoss(at(12)), 3.5))
check("no vehicle / no speed accessor: untouched", near(calc("WHEAT"):calculateTotalCropLoss(nil), 3.5) and near(calc("WHEAT"):calculateTotalCropLoss({}), 3.5))
TrainingMode = { suppressLossPhysics = function() return true end }
check("Training mode: untouched (the sandbox has no loss)", near(calc("WHEAT"):calculateTotalCropLoss(at(12)), 3.5))
TrainingMode = nil
H.enabled = false
check("switched off: untouched", near(calc("WHEAT"):calculateTotalCropLoss(at(12)), 3.5))
H.enabled = true
check("...and back on", calc("WHEAT"):calculateTotalCropLoss(at(12)) > 3.5)

print("=== 6. console ===")
RHM_RealisticHarvestManager.new()
local has = false; for _, n in ipairs(commands) do if n == "rhmHeaderLoss" then has = true end end
check("rhmHeaderLoss registered", has)
check("off / on / status", H.consoleCommand(nil, "off"):find("OFF") ~= nil and H.consoleCommand(nil, "on"):find("ON") ~= nil and H.consoleCommand(nil, "status"):find("9.7") ~= nil)
check("usage on garbage", H.consoleCommand(nil, "maybe"):find("Usage") ~= nil)
g_realisticHarvestManager.lastActiveCombine = { spec_rhm_Combine = { loadCalculator = { headerLoss = 1.234 } } }
check("shows the active machine's current loss", H.consoleCommand(nil, ""):find("1.23") ~= nil)

print("=== 7. a missing upstream method disables, never throws ===")
do
    local w0 = #warnings
    local saved = RHM_LoadCalculator.calculateTotalCropLoss
    RHM_LoadCalculator.calculateTotalCropLoss = nil
    local ok = pcall(dofile, "src/fork/HeaderLoss.lua")
    RHM_LoadCalculator.calculateTotalCropLoss = saved
    check("re-loading without the method does not throw", ok)
    check("...and says so", #warnings > w0, warnings[#warnings] or "")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
