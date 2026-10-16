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
    -- Crops added by the port. Used only to label bu/hr in `rhmThroughputTable`: these crops are
    -- defined by mass ("like" another crop), so the weight cannot change what a machine does.
    TRITICALE = 48, SPELT = 40, MILLET = 50, BUCKWHEAT = 48,
    LINSEED = 56, FLAX = 56, MUSTARD = 50, SAFFLOWER = 40, POPPY = 46, HEMP = 44,
    GRASS_SEED = 20, CLOVER = 60, BEANS = 60, BEAN = 60,
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
    local relatives = {}   -- crops defined as "like" another, resolved after every explicit anchor is in
    while true do
        local key = string.format("cropThroughput.crop(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end

        local name  = getXMLString(xmlFile, key .. "#name")
        local buMin = getXMLFloat(xmlFile, key .. "#buPerHrMin")
        local buMax = getXMLFloat(xmlFile, key .. "#buPerHrMax")
        local buRef = getXMLFloat(xmlFile, key .. "#buPerHrRef")
        local tMin  = getXMLFloat(xmlFile, key .. "#tPerHrMin")
        local tMax  = getXMLFloat(xmlFile, key .. "#tPerHrMax")
        local like   = getXMLString(xmlFile, key .. "#like")
        local factor = getXMLFloat(xmlFile, key .. "#factor")
        local kind   = getXMLString(xmlFile, key .. "#kind")

        if name and like and factor and factor > 0
            and not (buMin or buMax or buRef or tMin or tMax) then
            -- EN: "Like" form: this crop's throughput is `factor` x another crop's, at every
            --     horsepower. Same curve shape (same exponent), so a derived crop stays in step
            --     with its reference if the reference is retuned. kind="forage" looks the
            --     reference up among the forage anchors; the default is the grain anchors.
            -- UA: Форма "like": продуктивність культури = factor x продуктивність іншої на будь-яких
            --     к.с. Та сама форма кривої; kind="forage" шукає еталон серед форажних.
            relatives[#relatives + 1] = { name = name:lower(), like = like:lower(), factor = factor,
                                          forage = (kind == "forage") }
        elseif name then
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

    -- EN: Resolve "like" crops. A crop may only be like an EXPLICITLY anchored one (no chains),
    --     which keeps resolution order-independent and makes a typo fail loudly, not quietly.
    -- UA: Розв'язуємо "like": еталоном може бути лише явно задана культура (без ланцюжків).
    for _, r in ipairs(relatives) do
        local pool = r.forage and C._forage or C._grain
        local ref = pool[r.like]
        if ref then
            pool[r.name] = { coef = ref.coef * r.factor, exp = ref.exp }
            count = count + 1
        else
            Logging.warning("[RHM-fork] RealThroughput: crop '%s' is like '%s' (%s), which has no anchor — skipped",
                r.name, r.like, r.forage and "forage" or "grain")
        end
    end

    -- EN: The <moistureSettings> block lives in the same file; hand it to the moisture model while open.
    -- UA: Блок <moistureSettings> лежить у тому ж файлі; передаємо його моделі вологості, поки файл відкритий.
    if MoistureModel and MoistureModel.loadFromXML then
        MoistureModel.loadFromXML(xmlFile)
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
-- EN: Names that mean the same crop. Tried only when the name itself has no entry, so an explicit
--     entry always wins over an alias.
local ALIASES = {
    oats = "oat", peas = "pea", lucerne = "alfalfa",
    flax = "linseed", linseed = "flax",
    maize = "corn", corn = "maize",
}

local function lookup(tbl, cropName)
    if not cropName then return nil end
    local key = tostring(cropName):lower()

    -- EN: Candidate spellings, most specific first: as given; without underscores
    --     (RICE_LONG_GRAIN vs riceLongGrain); without a windrow/chopped/forage suffix.
    local candidates = { key, (key:gsub("_", "")) }
    local base = key:match("^(.-)_windrow$") or key:match("^(.-)_chopped$") or key:match("^(.-)_forage$")
    if base then
        candidates[#candidates + 1] = base
        candidates[#candidates + 1] = (base:gsub("_", ""))
    end

    for _, c in ipairs(candidates) do
        if tbl[c] then return tbl[c] end
    end
    for _, c in ipairs(candidates) do
        local alias = ALIASES[c]
        if alias and tbl[alias] then return tbl[alias] end
    end
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
