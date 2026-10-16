-- Headless harness for the real-throughput overlay (src/fork/RealThroughput*.lua).
-- Loads the REAL config + overlay modules and the REAL bundled cropThroughput.xml (parsed by a
-- tiny stand-in for the engine's XML API) against a stub shaped like upstream's load calculator.
-- Run from the mod root:  lua tests/throughputtest.lua
--
-- Guards the properties the anchors exist to encode, plus the overlay's contract with upstream:
--   * the derived curves pass exactly through the anchors
--   * the derived specific energy makes a class-matched machine read 100 % at rated throughput
--   * an oversized header pushes the gauge past 100 %; a light one never lets it fall short
--   * upstream's yield adaptation is recovered, not replaced
--   * anything the overlay does not own falls straight through to upstream

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }
function addConsoleCommand() end

-- ---- stand-in for the engine XML API, backed by the real bundled file ----
local function readAll(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
local xmlText = readAll("cropThroughput.xml")
xmlText = xmlText:gsub("<!%-%-.-%-%->", "")                       -- comments
xmlText = xmlText:gsub("<moistureSettings.-</moistureSettings>", "") -- not our nodes
local crops = {}
for attrs in xmlText:gmatch("<crop%s+(.-)/>") do
    local t = {}
    for k, v in attrs:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do t[k] = v end
    crops[#crops + 1] = t
end
local handles = {}
function fileExists(p) return p:find("cropThroughput.xml", 1, true) ~= nil end
function loadXMLFile() handles[1] = crops; return 1 end
function delete() end
local function node(key) return tonumber(key:match("crop%((%d+)%)")) end
function hasXMLProperty(_, key) return crops[node(key) + 1] ~= nil end
function getXMLString(_, key) return crops[node(key) + 1][key:match("#(.+)$")] end
function getXMLFloat(_, key) return tonumber(crops[node(key) + 1][key:match("#(.+)$")]) end
g_currentModDirectory = "./"

-- ---- upstream-shaped load calculator stub ----
-- getCropSpecificEnergy mimics upstream: constant * yieldFactor, where yieldFactor is 1.0 when
-- there is no live yield (it falls back to the crop reference yield) - the property the overlay
-- relies on to recover upstream's factor.
RHM_LoadCalculator = {}
local UP_CONST = { WHEAT = 4.8, CORN = 3.8, MAIZE = 3.8, RYE = 5.2, GRASS = 3.1 }
local YIELD_REF = 10
function RHM_LoadCalculator:getCropSpecificEnergy(fruitTypeIndex, fillTypeIndex, machineType, isPickup, isForageCutter)
    local name = self._testCrop or "WHEAT"
    local base = UP_CONST[name] or 6.0
    if machineType == "root" then base = 2.1 end
    if isPickup then base = 2.2 end
    local actual = self.currentYield or 0
    if actual < 0.5 then actual = YIELD_REF end
    local factor = math.max(0.45, math.min(1.25, (YIELD_REF / actual) ^ 0.7))
    return base * factor
end
function RHM_LoadCalculator:getEnginePowerHp() return self._testHp or 775 end
function RHM_LoadCalculator:calculateEngineLoad(vehicle)
    self.sawVehicle = self._rtVehicle                        -- what the overlay stashed for this tick
    self.lastE = self:getCropSpecificEnergy(0, 0, self._machine or "grain", self._pickup, self._forageCutter)
end
-- the overlay resolves names from the engine's managers; stub them to return our test crop
g_fruitTypeManager = { getFruitTypeByIndex = function(_, idx) return idx and idx ~= 0 and { name = idx } or nil end }
g_fillTypeManager  = { getFillTypeByIndex  = function(_, idx) return idx and idx ~= 0 and { name = idx } or nil end }
RHM_RealisticHarvestManager = { new = function() return {} end }

dofile("src/fork/RealThroughputConfig.lua")
dofile("src/fork/RealThroughput.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-60s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-60s %s", name, detail or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
local C = RealThroughputConfig
local LBS_PER_KG = 2.20462
local function buHr(curve, hp, crop) return C.curveKgPerSec(curve, hp) * 3600 * LBS_PER_KG / C.bushelLbs(crop) end

print("=== 1. config loads from the bundled XML ===")
C.load()
check("source is bundled", C._source == "bundled", C._source)
check("no load warnings", #warnings == 0, warnings[1] or "")
local nG = 0; for _ in pairs(C._grain) do nG = nG + 1 end
local nF = 0; for _ in pairs(C._forage) do nF = nF + 1 end
check("grain + forage curves present", nG >= 10 and nF >= 10, nG .. " grain, " .. nF .. " forage")

print("=== 2. curves pass exactly through the anchors ===")
for _, row in ipairs({ { "wheat", 1200, 3600 }, { "corn", 2200, 10000 }, { "soybean", 800, 3200 }, { "canola", 700, 1800 } }) do
    local crop, mn, mx = row[1], row[2], row[3]
    local c = C.getGrainCurve(crop)
    check(crop .. " @ 280 hp = " .. mn .. " bu/hr", near(buHr(c, 280, crop), mn, 0.5), string.format("%.1f", buHr(c, 280, crop)))
    check(crop .. " @ 775 hp = " .. mx .. " bu/hr", near(buHr(c, 775, crop), mx, 0.5), string.format("%.1f", buHr(c, 775, crop)))
end
local fm = C.getForageCurve("maize")
check("forage maize @ 950 hp = 455 US t/hr", near(C.curveKgPerSec(fm, 950) * 3600 / 907.185, 455, 0.1))

print("=== 3. anchor properties the fork locked ===")
-- Small grains are shoe-limited: their exponents sit in one band, and bulkier barley must not
-- out-mass wheat (caught a wheat max anchor of 2500 that left B at 0.72 against siblings ~0.97).
local wB, bB, oB = C.getGrainCurve("wheat").exp, C.getGrainCurve("barley").exp, C.getGrainCurve("oat").exp
check("wheat exponent within 0.25 of barley and oat", math.abs(wB - bB) <= 0.25 and math.abs(wB - oB) <= 0.25,
    string.format("wheat %.3f barley %.3f oat %.3f", wB, bB, oB))
for _, hp in ipairs({ 400, 555, 775 }) do
    local w = C.curveKgPerSec(C.getGrainCurve("wheat"), hp) * 3.6
    local b = C.curveKgPerSec(C.getGrainCurve("barley"), hp) * 3.6
    check("wheat out-masses barley at " .. hp .. " hp", w > b, string.format("%.1f vs %.1f t/h", w, b))
end
check("corn exponent > 1 (big machines more productive per hp)", C.getGrainCurve("corn").exp > 1,
    string.format("B = %.3f", C.getGrainCurve("corn").exp))

print("=== 4. name lookup tolerates engine spellings ===")
check("MAIZE resolves to the corn grain curve", C.getGrainCurve("MAIZE") == C.getGrainCurve("corn"))
check("RICELONGGRAIN resolves", C.getGrainCurve("RICELONGGRAIN") ~= nil)
check("RICE_LONG_GRAIN resolves (underscored database spelling)", C.getGrainCurve("RICE_LONG_GRAIN") == C.getGrainCurve("RICELONGGRAIN"))
check("OATS resolves to oat", C.getGrainCurve("OATS") == C.getGrainCurve("oat"))
check("GRASS_WINDROW resolves to the forage grass curve", C.getForageCurve("GRASS_WINDROW") == C.getForageCurve("grass"))
check("unknown crop -> nil", C.getGrainCurve("UNOBTANIUM") == nil)

print("=== 5. derived energy makes a matched machine read 100 % at rated ===")
local R = RealThroughput
for _, hp in ipairs({ 280, 400, 555, 775 }) do
    local wheat = C.getGrainCurve("wheat")
    local rated = C.curveKgPerSec(wheat, hp)
    local base = 0.08
    local hdr = R.headerRefFraction(hp) * hp                    -- class-matched header
    local e = R.processingEnergy(rated, hp, base, hdr)
    local gauge = (base * hp + hdr + e * rated * 3.6) / hp
    check(string.format("%d hp wheat: gauge = 100%% at rated", hp), near(gauge, 1.0, 1e-9), string.format("%.6f", gauge))
end
do
    local hp, wheat = 775, C.getGrainCurve("wheat")
    local rated = C.curveKgPerSec(wheat, hp)
    local e = R.processingEnergy(rated, hp, 0.08, R.headerRefFraction(hp) * hp)
    local over = (0.08 * hp + 2.0 * R.headerRefFraction(hp) * hp + e * rated * 3.6) / hp
    check("oversized header: gauge > 100 % at rated", over > 1.0, string.format("%.1f%%", over * 100))
    local eLight = R.processingEnergy(rated, hp, 0.08, 0.5 * R.headerRefFraction(hp) * hp)
    local light = (0.08 * hp + 0.5 * R.headerRefFraction(hp) * hp + eLight * rated * 3.6) / hp
    check("light header: gauge still exactly 100 % at rated (never short)", near(light, 1.0, 1e-9), string.format("%.6f", light))
    check("light header gets MORE energy per t/h than matched", eLight > e)
end

print("=== 6. hook: anchored crops ===")
local calc = setmetatable({ _testCrop = "WHEAT", headerHp = 0.15 * 775 }, { __index = RHM_LoadCalculator })
local veh = { spec_rhm_Combine = { threshingType = "rotor" } }
calc:calculateEngineLoad(veh)
check("calculateEngineLoad stashes the vehicle for the seam", calc.sawVehicle == veh)
local eUp = UP_CONST.WHEAT
-- the stub resolves crop name from fruit type idx: pass the name as the "index" via _testCrop path
-- (the overlay calls the managers; the stub managers echo whatever it passes). Drive the seam directly:
local function energy(c, crop, machine, pickup, forageCutter)
    c._testCrop = crop
    c._rtVehicle = veh
    return c:getCropSpecificEnergy(crop, 0, machine or "grain", pickup, forageCutter)
end
local e1 = energy(calc, "WHEAT")
local expected = R.processingEnergy(C.curveKgPerSec(C.getGrainCurve("wheat"), 775), 775,
    R.baseLossFraction(calc, veh, "grain"), calc.headerHp)
check("wheat uses the anchored energy (yield factor 1 at reference)", near(e1, expected, 1e-9),
    string.format("%.3f vs upstream %.3f", e1, eUp))
check("anchored wheat differs from upstream's constant", math.abs(e1 - eUp) > 0.05)
check("rotor machine uses 11 % base loss", R.baseLossFraction(calc, veh, "grain") == 0.11)

print("=== 7. hook: upstream's yield adaptation is recovered ===")
calc.currentYield = 20      -- double the reference -> upstream factor < 1
local e2 = energy(calc, "WHEAT")
local upFactor = (YIELD_REF / 20) ^ 0.7
check("high yield scales the anchored energy by upstream's own factor", near(e2, expected * upFactor, 1e-9),
    string.format("%.3f vs %.3f", e2, expected * upFactor))
check("live yield is restored after the probe", calc.currentYield == 20)
calc.currentYield = 4       -- thin stand -> factor > 1
check("thin stand raises energy per t/h", energy(calc, "WHEAT") > expected)
calc.currentYield = nil

print("=== 8. hook falls through to upstream wherever it owns nothing ===")
check("crop with no anchor -> upstream (unlisted mod crop)", near(energy(calc, "UNOBTANIUM"), 6.0))
check("rye IS anchored now (relative to wheat), no longer upstream's constant", math.abs(energy(calc, "RYE") - UP_CONST.RYE) > 0.05)
check("root machine -> upstream", near(energy(calc, "WHEAT", "root"), 2.1))
check("grain combine on a pickup -> upstream", near(energy(calc, "WHEAT", "grain", true), 2.2))
check("cotton machine -> upstream", near(energy(calc, "WHEAT", "cotton"), UP_CONST.WHEAT))
local noVeh = setmetatable({ _testCrop = "WHEAT" }, { __index = RHM_LoadCalculator })
check("no vehicle stashed (call outside a load tick) -> upstream", near(noVeh:getCropSpecificEnergy("WHEAT", 0, "grain"), UP_CONST.WHEAT))
RealThroughput.enabled = false
check("switch off -> upstream", near(energy(calc, "WHEAT"), UP_CONST.WHEAT))
RealThroughput.enabled = true
check("switch back on -> anchored again", near(energy(calc, "WHEAT"), expected, 1e-9))

print("=== 9. forage path ===")
local fcalc = setmetatable({ headerHp = 200 }, { __index = RHM_LoadCalculator })
fcalc._testHp = 650
local ef = energy(fcalc, "MAIZE", "forage")
local rf = C.curveKgPerSec(C.getForageCurve("maize"), 650)
check("forage maize anchored", near(ef, R.processingEnergy(rf, 650, 0.09, 200), 1e-9), string.format("E %.2f HP/(t/h)", ef))
check("forage energy is not upstream's constant", math.abs(ef - UP_CONST.MAIZE) > 0.05)
check("forage uses 9 % base loss", R.baseLossFraction(fcalc, veh, "forage") == 0.09)
-- A forage cutter on a GRAIN-typed machine takes the forage curve, but upstream's P_base still
-- keys on machineType, so the base-loss fraction must follow the machine type (rotor -> 11 %).
local efc = energy(fcalc, "MAIZE", "grain", false, true)
check("isForageCutter on a grain machine takes the forage curve with that machine's base loss",
    near(efc, R.processingEnergy(rf, 650, R.baseLossFraction(fcalc, veh, "grain"), 200), 1e-9),
    string.format("E %.2f", efc))

print("=== 10. sanity window protects against bad config ===")
local saved = C._grain.wheat
C._grain.wheat = { coef = 1e-9, exp = 1.0 }                -- absurdly slow machine -> E huge
check("absurdly low anchor -> upstream", near(energy(calc, "WHEAT"), UP_CONST.WHEAT))
C._grain.wheat = { coef = 1e3, exp = 1.0 }                 -- absurdly fast machine -> E tiny
check("absurdly high anchor -> upstream", near(energy(calc, "WHEAT"), UP_CONST.WHEAT))
C._grain.wheat = saved

print("=== 11. hook order: a missing upstream method disables, never throws ===")
local w0 = #warnings
local ok = pcall(function()
    local saveG = RHM_LoadCalculator.getCropSpecificEnergy
    -- re-source with the method absent
    RHM_LoadCalculator.getCropSpecificEnergy = nil
    dofile("src/fork/RealThroughput.lua")
    RHM_LoadCalculator.getCropSpecificEnergy = saveG
end)
check("missing method does not throw", ok)
check("missing method is logged", #warnings > w0, warnings[#warnings] or "")

print("=== 12. relative anchors (\"like\" crops) ===")
C.load()
-- name, reference, factor, forage?  - mirrors the block at the end of cropThroughput.xml
local relatives = {
    { "rye", "wheat", 0.90 }, { "triticale", "wheat", 0.95 }, { "spelt", "wheat", 0.80 },
    { "millet", "wheat", 0.55 }, { "buckwheat", "wheat", 0.50 },
    { "mustard", "canola", 1.00 }, { "linseed", "canola", 0.85 }, { "safflower", "canola", 0.85 },
    { "poppy", "canola", 0.60 }, { "hemp", "canola", 0.55 }, { "grass_seed", "canola", 0.30 },
    { "clover", "canola", 0.35 }, { "beans", "soybean", 1.00 }, { "bean", "soybean", 1.00 },
    { "poplar", "woodchips", 1.00, true }, { "meadow", "grass", 1.00, true },
    { "silage", "maize", 1.00, true }, { "gps", "maize", 1.00, true }, { "hay", "drygrass", 1.00, true },
}
local allRelativesOk = true
for _, r in ipairs(relatives) do
    local get = r[4] and C.getForageCurve or C.getGrainCurve
    local d, ref = get(r[1]), get(r[2])
    local ok = d and ref and near(d.exp, ref.exp, 1e-12) and near(d.coef / ref.coef, r[3], 1e-9)
    if not ok then allRelativesOk = false; print("  FAIL  " .. r[1] .. " is not " .. r[3] .. " x " .. r[2]) end
end
check("every relative crop = factor x reference, same exponent", allRelativesOk, #relatives .. " crops")
do
    local rye, wheat = C.getGrainCurve("rye"), C.getGrainCurve("wheat")
    for _, hp in ipairs({ 280, 555, 775 }) do
        check("rye mass at " .. hp .. " hp = 0.90 x wheat",
            near(C.curveKgPerSec(rye, hp), 0.90 * C.curveKgPerSec(wheat, hp), 1e-9))
    end
    check("rye no longer out-produces wheat", C.curveKgPerSec(rye, 775) < C.curveKgPerSec(wheat, 775))
    check("flax resolves to linseed", C.getGrainCurve("FLAX") == C.getGrainCurve("linseed"))
    check("LUCERNE_WINDROW resolves to the alfalfa forage curve", C.getForageCurve("LUCERNE_WINDROW") == C.getForageCurve("alfalfa"))
    check("MAIZE_FORAGE resolves to the maize forage curve", C.getForageCurve("MAIZE_FORAGE") == C.getForageCurve("maize"))
end
-- A relative crop must have a defined reference; a typo is skipped with a warning, never fatal.
do
    local w0 = #warnings
    crops[#crops + 1] = { name = "typo", like = "whaet", factor = "0.9" }
    local ok2 = pcall(C.load)
    check("a 'like' pointing at a missing crop is skipped, not fatal", ok2 and C.getGrainCurve("typo") == nil)
    check("...and is logged", #warnings > w0, warnings[#warnings] or "")
    crops[#crops] = nil
    C.load()
end

print("=== 13. every crop upstream knows has an anchor ===")
-- Reads upstream's own crop registry, so a crop added upstream later fails here until it is anchored.
do
    local f = assert(io.open("src/data/RHM_CombineSettingsDatabase.lua", "rb"))
    local src = f:read("*a"); f:close()
    local grain, forage = {}, {}
    for name, mt in src:gmatch('%["([A-Z_]+)"%]%s*=%s*{%s*machineType%s*=%s*"(%w+)"') do
        if mt == "grain" then grain[#grain + 1] = name elseif mt == "forage" then forage[#forage + 1] = name end
    end
    check("registry parsed (sanity)", #grain >= 25 and #forage >= 8, #grain .. " grain, " .. #forage .. " forage")
    local missingG, missingF = {}, {}
    for _, n in ipairs(grain)  do if not C.getGrainCurve(n)  then missingG[#missingG + 1] = n end end
    for _, n in ipairs(forage) do if not C.getForageCurve(n) then missingF[#missingF + 1] = n end end
    check("every grain-machine crop has an anchor", #missingG == 0, #missingG > 0 and ("MISSING: " .. table.concat(missingG, ", ")) or "")
    check("every forage crop has an anchor", #missingF == 0, #missingF > 0 and ("MISSING: " .. table.concat(missingF, ", ")) or "")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
