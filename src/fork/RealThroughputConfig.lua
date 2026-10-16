-- EN: Real-throughput curve config. Reads cropThroughput.xml and derives, for each crop, a
--     power-law throughput curve from two real-world anchor points:
--
--         grain   buPerHrMin @ 280 hp  (AEM Class 6)    buPerHrMax @ 775 hp  (AEM Class 11, Case IH AF11)
--         forage  tPerHrMin  @ 400 hp                   tPerHrMax  @ 950 hp  (Jaguar 990 / JD 9900 class)
--
--         throughput_kg_s = A * hp ^ B
--
--     B > 1 is expected and intended: a Class 11 is not merely "more horsepower" than a Class 6,
--     it also has a far larger cleaning shoe and separation area, so it turns each horsepower
--     into more bushels. This is the one thing a linear HP-per-t/h constant cannot express.
--
--     Carried over from the fork's src/config/CropThroughputConfig.lua. Differences: it owns its
--     USDA bushel table (the fork read it from its own UnitConverter, which upstream does not
--     have), and it loads lazily on first use instead of from main.lua, so upstream's main.lua
--     needs no extra hook.
--
--     Load priority:
--         1. <profile>/modSettings/FS25_RealisticHarvesting/cropThroughput.xml   (user override)
--         2. <mod dir>/cropThroughput.xml                                         (bundled default)
--
-- UA: Конфігурація кривих реальної продуктивності. Читає cropThroughput.xml і для кожної культури
--     будує степеневу криву з двох реальних опорних точок. B > 1 — очікувано: більший комбайн має
--     значно більше решето та площу сепарації, тож перетворює кожну к.с. на більше бушелів.
--     Перенесено з форку; власна таблиця ваги бушеля, завантаження — ліниве (без хука в main.lua).
RealThroughputConfig = {}

-- EN: Captured at source time. By the time load() runs (mid-mission), g_currentModDirectory
--     belongs to whichever mod loaded last, so building the bundled path from it would fail.
-- UA: Зберігаємо директорію мода під час завантаження файлу; пізніше g_currentModDirectory — чужий.
local MOD_DIR = g_currentModDirectory or ""

RealThroughputConfig.HP_MIN, RealThroughputConfig.HP_MAX = 280.0, 775.0
RealThroughputConfig.HP_MIN_FORAGE, RealThroughputConfig.HP_MAX_FORAGE = 400.0, 950.0
RealThroughputConfig.REF_HP = 400.0   -- EN: single-point mode (buPerHrRef) is treated as this hp

RealThroughputConfig._grain   = {}    -- cropKey -> { coef = A, exp = B }
RealThroughputConfig._forage  = {}
RealThroughputConfig._loaded  = false
RealThroughputConfig._source  = "none"

-- EN: USDA test weights (lb/bu). Same values as the fork's UnitConverter.BUSHEL_LBS, which is the
--     single source of truth there; kept as a separate copy here because upstream's converter has
--     no bushel table. If a weight changes, change it in both places.
-- UA: Стандартні ваги бушеля USDA. Ті самі значення, що у форку; окрема копія, бо у оригіналу
--     такої таблиці немає.
RealThroughputConfig.BUSHEL_LBS = {
    WHEAT = 60, BARLEY = 48, OAT = 32, RYE = 56,
    RICE = 45, RICELONGGRAIN = 45,
    SORGHUM = 56, MAIZE = 56,
    SOYBEAN = 60, CANOLA = 50, SUNFLOWER = 25,
    PEA = 60, LENTIL = 60, CHICKPEA = 60,
    COTTON = 32, SUGARBEET = 60, POTATO = 60,
}

-- EN: The XML uses the farmer-facing name "corn"; FS25 and the weight table call it MAIZE.
local BUSHEL_ALIASES = { CORN = "MAIZE" }

local LBS_PER_KG = 2.20462
local US_TON_KG  = 907.185

-- EN: Unlisted (mod) crops fall back to corn's weight, a safe middle.
function RealThroughputConfig.bushelLbs(cropKey)
    local key = tostring(cropKey):upper()
    key = BUSHEL_ALIASES[key] or key
    return RealThroughputConfig.BUSHEL_LBS[key] or 56
end

function RealThroughputConfig.buPerHrToKgPerSec(buPerHr, cropKey)
    return (buPerHr * RealThroughputConfig.bushelLbs(cropKey) / LBS_PER_KG) / 3600.0
end

-- EN: Solve throughput = A * hp^B through (hpMin, kgsMin) and (hpMax, kgsMax).
-- UA: Знаходимо A та B за двома опорними точками.
function RealThroughputConfig.deriveCurve(kgsMin, kgsMax, hpMin, hpMax)
    if not (kgsMin and kgsMax) or kgsMin <= 0 or kgsMax <= 0 then return nil end
    local B = math.log(kgsMax / kgsMin) / math.log(hpMax / hpMin)
    local A = kgsMin / (hpMin ^ B)
    if A > 0 and B > 0 then return { coef = A, exp = B } end
    return nil
