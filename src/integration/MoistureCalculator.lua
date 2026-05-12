-- EN: Per-crop moisture threshold table and factor calculators for the FS25 MoistureSystem
--     integration. All functions are pure (no FS25 API calls at runtime) so they can be
--     called freely from LoadCalculator, rhm_Combine, and DraggableHUD without side effects.
--
--     Effect model:
--       • Below target moisture  → slight bonus (dry grain is easier to thresh and lighter)
--       • target → max moisture  → linear/curved ramp from 1.0 to the configured maximum
--       • Above max moisture     → factors are capped at their maximum (no infinite penalty)
--
--     Three independent effect channels, each with its own enable flag:
--       enableLoad  — raises effective engine load (wet crop is harder to thresh)
--       enableLoss  — raises grain loss on sieves/rotor (wet grain doesn't separate cleanly)
--       enableSpeed — lowers the recommended-speed cap (wet standing crop resists the header)
--
--     All thresholds and scale factors are readable from the cropThroughput.xml
--     <moistureSettings> block so they can be tuned without a code change.
--
-- UA: Таблиця порогів вологості по культурах та калькулятори коефіцієнтів для інтеграції
--     з FS25 MoistureSystem. Всі функції чисті (немає викликів FS25 API під час виконання).

MoistureCalculator = {}

-- ---------------------------------------------------------------------------
-- EN: Per-crop harvest moisture thresholds (USDA / industry standard).
--     target = ideal harvest moisture % — factors start climbing above this.
--     max    = practical ceiling % — factors are capped at this point.
--     These are the built-in defaults; all values can be overridden from XML.
-- UA: Порогові значення вологості при збиранні (USDA / галузевий стандарт).
-- ---------------------------------------------------------------------------
MoistureCalculator.CROP_THRESHOLDS = {
    -- EN: Small grains / UA: Дрібні зернові
    WHEAT         = { target = 13.5, max = 20.0 },
    BARLEY        = { target = 13.5, max = 20.0 },
    OAT           = { target = 13.0, max = 18.0 },
    RYE           = { target = 13.5, max = 20.0 },
    SPELT         = { target = 13.5, max = 20.0 },
    TRITICALE     = { target = 13.5, max = 20.0 },
    MILLET        = { target = 13.5, max = 20.0 },

    -- EN: Coarse grains / UA: Крупні зернові
    MAIZE         = { target = 15.5, max = 28.0 },  -- EN: Also covers CORN alias
    CORN          = { target = 15.5, max = 28.0 },
    SORGHUM       = { target = 14.0, max = 25.0 },

    -- EN: Oilseeds / UA: Олійні культури
    SOYBEAN       = { target = 13.0, max = 18.0 },
    CANOLA        = { target =  9.0, max = 16.0 },
    SUNFLOWER     = { target =  9.0, max = 15.0 },

    -- EN: Rice / UA: Рис
    RICE          = { target = 20.0, max = 28.0 },  -- EN: Harvested wet; dried post-field
    RICELONGGRAIN = { target = 20.0, max = 28.0 },

    -- EN: Pulse crops / UA: Бобові
    PEA           = { target = 13.0, max = 18.0 },
    LENTIL        = { target = 13.0, max = 18.0 },
    CHICKPEA      = { target = 13.0, max = 18.0 },

    -- EN: Fibre / specialty / UA: Технічні та спеціальні
    COTTON        = { target =  8.0, max = 14.0 },
}

-- ---------------------------------------------------------------------------
-- EN: Per-effect enable flags. Default true; can be set false in XML.
-- UA: Прапорці включення для кожного ефекту. За замовчуванням true.
-- ---------------------------------------------------------------------------
MoistureCalculator.enableLoad  = true   -- EN: Raise engine load above target moisture
MoistureCalculator.enableLoss  = true   -- EN: Raise grain losses above target moisture
MoistureCalculator.enableSpeed = true   -- EN: Reduce recommended-speed cap above target moisture

-- ---------------------------------------------------------------------------
-- EN: Global factor scales — configurable from XML.
-- UA: Глобальні масштаби коефіцієнтів — налаштовуються з XML.
-- ---------------------------------------------------------------------------
MoistureCalculator.maxLoadFactor      = 1.30   -- EN: Load at max moisture vs. target (+30%)
MoistureCalculator.maxLossFactor      = 2.00   -- EN: Loss multiplier at max moisture (×2)
MoistureCalculator.maxSpeedReduction  = 0.35   -- EN: Max speed cap reduction at max moisture (−35%)
MoistureCalculator.dryBonusFactor     = 0.05   -- EN: Bonus (load/loss reduction) when below target (5%)

-- ---------------------------------------------------------------------------
-- EN: Internal helpers.
-- UA: Внутрішні допоміжні функції.
-- ---------------------------------------------------------------------------

--- EN: Return the threshold table for a crop, falling back to wheat if not listed.
--- UA: Повертає таблицю порогів для культури, повертаючись до пшениці якщо не знайдено.
local function getThresholds(cropName)
    if not cropName then
        return MoistureCalculator.CROP_THRESHOLDS["WHEAT"]
    end
    local name = cropName:upper()
    return MoistureCalculator.CROP_THRESHOLDS[name]
        or MoistureCalculator.CROP_THRESHOLDS["WHEAT"]
end

--- EN: Returns the normalised moisture ratio.
--      0.0 = at target; 1.0 = at max; negative = below target (dry bonus).
--- UA: Нормалізоване відношення вологості. 0=ціль, 1=максимум, <0=нижче цілі.
local function moistureRatio(moisture, t)
    return (moisture - t.target) / math.max(0.1, t.max - t.target)
end

-- ---------------------------------------------------------------------------
-- EN: Public API.
-- UA: Публічний API.
-- ---------------------------------------------------------------------------

--- EN: Engine-load multiplier for crop moisture.
--      Returns values < 1.0 (bonus) when crop is drier than target,
--      1.0 at target, and up to (1 + maxLoadFactor) at or above max moisture.
--- UA: Множник навантаження двигуна від вологості.
function MoistureCalculator.getLoadFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local t     = getThresholds(cropName)
    local ratio = moistureRatio(moisture, t)

    if ratio <= 0 then
        -- EN: Dry bonus — slight load reduction, capped at dryBonusFactor.
        -- UA: Бонус сухості — невелике зменшення навантаження.
        local dryRatio = math.min(1.0, -ratio)
        return math.max(1.0 - MoistureCalculator.dryBonusFactor, 1.0 - MoistureCalculator.dryBonusFactor * dryRatio)
    end

    -- EN: Linear ramp from 1.0 → 1.0 + maxLoadFactor.
    -- UA: Лінійне зростання від 1.0 до 1.0 + maxLoadFactor.
    return 1.0 + MoistureCalculator.maxLoadFactor * math.min(1.0, ratio)
end

--- EN: Grain-loss multiplier for crop moisture.
--      Uses a steeper exponent than load (1.5) so losses compound faster as
--      moisture climbs — wet grain tumbles poorly through sieves.
--- UA: Множник втрат зерна від вологості. Крутіший показник (1.5) — втрати зростають швидше.
function MoistureCalculator.getLossFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local t     = getThresholds(cropName)
    local ratio = moistureRatio(moisture, t)

    if ratio <= 0 then
        -- EN: Dry bonus — slight loss reduction.
        -- UA: Бонус сухості — невелике зменшення втрат.
        local dryRatio = math.min(1.0, -ratio)
        return math.max(1.0 - MoistureCalculator.dryBonusFactor, 1.0 - MoistureCalculator.dryBonusFactor * dryRatio)
    end

    -- EN: Exponential ramp (^1.5) — losses spike more aggressively than engine load.
    -- UA: Показникова крива (^1.5) — втрати зростають різкіше ніж навантаження.
    local curved = math.min(1.0, ratio) ^ 1.5
    return 1.0 + (MoistureCalculator.maxLossFactor - 1.0) * curved
end

--- EN: Recommended-speed cap multiplier for crop moisture.
--      Reduces the maximum attainable recommended speed independently of engine
--      load — wet standing crop increases resistance at the header and reel.
--      A small bonus is given when crop is drier than target.
--- UA: Множник стелі рекомендованої швидкості від вологості культури.
function MoistureCalculator.getSpeedFactor(cropName, moisture)
    if not moisture or moisture <= 0 then return 1.0 end
    local t     = getThresholds(cropName)
    local ratio = moistureRatio(moisture, t)

    if ratio <= 0 then
        -- EN: Slight speed bonus when crop is unusually dry (5% max).
        -- UA: Незначний бонус швидкості при дуже сухій культурі (до 5%).
        local dryRatio = math.min(1.0, -ratio)
        return math.min(1.05, 1.0 + 0.05 * dryRatio)
    end

    -- EN: Linear speed reduction: 1.0 → (1.0 − maxSpeedReduction).
    -- UA: Лінійне зменшення швидкості: 1.0 → (1.0 − maxSpeedReduction).
    local clampedRatio = math.min(1.0, ratio)
    return math.max(1.0 - MoistureCalculator.maxSpeedReduction,
                    1.0 - MoistureCalculator.maxSpeedReduction * clampedRatio)
end

--- EN: Returns HUD text color (r, g, b) based on crop moisture vs. per-crop thresholds.
--      Green  = at or below target (ideal conditions)
--      Amber  = between target and max (penalties accumulating)
--      Red    = above max (serious losses and load spike)
--- UA: Повертає колір тексту HUD (r, g, b) на основі вологості відносно порогів культури.
function MoistureCalculator.getHUDColor(cropName, moisture)
    if not moisture or moisture <= 0 then
        return 0.24, 0.72, 0.47  -- EN: Green (no data = assume fine)
    end
    local t = getThresholds(cropName)
    if moisture <= t.target then
        return 0.24, 0.72, 0.47  -- EN: Green — at or below ideal
    elseif moisture <= t.max then
        return 0.91, 0.78, 0.25  -- EN: Amber — above target, within range
    else
        return 0.89, 0.29, 0.29  -- EN: Red — above practical maximum
    end
end

--- EN: Returns a one-line label showing the moisture status vs. the crop threshold.
--      Shown alongside the % value in the HUD moisture row.
--- UA: Повертає коротку мітку стану вологості відносно порогу культури.
function MoistureCalculator.getMoistureLabel(cropName, moisture)
    if not moisture or moisture <= 0 then return "" end
    local t = getThresholds(cropName)
    if moisture < t.target - 2.0 then
        return string.format("%.1f%% ↓dry", moisture)
    elseif moisture <= t.target then
        return string.format("%.1f%%", moisture)
    elseif moisture <= t.max then
        return string.format("%.1f%% wet", moisture)
    else
        return string.format("%.1f%% !!wet", moisture)
    end
end

-- ---------------------------------------------------------------------------
-- EN: XML loader — reads the <moistureSettings> block inside cropThroughput.xml.
--     Called from CropThroughputConfig.load() after the XML file is open.
--     Safe to call even if the block is absent (all defaults are preserved).
--
--     XML structure expected:
--       <cropThroughput>
--           <moistureSettings
--               enableLoad="true"
--               enableLoss="true"
--               enableSpeed="true"
--               maxLoadFactor="1.30"
--               maxLossFactor="2.00"
--               maxSpeedReduction="0.35"
--               dryBonusFactor="0.05">
--               <crop name="wheat"    target="13.5" max="20.0" />
--               ...
--           </moistureSettings>
--           ...
--       </cropThroughput>
--
-- UA: XML завантажувач — читає блок <moistureSettings> всередині cropThroughput.xml.
-- ---------------------------------------------------------------------------
function MoistureCalculator.loadFromXML(xmlFile)
    if not xmlFile then return end

    local base = "cropThroughput.moistureSettings"
    if not hasXMLProperty(xmlFile, base) then
        -- EN: Block absent — keep compiled-in defaults silently.
        -- UA: Блок відсутній — зберігаємо вбудовані значення без попереджень.
        return
    end

    -- EN: Global enable flags.
    -- UA: Глобальні прапорці включення.
    local enLoad  = getXMLBool(xmlFile, base .. "#enableLoad")
    local enLoss  = getXMLBool(xmlFile, base .. "#enableLoss")
    local enSpeed = getXMLBool(xmlFile, base .. "#enableSpeed")
    if enLoad  ~= nil then MoistureCalculator.enableLoad  = enLoad  end
    if enLoss  ~= nil then MoistureCalculator.enableLoss  = enLoss  end
    if enSpeed ~= nil then MoistureCalculator.enableSpeed = enSpeed end

    -- EN: Global scale factors.
    -- UA: Глобальні масштабні коефіцієнти.
    local mxLoad  = getXMLFloat(xmlFile, base .. "#maxLoadFactor")
    local mxLoss  = getXMLFloat(xmlFile, base .. "#maxLossFactor")
    local mxSpeed = getXMLFloat(xmlFile, base .. "#maxSpeedReduction")
    local dryBon  = getXMLFloat(xmlFile, base .. "#dryBonusFactor")
    if mxLoad  and mxLoad  > 0 then MoistureCalculator.maxLoadFactor     = mxLoad  end
    if mxLoss  and mxLoss  > 0 then MoistureCalculator.maxLossFactor     = mxLoss  end
    if mxSpeed and mxSpeed >= 0 then MoistureCalculator.maxSpeedReduction = mxSpeed end
    if dryBon  and dryBon  >= 0 then MoistureCalculator.dryBonusFactor   = dryBon  end

    -- EN: Per-crop threshold overrides.
    -- UA: Перевизначення порогів по культурах.
    local i = 0
    while true do
        local key = string.format("%s.crop(%d)", base, i)
        if not hasXMLProperty(xmlFile, key) then break end
        local name   = getXMLString(xmlFile, key .. "#name")
        local target = getXMLFloat (xmlFile, key .. "#target")
        local maxVal = getXMLFloat (xmlFile, key .. "#max")
        if name and target and maxVal and maxVal > target then
            MoistureCalculator.CROP_THRESHOLDS[name:upper()] = { target = target, max = maxVal }
        end
        i = i + 1
    end

end