end

function RealThroughputConfig.curveKgPerSec(params, hp)
    return params.coef * (hp ^ params.exp)
end

local function getConfigPath()
    if getUserProfileAppPath then
        local userPath = getUserProfileAppPath() .. "modSettings/FS25_RealisticHarvesting/cropThroughput.xml"
        if fileExists(userPath) then return userPath, "user" end
    end
    local bundled = MOD_DIR .. "cropThroughput.xml"
    if fileExists(bundled) then return bundled, "bundled" end
    return nil, "none"
end

-- EN: Parse the XML. Safe to call repeatedly; replaces whatever was loaded before.
--     The <moistureSettings> block in the same file is ignored on this branch: upstream has its
--     own moisture model (per-crop limits live in its settings database).
-- UA: Розбір XML. Блок <moistureSettings> тут ігнорується — у оригіналу власна модель вологості.
function RealThroughputConfig.load()
    RealThroughputConfig._grain, RealThroughputConfig._forage = {}, {}
    RealThroughputConfig._loaded, RealThroughputConfig._source = true, "none"

    local path, source = getConfigPath()
    if not path then
        Logging.warning("[RHM-fork] RealThroughput: cropThroughput.xml not found — upstream energy model stays in force")
        return
    end

    local xmlFile = loadXMLFile("RealThroughputConfig", path)
    if not xmlFile or xmlFile == 0 then
        Logging.warning("[RHM-fork] RealThroughput: failed to parse %s", path)
        return
    end

    local C = RealThroughputConfig
    local count, i = 0, 0
    while true do
        local key = string.format("cropThroughput.crop(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end

        local name  = getXMLString(xmlFile, key .. "#name")
        local buMin = getXMLFloat(xmlFile, key .. "#buPerHrMin")
        local buMax = getXMLFloat(xmlFile, key .. "#buPerHrMax")
        local buRef = getXMLFloat(xmlFile, key .. "#buPerHrRef")
        local tMin  = getXMLFloat(xmlFile, key .. "#tPerHrMin")
        local tMax  = getXMLFloat(xmlFile, key .. "#tPerHrMax")

        if name then
            local cropKey = name:lower()
            if tMin and tMax and tMin > 0 and tMax > 0 then
                -- EN: Forage — US short tons/hr at the forage anchor horsepowers.
                local curve = C.deriveCurve(tMin * US_TON_KG / 3600, tMax * US_TON_KG / 3600,
                                            C.HP_MIN_FORAGE, C.HP_MAX_FORAGE)
                if curve then C._forage[cropKey] = curve; count = count + 1 end
            elseif buMin and buMax and buMin > 0 and buMax > 0 then
                local curve = C.deriveCurve(C.buPerHrToKgPerSec(buMin, cropKey),
                                            C.buPerHrToKgPerSec(buMax, cropKey), C.HP_MIN, C.HP_MAX)
                if curve then C._grain[cropKey] = curve; count = count + 1 end
            elseif buRef and buRef > 0 then
                -- EN: Single reference point at REF_HP with a fixed exponent of 0.75.
                local A = C.buPerHrToKgPerSec(buRef, cropKey) / (C.REF_HP ^ 0.75)
                C._grain[cropKey] = { coef = A, exp = 0.75 }
                count = count + 1
            end
        end
        i = i + 1
    end

    delete(xmlFile)
    RealThroughputConfig._source = source
    if rhm_log then rhm_log(string.format("RHM [RealThroughput]: loaded %d crop curve(s) from %s config", count, source)) end
end

function RealThroughputConfig.ensureLoaded()
    if not RealThroughputConfig._loaded then RealThroughputConfig.load() end
end

-- EN: Look a crop up by name, tolerant of the spellings the engine and the settings database use:
--     case, underscores (RICE_LONG_GRAIN vs riceLongGrain), plural "oats", and corn/maize.
-- UA: Пошук за назвою, стійкий до різних написань: регістр, підкреслення, "oats", corn/maize.
local function lookup(tbl, cropName)
    if not cropName then return nil end
    local key = tostring(cropName):lower()
    local hit = tbl[key]
    if hit then return hit end

    local stripped = key:gsub("_", "")
    hit = tbl[stripped]
    if hit then return hit end

    local suffixless = key:match("^(.-)_windrow$") or key:match("^(.-)_chopped$") or key:match("^(.-)_forage$")
    if suffixless and tbl[suffixless] then return tbl[suffixless] end

    if stripped == "oats" then return tbl.oat end
    if stripped == "maize" then return tbl.corn end
    if stripped == "corn"  then return tbl.maize end
    return nil
end

function RealThroughputConfig.getGrainCurve(cropName)
    RealThroughputConfig.ensureLoaded()
    return lookup(RealThroughputConfig._grain, cropName)
end

function RealThroughputConfig.getForageCurve(cropName)
    RealThroughputConfig.ensureLoaded()
    return lookup(RealThroughputConfig._forage, cropName)
end
