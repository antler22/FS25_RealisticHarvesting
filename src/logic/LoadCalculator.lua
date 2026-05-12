-- EN: Physics-based engine load and speed limit calculator for combine harvesters.
--     Tracks cut area and harvested mass each tick to compute: engine load (%),
--     dynamic speed limit, productivity (t/h, L/h), yield (t/ha), and crop loss (%)
--     from combine settings deviation. Supports grain, forage, root, and cotton types.
-- UA: Фізичний калькулятор навантаження двигуна та ліміту швидкості для комбайнів.
--     Відстежує площу зрізу та масу врожаю кожен тік для розрахунку: навантаження (%),
--     динамічного ліміту швидкості, продуктивності (т/год, л/год), врожайності (т/га)
--     та втрат врожаю (%) від відхилення налаштувань. Підтримує зернові, форажні, коренеплоди, бавовну.
LoadCalculator = {}
local LoadCalculator_mt = Class(LoadCalculator)

function LoadCalculator.new(modDirectory)
    local self = setmetatable({}, LoadCalculator_mt)
    
    self.modDirectory = modDirectory or g_currentModDirectory
    
    -- EN: Crop difficulty coefficients / UA: Коефіцієнти складності культур
    self.CROP_FACTORS = {} -- By FruitType ID
    self.CROP_FACTORS_FT = {} -- By FillType ID
    self:loadDefaultCropFactors()
    
    -- EN: average load calculation data / UA: Дані для розрахунку середнього навантаження
    self.totalDistance = 0
    self.totalArea = 0
    self.currentTime = 0
    self.avgTime = 1500  -- EN: 1.5 seconds between measuring / UA: 1.5 секунди між вимірами
    self.distanceForMeasuring = 3  -- EN: 3 meters / UA: 3 метри
    
    -- EN: Base perf (will be set in onLoad) / UA: Базова продуктивність (оновиться в onLoad)
    self.basePerfMass = 0  -- EN: kg per second / UA: кг на секунду
    self.cachedHP = 0            -- EN: Engine HP cached for dynamic crop-curve updates / UA: Кешоване HP для динамічних оновлень
    self.lastBasePerfCrop = nil  -- EN: Crop name used when basePerfMass was last calculated / UA: Культура при останньому розрахунку
    self.lastPickupCrop   = nil  -- EN: Crop name last applied via the pickup secondary forage path / UA: Культура, застосована через вторинний форажний шлях підбирача
    self.currentAvgMass = 0
    self.lastAvgMass = 0  -- EN: Prior average for acceleration / UA: Попереднє середнє для прискорення
    self.rawAvgMass = 0  -- EN: Raw unsmoothed value for braking / UA: Сире незгладжене для гальмування
    
    -- EN: Current Load Enum / UA: Поточне навантаження
    self.engineLoad = 0
    self.speedLimit = 15  -- EN: Current km/h limit / UA: Поточний ліміт км/год
    self.genuineSpeedLimit = -1  -- EN: Genuine limits from game db / UA: Ліміт з гри
    self.lastCropType = nil  -- EN: Last crop / UA: Остання культура
    self.lastHarvestTime = 0  -- EN: Last harvest time / UA: Час останнього збирання
    
    -- Crop loss and productivity
    self.cropLoss = 0  -- EN: Current crop loss (%) / UA: Поточні втрати врожаю (%)
    self.headerLoss = 0 -- EN: Header/speed-related crop loss (%) / UA: Втрати від швидкості на жатці (%)
    self.tonPerHour = 0  -- EN: Yield in T/h / UA: Продуктивність в Т/год
    self.litersPerHour = 0  -- EN: Yield in L/h / UA: Продуктивність в Л/год
    self.totalOutputMass = 0  -- EN: Total harvested mass / UA: Загальна маса зібраного врожаю

    -- EN: Rotor plugging state machine.
    --     A plug occurs when engine load stays at 130%+ for 10 consecutive seconds.
    --     Once plugged, the combine is disabled for 12 seconds (clear time).
    -- UA: Стан машини забивання ротора.
    self.plugTimer = 0      -- EN: ms spent continuously at >=130% load / UA: мс безперервно при навантаженні >=130%
    self.isPlugged = false  -- EN: True while combine is clearing a plug / UA: True поки комбайн очищує засмічення
    self.pluggedTimer = 0   -- EN: ms remaining until plug is cleared / UA: мс що залишились до очищення засмічення

    -- EN: Time-of-day moisture factor (cached every 60s to avoid per-tick env queries).
    -- UA: Коефіцієнт вологості часу доби (кешується кожні 60с для уникнення запитів оточення кожен тік).
    self.moistureFactor  = 1.0
    self.moistureLabel   = ""     -- EN: Short label for HUD display / UA: Коротка мітка для HUD
    self.moisturePercent = 13.0   -- EN: Realistic grain moisture % (always computed from time of day,
                                  --     independent of tech tier). Maps Optimal→~13%, Night Dew→~24%,
                                  --     Morning/Evening Dew linearly between. Always shown on HUD so
                                  --     the player always has a number — like real-life combines.
                                  -- UA: Реалістична вологість зерна у % (завжди обчислюється з часу доби,
                                  --     незалежно від рівня апгрейду). Оптимум→~13%, нічна роса→~24%.
    -- EN: Start timer at 60s so the first updateMoistureFactor call fires immediately (on the first tick).
    -- UA: Починаємо таймер на 60с щоб перший виклик updateMoistureFactor спрацював одразу (на першому тіку).
    self._moistureUpdateTimer = 60000

    -- EN: Session statistics — reset by the player via the Harvest Report panel.
    -- UA: Статистика сесії — скидається гравцем через панель звіту про збирання.
    self.session = {
        startTime   = 0,
        area        = 0,   -- ha
        mass        = 0,   -- tonnes
        loadSum     = 0,
        loadCount   = 0,
        lossSum     = 0,
        lossCount   = 0,
        hdrLossSum  = 0,
        hdrLossCount= 0,
        peakLoad    = 0,
        plugCount   = 0,
        active      = false,
    }
    
    -- EN: Yield counters accumulation / UA: Накопичення продуктивності
    self.productivityMass = 0  -- EN: Accumulated mass (kg) / UA: Накопичена маса (кг)
    self.productivityLiters = 0  -- EN: Accumulated volume (L) / UA: Накопичений об'єм (л)
    self.productivityTime = 0  -- EN: Accumulation time (ms) / UA: Час накопичення (мс)
    self.productivityUpdateInterval = 3000  -- EN: Update interval (ms) / UA: Інтервал оновлення
    
    -- EN: Load accumulator / UA: Накопичувач навантаження
    self.loadAccumulatedMass = 0 -- kg
    
    -- Combine Settings System
    self.combineMemory = nil  -- EN: Will be set by rhm_Combine / UA: Буде встановлено з rhm_Combine
    self.currentCrop = nil    -- EN: Current crop for loss calc / UA: Поточна культура для розрахунку втрат
    
    self.debug = RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") or false

    return self
end

---EN: Loads default crop difficulty factors / UA: Завантажує стандартні коефіцієнти складності культур
function LoadCalculator:loadDefaultCropFactors()
    -- EN: Target load factors for crops / UA: Цільові фактори навантаження для культур
    -- EN: Lower factor = lighter crop = faster drive / UA: Менший фактор = легша культура = комбайн їде швидше
    local factorMap = {
        ["WHEAT"] = 0.814,
        ["BARLEY"] = 0.869,
        ["OAT"] = 1.164,        -- EN: +25% / UA: +25%
        ["MAIZE"] = 0.572,      -- EN: -50% / UA: -50%
        ["CORN"] = 0.572,
        ["MAIZE_FORAGE"] = 0.572,
        ["MAIZE_SILAGE"] = 0.572,
        ["SOYBEAN"] = 1.788,    -- EN: -20% / UA: -20%
        ["SUNFLOWER"] = 2.324,
        ["CANOLA"] = 1.738,
        ["SORGHUM"] = 0.801,    -- EN: -20% / UA: -20%
        
        -- EN: Rice is a heavy crop / UA: Рис важка культура
        ["RICE"] = 1.303,
        ["RICE_LONG_GRAIN"] = 1.303,
        
        -- EN: Legumes / UA: Бобові
        ["PEA"] = 1.152,        -- EN: -20% / UA: -20%
        ["LENTIL"] = 1.152,
        ["CHICKPEA"] = 1.152,
        ["GREENBEAN"] = 2.240,  -- EN: -20% / UA: -20%
        
        -- EN: Root crops / UA: Коренеплоди
        ["POTATO"] = 0.600,     -- EN: Lighter / UA: Полегшено
        ["SUGARBEET"] = 0.920,  -- EN: +15% / UA: +15%
        ["BEETROOT"] = 1.050,   -- EN: +15% / UA: +15%
        ["CARROT"] = 0.323,     -- EN: -15% / UA: -15%
        ["PARSNIP"] = 0.400,    -- EN: Lighter / UA: Полегшено
        ["ONION"] = 0.600,      
        ["SPINACH"] = 2.880,    
        
        -- EN: Grass & Silage / UA: Трава та силос
        ["GRASS"] = 1.221,      -- EN: 1.5x Wheat / UA: 1.5x Пшениці
        ["DRYGRASS"] = 1.100,
        ["ALFALFA"] = 1.100,
        ["CLOVER"] = 1.100,
        ["MEADOW"] = 1.221,
        ["ONION_DIRTY"] = 0.700, -- EN: Dirty onions (Root crop) / UA: Брудна цибуля
        
        -- EN: Other / Mod crops / UA: Інші культури
        ["COTTON"] = 4.782,     -- EN: 2x heavier / UA: у 2 рази важча
        ["SUGARCANE"] = 0.654,
        ["POPLAR"] = 0.156,
        ["OILSEED_RADISH"] = 0.391,
        ["GRAPE"] = 0.391,
        ["OLIVE"] = 0.391,
        ["RYE"] = 0.814,
        ["SPELT"] = 0.814,
        ["TRITICALE"] = 0.461,
        ["MILLET"] = 0.976,
        ["MINT"] = 1.054,
    }

    -- EN: Dynamically mapping FruitType Enum
    for key, value in pairs(FruitType) do
        local mappedFactor = factorMap[key]
        if not mappedFactor then
            if key:find("_WINDROW") then
                mappedFactor = factorMap[key:gsub("_WINDROW", "")]
            elseif key:find("CUT_") then
                mappedFactor = factorMap[key:gsub("CUT_", "")]
            elseif key:find("_CUT") then
                mappedFactor = factorMap[key:gsub("_CUT", "")]
            end
        end
        if mappedFactor then
            self.CROP_FACTORS[value] = mappedFactor
        elseif type(value) == "number" and not key:find("NUM_") then
            -- EN: Use Wheat as the base fallback for any unknown crops
            -- UA: Використовуємо Пшеницю як базовий фолбек для невідомих культур
            self.CROP_FACTORS[value] = factorMap["WHEAT"] or 0.8
        end
    end

    -- EN: Also map FillType Enum (Critical for Pickups and Mod Crops)
    -- UA: Також мапуємо FillType Enum (Критично для підбирачів та мод-культур)
    if g_fillTypeManager then
        for key, value in pairs(FillType) do
            local mappedFactor = factorMap[key]
            if not mappedFactor then
                if key:find("_WINDROW") then
                    mappedFactor = factorMap[key:gsub("_WINDROW", "")]
                elseif key:find("CUT_") then
                    mappedFactor = factorMap[key:gsub("CUT_", "")]
                elseif key:find("_CUT") then
                    mappedFactor = factorMap[key:gsub("_CUT", "")]
                elseif key == "ONION_DIRTY" then
                    mappedFactor = factorMap["ONION_DIRTY"] or factorMap["ONION"]
                elseif key == "MEADOW" then
                    mappedFactor = factorMap["GRASS"]
                end
            end
            if mappedFactor then
                self.CROP_FACTORS_FT[value] = mappedFactor
            end
        end
    end

    -- EN: High-priority string-name lookup table. Values here override the FruitType/FillType
    --     enum lookups in calculateEngineLoad, correcting crops where the enum integer mapping
    --     is unreliable (mod crops, windrows, or crops with distinct forage vs grain behaviour).
    --     Key corrections vs the enum map:
    --       OAT        — 0.680 (lighter than wheat in practice, enum map had 1.164)
    --       MAIZE_FORAGE — 0.300 (green silage corn is far easier for forage harvesters)
    --       GRASS_WINDROW / DRYGRASS_WINDROW — explicit entries the _WINDROW suffix strip misses
    -- UA: Таблиця пріоритетного пошуку за іменем культури. Значення тут мають пріоритет над
    --     enum-пошуком, виправляючи культури з ненадійними enum-ID або форажними відмінностями.
    self.CROP_FACTORS_BY_NAME = {
        ["WHEAT"]             = 0.814,
        ["BARLEY"]            = 0.869,
        ["OAT"]               = 0.900,  -- EN: Light-stemmed but bulky; roughly on par with wheat
        ["MAIZE"]             = 0.572,
        ["CORN"]              = 0.572,
        ["MAIZE_FORAGE"]      = 0.300,
        ["MAIZE_SILAGE"]      = 0.572,
        ["SOYBEAN"]           = 1.788,
        ["SUNFLOWER"]         = 2.324,
        ["CANOLA"]            = 1.738,
        ["SORGHUM"]           = 0.801,
        ["RICE"]              = 1.303,
        ["RICE_LONG_GRAIN"]   = 1.303,
        ["PEA"]               = 1.152,
        ["LENTIL"]            = 1.152,
        ["CHICKPEA"]          = 1.152,
        ["GREENBEAN"]         = 2.240,
        ["POTATO"]            = 0.600,
        ["SUGARBEET"]         = 0.920,
        ["BEETROOT"]          = 1.050,
        ["CARROT"]            = 0.323,
        ["PARSNIP"]           = 0.400,
        ["ONION"]             = 0.600,
        ["SPINACH"]           = 2.880,
        ["GRASS"]             = 1.221,
        ["DRYGRASS"]          = 1.100,
        ["ALFALFA"]           = 1.100,
        ["CLOVER"]            = 1.100,
        ["MEADOW"]            = 1.221,
        ["ONION_DIRTY"]       = 0.700,
        ["COTTON"]            = 4.782,
        ["SUGARCANE"]         = 0.654,
        ["POPLAR"]            = 0.156,
        ["OILSEED_RADISH"]    = 0.391,
        ["GRAPE"]             = 0.391,
        ["OLIVE"]             = 0.391,
        ["RYE"]               = 0.814,
        ["SPELT"]             = 0.814,
        ["TRITICALE"]         = 0.461,
        ["MILLET"]            = 0.976,
        ["MINT"]              = 1.054,
        -- EN: GRASS_WINDROW and DRYGRASS_WINDROW are intentionally absent here.
        --     The enum mapping loop strips the _WINDROW suffix and maps them to their base crop
        --     factor (GRASS=1.221, DRYGRASS=1.100), and then the 0.75 pickup multiplier is applied
        --     in calculateEngineLoad — giving effective factors of ~0.916 and ~0.825 respectively.
        --     That result is already realistic for pre-cut dried windrow material and doesn't
        --     need a separate BY_NAME entry.
    }
end

---EN: Sets base performance mass / UA: Встановлює базову продуктивність (маса)
function LoadCalculator:setBasePerformance(basePerfMass)
    self.basePerfMass = basePerfMass
    
    if rhm_Combine and rhm_Combine.debug then
        print(string.format("RHM: Base performance set to %.2f kg/s (%.1f t/h)", 
            self.basePerfMass, self.basePerfMass * 3.6))
    end
end

---EN: Gets base performance from engine power / UA: Отримує базову продуктивність з потужності двигуна
function LoadCalculator:getBasePerformanceFromPower(vehicle)
    -- NEW LOGIC: Calculate throughput based on Horsepower
    -- Approximation: 1 HP ~= 0.035 kg/s throughput for Grain
    
    local coef = 0.035  -- EN: Standard coefficient for grain / UA: Стандартний коефіцієнт для зерна
    local power = 0

    -- EN: Use g_storeManager to get the category string — vehicle.xmlFile:getValue() returns a
    --     Lua table in FS25 (not a string), so string comparisons against it always fail.
    -- UA: Використовуємо g_storeManager для рядка категорії — xmlFile:getValue() повертає таблицю.
    local category = nil
    if g_storeManager then
        local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        -- EN: Normalize to lowercase — storeItem.categoryName may be any case depending on mod
        --     (e.g. "FORAGEHARVESTERS" vs "forageHarvesters"). Strip spaces too for safety.
        -- UA: Нормалізуємо до нижнього регістру — categoryName може бути будь-якого регістру.
        category = storeItem and storeItem.categoryName and storeItem.categoryName:lower():gsub("%s","") or nil
    end

    if category == "forageharvesters" or category == "forageharvestercutters" then
        -- EN: Calibrated so a 930–950 hp forage harvester (CLAAS Jaguar 990 / JD 9900) reaches
        --     ~450 t/hr fresh corn silage at 100% rated capacity.
        --     Formula: basePerfMass = coef × (400^0.25) × (hp^0.75)
        --       930 hp → 0.166 × 4.472 × 168.5 = 125.1 kg/s = 450 t/hr  ✓ (CLAAS Jaguar 990)
        --       650 hp → 0.166 × 4.472 × 128.9 =  95.7 kg/s = 344 t/hr  ✓ (mid-size, e.g. Jaguar 870)
        --       450 hp → 0.166 × 4.472 × 97.0  =  72.0 kg/s = 259 t/hr  ✓ (small forage harvester)
        -- UA: Калібровано: 930 к.с. Jaguar 990 = 450 т/год кукурудзяного силосу при 100% навантаженні.
        coef = 0.166
    elseif category == "beetvehicles" or category == "beetharvesting" then
        coef = 0.060  -- Beet harvesting
    elseif category == "potatovehicles" then
        coef = 0.060  -- Potato harvesting
    elseif category == "cottonvehicles" then
        coef = 0.015  -- Cotton
    elseif category == "vegetablevehicles" then
        coef = 0.060  -- Vegetable harvesting
    end
    
    if vehicle.spec_motorized and vehicle.spec_motorized.motor then
        local motor = vehicle.spec_motorized.motor
        -- EN: FS25 VehicleMotor does NOT have a .hp property at runtime.
        --     The #hp XML attribute is only used for shop-display via loadSpecValuePowerConfig()
        --     and is never stored on the motor object itself.
        --     The correct runtime API is motor.peakMotorPower, which is in kW (kilowatts).
        --     Derivation: keyframes store (normalizedTorque × torqueScale_kNm) as value and
        --     actual RPM as time. peakMotorPower = max(scaledTorque_kNm × RPM) × π/30
        --     = kNm × rad/s = kW.  Convert to hp: kW ÷ 0.7457.
        --
        -- EN: IMPORTANT: peakMotorPower is the mechanical engine-curve peak computed from the
        --     torque keyframes.  For forage harvesters (and some tractors) this often reports
        --     significantly less than the advertised HP because the torque curve shape in the
        --     vehicle XML does not scale to the full rated power.  We also read the XML #hp
        --     shop-display attribute and take the maximum of both, so the calibration always
        --     matches what the user sees in the store.
        -- UA: peakMotorPower — механічний пік з кривої двигуна.  Для форажних часто нижчий за
        --     паспортні дані.  Беремо максимум між peakMotorPower і XML #hp зі стору.
        if motor.peakMotorPower and motor.peakMotorPower > 0 then
            power = motor.peakMotorPower / 0.7457  -- EN: kW → hp / UA: кВт → к.с.
        end
    end

    -- EN: Also read the XML #hp store-display attribute via ConfigurationUtil (schema-registered,
    --     no validation errors) and take the maximum over peakMotorPower-derived hp.
    --     Guards against forage harvester torque curves that underreport vs. advertised HP
    --     (e.g. CLAAS Jaguar 990 advertised 913 hp, peakMotorPower curve gives ~400 hp).
    -- UA: Читаємо XML #hp через ConfigurationUtil (зареєстровано в схемі) і беремо максимум.
    if SpecializationUtil.hasSpecialization(Motorized, vehicle.specializations) then
        local cfgKey = ConfigurationUtil.getXMLConfigurationKey(
            vehicle.xmlFile,
            vehicle.configurations and vehicle.configurations.motor,
            "vehicle.motorized.motorConfigurations.motorConfiguration",
            "vehicle.motorized",
            "motor"
        )
        local xmlHp = ConfigurationUtil.getConfigurationValue(
            vehicle.xmlFile, cfgKey, "", "#hp", nil,
            "vehicle.motorized.motorConfigurations.motorConfiguration(0)",
            "vehicle"
        )
        if xmlHp and tonumber(xmlHp) and tonumber(xmlHp) > (power or 0) then
            power = tonumber(xmlHp)
        end
    end
    
    -- SMART DETECTION: If category didn't match specific types
    if math.abs(coef - 0.035) < 0.001 then
        local isVegetable = false
        
        -- 1. Check FillTypes (if available)
        if vehicle.getFillUnitFillTypes and vehicle.spec_fillUnit then
            for _, fillUnit in ipairs(vehicle.spec_fillUnit.fillUnits) do
                 if fillUnit.supportedFillTypes then
                     for fillTypeIndex, _ in pairs(fillUnit.supportedFillTypes) do
                        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                        if fillType and fillType.name then
                            local name = string.upper(fillType.name)
                            if name == "ONION" or name == "CARROT" or name == "BEETROOT" or name == "PARSNIP" then
                                isVegetable = true
                                break
                            end
                        end
                     end
                 end
                 if isVegetable then break end
            end
        end
        
        -- 2. Check Vehicle Name / Filename
        if not isVegetable then
            local name = string.lower(vehicle:getFullName() or "")
            local xml = string.lower(vehicle.configFileName or "")
            
            if name:find("onion") or name:find("carrot") or name:find("vegetable") or 
               xml:find("onion") or xml:find("carrot") or xml:find("vegetable") or
               name:find("ur%-%d+") or name:find("umr") or name:find("keiler") or 
               xml:find("ur_") or xml:find("umr_") then
                isVegetable = true
            end
        end
        
        if isVegetable then
            coef = 0.060 -- EN: Standardized vegetable coefficient / UA: Стандартизований коефіцієнт для овочів
        end
    end
    
    -- EN: NEXAT / articulated-module fix — walk the vehicle hierarchy to find the engine unit.
    -- UA: Виправлення для NEXAT / модульних машин — шукаємо двигун у ієрархії транспорту.
    if (not power or power == 0) then
        local function findVehicleWithEngine(v)
            if not v then return nil end
            local m = v.spec_motorized and v.spec_motorized.motor
            if m and m.peakMotorPower and m.peakMotorPower > 0 then
                return v
            end
            if v.getAttacherVehicle then
                return findVehicleWithEngine(v:getAttacherVehicle())
            end
            if v.rootVehicle and v.rootVehicle ~= v then
                local rm = v.rootVehicle.spec_motorized and v.rootVehicle.spec_motorized.motor
                if rm and rm.peakMotorPower and rm.peakMotorPower > 0 then
                    return v.rootVehicle
                end
            end
            return nil
        end
        local engineVeh = findVehicleWithEngine(vehicle)
        if engineVeh then
            local m = engineVeh.spec_motorized.motor
            if m.peakMotorPower and m.peakMotorPower > 0 then
                power = m.peakMotorPower / 0.7457  -- EN: kW → hp / UA: кВт → к.с.
            end
        end
    end
    
    -- EN: #hp already read unconditionally above via ConfigurationUtil — no second pass needed.
    
    if power and tonumber(power) > 0 then
        -- EN: Built-in throughput curve (exponent 0.75, reference 400hp) — used when no
        --     CropThroughputConfig override is present for this crop.
        --     Formula: basePerf = coef * (REF_HP^0.25) * (hp^0.75)
        -- UA: Вбудована крива пропускної здатності (показник 0.75, еталон 400 к.с.) —
        --     застосовується, коли немає перевизначення CropThroughputConfig для культури.
        local REF_HP = 400.0
        local hp = tonumber(power)

        -- EN: Cache HP so the dynamic per-crop recalculation in calculateEngineLoad can reuse it.
        -- UA: Кешуємо HP щоб динамічний перерахунок у calculateEngineLoad міг його використати.
        self.cachedHP = hp

        local basePerf = coef * (REF_HP ^ 0.25) * (hp ^ 0.75)

        -- EN: CropThroughputConfig AEM anchor curves are NOT applied here at init time because
        --     currentCrop is always nil at onPostLoad. The crop-specific curve is instead applied
        --     dynamically in calculateEngineLoad whenever the active crop changes.
        -- UA: Криві AEM тут не застосовуються, бо currentCrop завжди nil під час ініціалізації.
        --     Натомість крива конкретної культури динамічно оновлюється у calculateEngineLoad.

        return basePerf
    end
    
    -- NEXAT POWER FIX
    if vehicle.configFileName and vehicle.configFileName:lower():find("nexat") then
        local basePerf = 1100 * coef  
        return basePerf
    end
    
    return 10.0  -- Default ~36 t/h
end

-- ============================================================================
-- EN: Time-of-day moisture factor.
--     Wet crop is heavier to process — moisture multiplies effective crop
--     resistance, raising engine load so the speed control naturally backs
--     the machine off to maintain target load.
--
--     Schedule (all times are in-game clock hours):
--       00:00 – 06:00  Night dew    — full penalty  (factor 2.0 → ~50% speed)
--       06:00 – 09:00  Morning burn-off — linear taper from 2.0 → 1.0
--       09:00 – 19:00  Optimal window — no penalty  (factor 1.0)
--       19:00 – 24:00  Evening dew build-up — linear rise from 1.0 → 2.0
--
--     factor = 2.0 means the combine must run at ~50% of its normal speed
--     to keep engine load at target.  Factor = 1.0 = normal full speed.
-- UA: Коефіцієнт вологості часу доби.
-- ============================================================================
function LoadCalculator:updateMoistureFactor(dt)
    self._moistureUpdateTimer = (self._moistureUpdateTimer or 0) + dt
    if self._moistureUpdateTimer < 60000 then return end  -- EN: Update every 60s / UA: Оновлення кожні 60с
    self._moistureUpdateTimer = 0

    if not g_currentMission or not g_currentMission.environment then
        self.moistureFactor  = 1.0
        self.moistureLabel   = ""
        self.moisturePercent = 13.0  -- EN: Safe default at optimal.
        return
    end

    -- EN: dayTime is milliseconds since midnight. 24h = 86,400,000 ms.
    --     Field is environment.dayTime (NOT .currentDayTime — that field does not exist).
    -- UA: dayTime — мілісекунди від опівночі. 24 год = 86 400 000 мс.
    local dayTime = g_currentMission.environment.dayTime or 0
    local hour    = dayTime / 3600000  -- EN: Fractional hours 0.0–24.0 / UA: Дробові години 0.0–24.0

    -- EN: Realistic grain-moisture anchor points (based on typical cereal harvest conditions):
    --       Optimal window (9 am – 7 pm) ≈ 13.0 %
    --       Full night dew                ≈ 24.0 %
    --     Morning/evening transitions linearly between these anchors.
    -- UA: Реалістичні опорні значення вологості зерна:
    --       Оптимальне вікно (9:00–19:00) ≈ 13.0 %
    --       Повна нічна роса              ≈ 24.0 %
    local MOISTURE_OPTIMAL = 13.0
    local MOISTURE_NIGHT   = 24.0

    local factor, label, percent

    if hour < 6.0 then
        -- EN: 00:00–06:00 — full night penalty / UA: 00:00–06:00 — повний нічний штраф
        factor  = 2.0
        label   = "Night Dew"
        percent = MOISTURE_NIGHT

    elseif hour < 9.0 then
        -- EN: 06:00–09:00 — dew burning off, linear taper 2.0 → 1.0
        -- UA: 06:00–09:00 — роса висихає, лінійне зменшення 2.0 → 1.0
        local t = (hour - 6.0) / 3.0  -- EN: 0.0 at 6am, 1.0 at 9am
        factor  = 2.0 - t             -- EN: 2.0 → 1.0
        label   = "Morning Dew"
        percent = MOISTURE_NIGHT - (MOISTURE_NIGHT - MOISTURE_OPTIMAL) * t  -- EN: 24 → 13

    elseif hour < 19.0 then
        -- EN: 09:00–19:00 — optimal harvest window. Show "Optimal" so the HUD row is always visible.
        -- UA: 09:00–19:00 — оптимальне вікно збирання. "Optimal" щоб рядок HUD завжди відображався.
        factor  = 1.0
        label   = "Optimal"
        percent = MOISTURE_OPTIMAL

    else
        -- EN: 19:00–24:00 — evening dew building, linear rise 1.0 → 2.0
        -- UA: 19:00–24:00 — вечірня роса, лінійне зростання 1.0 → 2.0
        local t = (hour - 19.0) / 5.0  -- EN: 0.0 at 7pm, 1.0 at midnight
        factor  = 1.0 + t              -- EN: 1.0 → 2.0
        label   = "Evening Dew"
        percent = MOISTURE_OPTIMAL + (MOISTURE_NIGHT - MOISTURE_OPTIMAL) * t  -- EN: 13 → 24
    end

    self.moistureFactor  = factor
    self.moistureLabel   = label
    self.moisturePercent = percent
end

-- ============================================================================
-- EN: Header loss — crop loss due to travel speed at the cutter bar.
--     Grain knocked off heads or shattered pods at high speed.
--     Conservative values: <1% up to 6 mph (9.7 km/h), escalating above 8 mph.
--     Crop-specific multipliers: canola/soybean are most vulnerable to shattering.
-- UA: Втрати на жатці — втрати врожаю через швидкість руху у зоні жатки.
-- ============================================================================
LoadCalculator.HEADER_LOSS_CROP_FACTORS = {
    canola    = 2.0,   -- EN: Pod shatter very sensitive / UA: Дуже чутливий до розтріскування стручків
    soybean   = 1.8,   -- EN: Pod shatter risk / UA: Ризик розтріскування стручків
    pea       = 1.7,   -- EN: Pea pod shatter (FS25 crop key: PEA) / UA: Розтріскування стручків гороху
    lentil    = 1.6,   -- EN: Lentil pod shatter / UA: Розтріскування стручків сочевиці
    chickpea  = 1.5,   -- EN: Chickpea pod shatter / UA: Розтріскування нуту
    sunflower = 1.5,   -- EN: Head shatter / UA: Розтріскування кошика
    oat       = 1.2,   -- EN: Loose hull / UA: Слабкий лушпій
    rice      = 1.1,   -- EN: Shattering at tip / UA: Розтріскування на кінчику
    wheat     = 1.0,
    barley    = 1.0,
    sorghum   = 0.8,
    corn      = 0.25,  -- EN: Kernels well-protected in husk / UA: Зерна добре захищені в лушпинні
}

function LoadCalculator:calculateHeaderLoss(vehicle)
    if not vehicle then return 0 end

    -- EN: Header loss only applies when actively cutting (not forage — handled separately).
    -- UA: Втрати на жатці застосовуються лише при активному косінні (не форажні).
    if self.combineMemory and self.combineMemory.machineType == "forage" then
        self.headerLoss = 0
        return 0
    end

    local speed = vehicle:getLastSpeed()  -- EN: km/h / UA: км/год

    -- EN: 9.65 km/h = 6 mph (threshold where header loss begins).
    --     12.87 km/h = 8 mph (threshold where loss escalates sharply).
    -- UA: 9.65 км/год = 6 миль/год; 12.87 км/год = 8 миль/год.
    local THRESH_6MPH = 9.65
    if speed <= THRESH_6MPH then
        self.headerLoss = 0
        return 0
    end

    -- EN: Crop-specific shattering factor (defaults to wheat baseline = 1.0).
    -- UA: Коефіцієнт чутливості культури до обсипання (за замовчуванням пшениця = 1.0).
    local cropFactor = 1.0
    if self.combineMemory and self.combineMemory.currentCrop then
        local key = string.lower(self.combineMemory.currentCrop)
        -- EN: Strip suffixes like "_windrow", "_forage" etc. for lookup.
        -- UA: Обрізаємо суфікси типу "_windrow", "_forage" тощо для пошуку.
        for k, v in pairs(LoadCalculator.HEADER_LOSS_CROP_FACTORS) do
            if key == k or key:find(k, 1, true) then
                cropFactor = v
                break
            end
        end
    end

    -- EN: Gentle power-law curve. At 8 mph (12.87 km/h) wheat gets ~1.5%.
    --     Beyond 8 mph it escalates: at 10 mph (~16 km/h) wheat gets ~3.5%.
    --     All values capped at 8% to stay conservative.
    -- UA: М'яка крива степеневого закону. При 8 миль/год (12.87 км/год) пшениця дає ~1.5%.
    local excessSpeed = speed - THRESH_6MPH  -- EN: km/h above 6mph threshold
    local rawLoss = (excessSpeed ^ 1.35) * 0.28 * cropFactor
    self.headerLoss = math.min(8.0, rawLoss)
    return self.headerLoss
end

-- ============================================================================
-- EN: Plug state machine update. Called every tick from rhm_Combine:onUpdateTick.
--     Returns true if the plug state CHANGED this tick (for event/notification use).
-- UA: Оновлення стану засмічення ротора. Повертає true якщо стан змінився.
-- ============================================================================
function LoadCalculator:updatePlugState(dt)
    local changed = false
    if self.isPlugged then
        -- EN: Counting down clear timer.
        -- UA: Відлік таймера очищення.
        self.pluggedTimer = self.pluggedTimer - dt
        if self.pluggedTimer <= 0 then
            self.isPlugged    = false
            self.pluggedTimer = 0
            self.plugTimer    = 0
            changed = true
        end
    else
        -- EN: Check if engine load has been at 130%+ long enough to cause a plug.
        --     130% = engineLoad >= 1.30
        -- UA: Перевіряємо чи навантаження 130%+ тривало достатньо довго для засмічення.
        if self.engineLoad >= 1.30 then
            self.plugTimer = (self.plugTimer or 0) + dt
            if self.plugTimer >= 10000 then  -- EN: 10 seconds / UA: 10 секунд
                self.isPlugged    = true
                self.pluggedTimer = 12000   -- EN: 12 second clear time / UA: 12 секунд на очищення
                self.plugTimer    = 0
                self.session.plugCount = (self.session.plugCount or 0) + 1
                changed = true
            end
        else
            -- EN: Load dropped below threshold — reset the timer.
            -- UA: Навантаження впало нижче порогу — скидаємо таймер.
            self.plugTimer = 0
        end
    end
    return changed
end

-- ============================================================================
-- EN: Session tracking helpers.
-- UA: Допоміжні функції для відстеження статистики сесії.
-- ============================================================================
function LoadCalculator:startSession()
    self.session = {
        startTime      = g_currentMission and g_currentMission.time or 0,
        area           = 0,
        mass           = 0,      -- EN: Harvested mass in tonnes / UA: Зібрана маса в тоннах
        liters         = 0,      -- EN: Harvested volume in liters (for bushel conversion) / UA: Зібраний об'єм в літрах
        loadSum        = 0,
        loadCount      = 0,
        thrLossSum     = 0,      -- EN: Cumulative threshing loss (rotor/concave + overload) / UA: Накопичені втрати обмолоту
        thrLossCount   = 0,
        cleanLossSum   = 0,      -- EN: Cumulative cleaning loss (fan/sieves) / UA: Накопичені втрати очистки
        cleanLossCount = 0,
        hdrLossSum     = 0,
        hdrLossCount   = 0,
        peakLoad       = 0,
        plugCount      = 0,
        active         = true,
    }
end

function LoadCalculator:resetSession()
    self:startSession()
end

-- EN: Updated signature: (massKg, areaM2, liters, thrLoss, cleanLoss, headerLoss)
--     liters    — tick liters for bushel yield conversion.
--     thrLoss   — threshing loss % this tick (overload + rotor/concave settings).
--     cleanLoss — cleaning loss % this tick (fan/sieve settings).
-- UA: Оновлений підпис: (massKg, areaM2, liters, thrLoss, cleanLoss, headerLoss)
function LoadCalculator:updateSession(massKg, areaM2, liters, thrLoss, cleanLoss, headerLoss)
    if not self.session or not self.session.active then return end
    local load = self.engineLoad * 100

    self.session.mass   = (self.session.mass   or 0) + massKg / 1000
    self.session.area   = (self.session.area   or 0) + areaM2 / 10000
    self.session.liters = (self.session.liters or 0) + (liters or 0)

    if load > 0 then
        self.session.loadSum   = (self.session.loadSum   or 0) + load
        self.session.loadCount = (self.session.loadCount or 0) + 1
        if load > (self.session.peakLoad or 0) then self.session.peakLoad = load end
    end
    if (thrLoss or 0) > 0 then
        self.session.thrLossSum   = (self.session.thrLossSum   or 0) + thrLoss
        self.session.thrLossCount = (self.session.thrLossCount or 0) + 1
    end
    if (cleanLoss or 0) > 0 then
        self.session.cleanLossSum   = (self.session.cleanLossSum   or 0) + cleanLoss
        self.session.cleanLossCount = (self.session.cleanLossCount or 0) + 1
    end
    if (headerLoss or 0) > 0 then
        self.session.hdrLossSum   = (self.session.hdrLossSum   or 0) + headerLoss
        self.session.hdrLossCount = (self.session.hdrLossCount or 0) + 1
    end
end

-- EN: Returns a formatted summary table for the Harvest Report panel.
-- UA: Повертає форматовану таблицю підсумків для панелі звіту про збирання.
function LoadCalculator:getSessionSummary(unitSystem)
    local s = self.session or {}
    local avgLoad     = s.loadCount     > 0 and (s.loadSum     / s.loadCount)     or 0
    local avgThrLoss  = s.thrLossCount  > 0 and (s.thrLossSum  / s.thrLossCount)  or 0
    local avgCleanLoss= s.cleanLossCount> 0 and (s.cleanLossSum/ s.cleanLossCount) or 0
    local avgHdrLoss  = s.hdrLossCount  > 0 and (s.hdrLossSum  / s.hdrLossCount)  or 0
    local avgTotalLoss = avgThrLoss + avgCleanLoss

    -- EN: Elapsed game-time in minutes.
    local elapsed = 0
    if s.startTime and g_currentMission then
        elapsed = math.max(0, (g_currentMission.time - s.startTime) / 1000)
    end
    local elapsedMin = math.floor(elapsed / 60)

    -- EN: Efficiency score — starts at 100, deduct for losses, plugs, under-utilization.
    local score = 100
    score = score - avgThrLoss   * 5.0  -- EN: -5 pts per 1% avg threshing loss
    score = score - avgCleanLoss * 4.0  -- EN: -4 pts per 1% avg cleaning loss
    score = score - avgHdrLoss   * 3.0  -- EN: -3 pts per 1% avg header loss
    score = score - (s.plugCount or 0) * 10
    if avgLoad > 0 and avgLoad < 70 then
        score = score - math.max(0, (70 - avgLoad) / 5) * 3
    end
    score = math.max(0, math.min(100, score))

    local grade
    if     score >= 90 then grade = "A"
    elseif score >= 80 then grade = "B"
    elseif score >= 70 then grade = "C"
    elseif score >= 60 then grade = "D"
    else                    grade = "F"
    end
    local mod = score % 10
    if mod >= 7 then grade = grade .. "+"
    elseif mod < 3 and grade ~= "F" then grade = grade .. "-"
    end

    -- EN: Yield display — bushels use liters/35.2391; imperial = short tons; metric = tonnes.
    -- UA: Відображення врожаю — бушелі через літри/35.2391; imperial = коротка тонна; метрично = т.
    local areaStr, massStr
    if unitSystem == 3 then  -- EN: Bushels
        areaStr = string.format("%.1f ac", (s.area or 0) * 2.47105)
        local bushels = (s.liters or 0) / 35.2391
        massStr = string.format("%.0f bu", bushels)
    elseif unitSystem == 2 then  -- EN: Imperial (short tons)
        areaStr = string.format("%.1f ac", (s.area or 0) * 2.47105)
        massStr = string.format("%.1f ton", (s.mass or 0) * 1.10231)
    else  -- EN: Metric
        areaStr = string.format("%.1f ha", s.area or 0)
        massStr = string.format("%.1f t",  s.mass or 0)
    end

    if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
        print(string.format(
            "RHM [SessionSummary] avgThr=%.2f avgClean=%.2f avgHdr=%.2f score=%.0f liters=%.0f mass=%.2ft",
            avgThrLoss, avgCleanLoss, avgHdrLoss, score, s.liters or 0, s.mass or 0))
    end

    return {
        time         = string.format("%d min", elapsedMin),
        area         = areaStr,
        mass         = massStr,
        avgLoad      = string.format("%.0f%%",  avgLoad),
        peakLoad     = string.format("%.0f%%",  s.peakLoad or 0),
        avgThrLoss   = string.format("%.1f%%",  avgThrLoss),
        avgCleanLoss = string.format("%.1f%%",  avgCleanLoss),
        avgLoss      = string.format("%.1f%%",  avgTotalLoss),  -- EN: total, kept for backward compat
        avgHdrLoss   = string.format("%.1f%%",  avgHdrLoss),
        plugs        = tostring(s.plugCount or 0),
        grade        = grade,
        score        = math.floor(score),
    }
end

---EN: Updates load calculation variables / UA: Оновлює дані для розрахунку навантаження
function LoadCalculator:update(vehicle, dt, mass)
    self.totalDistance = self.totalDistance + vehicle.lastMovedDistance
    self.loadAccumulatedMass = (self.loadAccumulatedMass or 0) + mass

    -- INSTANT REACTION FIX:
    -- EN: Only reset to 5 km/h if starting from idle (prevents reset loop during harvest)
    -- UA: Після простою скидаємо до 5 км/год (запобігає циклу скидання під час роботи)
    if mass > 0 and self.speedLimit >= (self.genuineSpeedLimit - 0.1) and self.genuineSpeedLimit > 0 
       and (self.lastAvgMass or 0) < 0.1 then
         self.speedLimit = 5.0
    end
    
    self.currentTime = self.currentTime + dt
    if self.currentTime > self.avgTime or self.totalDistance > self.distanceForMeasuring then
        self:updateSettingsImpact() -- EN: Recalculate settings penalty / UA: Перераховання штрафу налаштувань
        self:calculateEngineLoad(vehicle)
        self:calculateSpeedLimit(vehicle)
        
        -- EN: Reset tick accumulators / UA: Скидаємо лічильники
        self.currentTime = 0
        self.loadAccumulatedMass = 0
        self.totalDistance = 0
    end
end

---EN: Calculates Engine Load / UA: Розраховує навантаження на двигун
function LoadCalculator:calculateEngineLoad(vehicle)
    if self.currentTime <= 0 then
        return
    end

    -- EN: Dynamic basePerfMass update — recalculate when the active crop changes.
    --     At onPostLoad (init time) currentCrop is always nil, so the AEM per-crop curve
    --     could never be applied then. We apply it here the first time the crop is known.
    --
    --     Forage harvesters use a separate _forageData table keyed by fruit type name,
    --     with tPerHrMin/tPerHrMax anchors (400/950 hp) in fresh t/hr — completely
    --     independent of the grain bu/hr curves in _data.
    -- UA: Динамічне оновлення basePerfMass — перераховуємо при зміні активної культури.
    --     Форажні комбайни використовують окрему таблицю _forageData з прив'язками у т/год.
    local currentCropName = self.combineMemory and self.combineMemory.currentCrop
    local isForageMachine = self.combineMemory and self.combineMemory.machineType == "forage"
    if isForageMachine then
        -- EN: Forage path — track fruit type changes and apply the per-crop forage throughput curve.
        --     Uses tPerHrMin/tPerHrMax anchors (400/950 hp) from cropThroughput.xml.
        --     Falls back to the corn silage curve if the current crop has no forage entry,
        --     then to the fixed coef formula if corn silage is also absent.
        -- UA: Форажний шлях — відстежуємо зміни типу плоду, застосовуємо форажну криву.
        local ft = vehicle.spec_combine and vehicle.spec_combine.lastValidInputFruitType
        if ft and ft ~= (self.lastForageFruitType or -1) and self.cachedHP and self.cachedHP > 0 then
            self.lastForageFruitType = ft
            local ftDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(ft)
            local ftName = ftDesc and ftDesc.name
            local params = CropThroughputConfig and CropThroughputConfig.getForageCurveParams
                           and (CropThroughputConfig.getForageCurveParams(ftName)
                                or CropThroughputConfig.getForageCurveParams("maize"))
            if params then
                self.basePerfMass = params.coef * (self.cachedHP ^ params.exp)
            else
                Logging.warning(string.format("[RHM] Forage curve: no params for '%s', basePerfMass unchanged=%.2f kg/s",
                    tostring(ftName), self.basePerfMass))
            end
            if currentCropName then self.lastBasePerfCrop = currentCropName end
        end

        -- EN: Secondary path — pickup forage headers (windrow pickup) never call addCutterArea,
        --     so lastValidInputFruitType stays 0 and the block above fires once with ftName=nil,
        --     falling back to "maize".  When addFillUnitFillLevel detects the actual output fill
        --     type (e.g. GRASS_WINDROW → mapped to "GRASS" by CombineSettingsDatabase) it sets
        --     currentCrop on combineMemory.  We catch that change here using a SEPARATE tracking
        --     variable (lastPickupCrop) so the ft-block setting lastBasePerfCrop cannot mask it.
        --
        --     Timing note: addFillUnitFillLevel may fire in the same frame as calculateEngineLoad
        --     but after it (scenario B) or before it (scenario A).  Using lastPickupCrop instead
        --     of lastBasePerfCrop guarantees this block fires on the very next frame where
        --     currentCropName is set, regardless of order.
        -- UA: Додатковий шлях — для підбиральних форажних голівок.
        --     Використовуємо окрему змінну lastPickupCrop, щоб ft-блок не заблокував цей шлях.
        if currentCropName and currentCropName ~= (self.lastPickupCrop or "")
           and self.cachedHP and self.cachedHP > 0 then
            local params = CropThroughputConfig and CropThroughputConfig.getForageCurveParams
                           and (CropThroughputConfig.getForageCurveParams(currentCropName)
                                or CropThroughputConfig.getForageCurveParams("maize"))
            if params then
                self.basePerfMass = params.coef * (self.cachedHP ^ params.exp)
            else
                Logging.warning(string.format(
                    "[RHM] Forage curve (pickup): no params for '%s', basePerfMass unchanged=%.2f kg/s",
                    currentCropName, self.basePerfMass))
            end
            self.lastPickupCrop    = currentCropName
            self.lastBasePerfCrop  = currentCropName
        end
    elseif currentCropName and currentCropName ~= self.lastBasePerfCrop and self.cachedHP > 0 then
        -- EN: Grain combines — apply the per-crop AEM throughput curve.
        -- UA: Зернові комбайни — застосовуємо криву AEM для конкретної культури.
        local params = CropThroughputConfig and CropThroughputConfig.getCurveParams
                       and CropThroughputConfig.getCurveParams(currentCropName)
        if params then
            self.basePerfMass = params.coef * (self.cachedHP ^ params.exp)
            if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
                print(string.format("RHM: [Throughput] %s → basePerfMass %.2f kg/s (%.0f t/h) @ %d hp",
                    currentCropName, self.basePerfMass, self.basePerfMass * 3.6, self.cachedHP))
            end
        end
        self.lastBasePerfCrop = currentCropName
    end

    -- EN: BASE CROP FACTOR / UA: БАЗОВИЙ КОЕФІЦІЄНТ КУЛЬТУРИ
    -- EN: Priority: 1. FruitType (Direct Cut), 2. FillType (Pickup/Windrow), 3. Wheat fallback
    local spec_combine = vehicle.spec_combine
    local rhmSpec = vehicle.spec_rhm_Combine
    
    local cropFactor = self.CROP_FACTORS[spec_combine.lastValidInputFruitType]
    
    -- Fallback to FillType (especially for Pickups/Root Crops)
    if not cropFactor and rhmSpec and rhmSpec.lastFillType then
        cropFactor = self.CROP_FACTORS_FT[rhmSpec.lastFillType]
    end
    
    -- Final fallback to Wheat
    if not cropFactor then
        cropFactor = self.CROP_FACTORS[FruitType.WHEAT] or 0.814
    end
    
    -- EN: INPUT DETECTION (PICKUP / CUTTER / FORAGE)
    local fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(spec_combine.lastValidInputFruitType or 0)
    local currentFruitTypeName = "UNKNOWN"
    
    if fruitTypeDesc then
        currentFruitTypeName = string.upper(fruitTypeDesc.name)
    elseif rhmSpec and rhmSpec.lastFillType then
        -- Try to get name from fillType if fruitType is unknown
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(rhmSpec.lastFillType)
        if fillTypeDesc then
            currentFruitTypeName = string.upper(fillTypeDesc.name)
        end
    end
    -- EN: String-name override — takes priority over FruitType/FillType enum lookups.
    --     Applied after the name is resolved so mod crops with non-standard enum IDs still
    --     get the correct factor. Skipped for forage machines (cropFactor is forced to 1.0
    --     further below; CROP_FACTORS_BY_NAME has no effect on them anyway).
    -- UA: Перевизначення за іменем — пріоритет над enum-пошуком. Пропускається для
    --     форажних машин (cropFactor скидається в 1.0 нижче).
    if not isForageMachine and currentFruitTypeName ~= "UNKNOWN" then
        local nameOverride = self.CROP_FACTORS_BY_NAME and self.CROP_FACTORS_BY_NAME[currentFruitTypeName]
        if nameOverride then
            cropFactor = nameOverride
        end
    end

    -- EN: CropFactorTuning hook — dev-only live override (no-op when ENABLED=false).
    --     Takes highest priority so tuned values are immediately reflected in engine load.
    -- UA: Хук CropFactorTuning — перевизначення в режимі розробника (no-op якщо ENABLED=false).
    if not isForageMachine and CropFactorTuning and CropFactorTuning.isEnabled() then
        local tuneOverride = CropFactorTuning.getFactorOverride(currentFruitTypeName)
        if tuneOverride then
            cropFactor = tuneOverride
        end
    end

    local isPickup = false
    local isForageCutter = false

    -- EN: ROBUST DETECTION (Check attached implements) / UA: НАДІЙНА ДЕТЕКЦІЯ
    if vehicle.getAttachedImplements then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            local implObj = implement.object
            if implObj then
                local storeItem = g_storeManager:getItemByXMLFilename(implObj.configFileName)
                -- EN: Normalize category to lowercase for case-insensitive matching.
                local cat = storeItem and storeItem.categoryName and storeItem.categoryName:lower():gsub("%s","") or ""

                -- EN: Detect Forage Harvester Header / UA: Силосна жатка
                if implObj.spec_forageHarvesterCutter ~= nil or implObj.spec_forageCutter ~= nil
                   or cat == "forageharvestercutters" then
                    isForageCutter = true
                end

                -- EN: Detect WINDROW Pickup (not vegetable harvester!)
                -- UA: Визначаємо підбірач валків (не овочевий комбайн!)
                if implObj.spec_pickup ~= nil or cat == "pickups" or cat == "slasher" then

                    -- EN: Check if this is a vegetable/root crop direct harvester
                    -- UA: Перевіряємо чи це прямий збирач овочів/коренеплодів
                    local isVegetableHarvester = false

                    -- 1. Category check
                    if cat == "vegetablevehicles" or cat == "onionharvesters"
                       or cat == "rootcropharvesters" then
                        isVegetableHarvester = true
                    end
                    
                    -- 2. FillType check
                    if not isVegetableHarvester and implObj.spec_fillUnit then
                        for _, fillUnit in ipairs(implObj.spec_fillUnit.fillUnits or {}) do
                            if fillUnit.supportedFillTypes then
                                for fillTypeIndex, _ in pairs(fillUnit.supportedFillTypes) do
                                    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                                    if ft and ft.name then
                                        local ftName = string.upper(ft.name)
                                        if ftName == "ONION" or ftName == "ONION_DIRTY"
                                           or ftName == "CARROT" or ftName == "BEETROOT"
                                           or ftName == "PARSNIP" or ftName == "POTATO" then
                                            isVegetableHarvester = true
                                            break
                                        end
                                    end
                                end
                            end
                            if isVegetableHarvester then break end
                        end
                    end
                    
                    -- 3. Filename fallback
                    if not isVegetableHarvester then
                        local xml = string.lower(implObj.configFileName or "")
                        if xml:find("onion") or xml:find("carrot") or xml:find("beetroot")
                           or xml:find("parsnip") or xml:find("ur_") or xml:find("umr_")
                           or xml:find("keiler") then
                            isVegetableHarvester = true
                        end
                    end
                    
                    if not isVegetableHarvester then
                        isPickup = true
                    end
                end
                
                if isPickup or isForageCutter then break end
            end
        end
    end

    -- EN: Fallback pickup detection: if input fruit type contains WINDROW or is UNKNOWN but area is processed
    if not isPickup then
        if currentFruitTypeName:find("WINDROW") or spec_combine.lastValidInputFruitType == 0 then
            isPickup = true
        end
    end

    -- EN: FORAGE MACHINE: basePerfMass is already per-crop via CropThroughputConfig forage curves
    --     (tPerHrMin / tPerHrMax anchors in cropThroughput.xml, updated dynamically above when
    --     the fruit type changes).  No additional cropFactor multiplier is needed here.
    -- UA: ФОРАЖНА МАШИНА: basePerfMass вже враховує культуру через форажні криві CropThroughputConfig.
    --     Додатковий множник cropFactor не потрібен.
    local appliedForageFactor = false
    if isForageMachine then
        cropFactor = 1.0
        appliedForageFactor = true
    end

    -- EN: APPLY MULTIPLIERS / UA: ЗАСТОСУВАННЯ МНОЖНИКІВ
    self.isPickup = isPickup
    if not appliedForageFactor then
        if isPickup then
            -- EN: Root crops & Vegetables should NOT be easier when picked up (already high volume)
            -- UA: Коренеплоди та овочі не повинні бути легшими при підбиранні
            local isRootOrVeg = currentFruitTypeName:find("ONION")
                             or currentFruitTypeName:find("POTATO")
                             or currentFruitTypeName:find("CARROT")
                             or currentFruitTypeName:find("PARSNIP")
                             or currentFruitTypeName:find("BEETROOT")
                             or currentFruitTypeName:find("SUGARBEET")
                             or currentFruitTypeName:find("SPINACH")
                             or currentFruitTypeName:find("GREENBEAN")

            if not isRootOrVeg then
                cropFactor = cropFactor * 0.75  -- EN: Standard windrows (Wheat, Barley, etc.)
            end
        elseif isForageCutter then
            cropFactor = cropFactor * 0.80  -- EN: Forage harvesters (silage/direct cut) / UA: Кормозбиральні комбайни
        end
    end

    -- --- [RHM DEBUG: INFO LOG] ---
    if rhm_Combine and rhm_Combine.debug and self.lastCropType ~= spec_combine.lastValidInputFruitType then
        self.lastCropType = spec_combine.lastValidInputFruitType
        local mode = isPickup and "PICKUP" or (isForageCutter and "FORAGE_CUTTER" or "DIRECT_CUT")
        print(string.format("RHM DEBUG: [INPUT] %s (%s). Final Factor: %.3f", mode, currentFruitTypeName, cropFactor))
    end
    
    -- EN: Grain moisture load factor — sourced from MoistureCalculator via the cached value
    --     set in rhm_Combine:onUpdateTick() (self.moistureLoadFactor).
    --     Forage and root-crop machines are exempt — they don't separate grain at harvest.
    --     Stacks multiplicatively with the time-of-day plant moisture factor (self.moistureFactor).
    -- UA: Коефіцієнт навантаження від вологості зерна — з MoistureCalculator через кешоване значення.
    --     Форажні та коренеплодні машини звільнені — вони не сепарують зерно.
    local grainMoistureFactor = 1.0
    local machineTypeForMoisture = self.combineMemory and self.combineMemory.machineType or "grain"
    if machineTypeForMoisture ~= "forage" and machineTypeForMoisture ~= "root" then
        grainMoistureFactor = self.moistureLoadFactor or 1.0
    end

    -- EN: Calculate RAW average mass intake per second / UA: Розраховуємо RAW середню масу за секунду (кг/с)
    -- EN: Uses accumulatedMass over the target distance/time / UA: Використовуємо accumulatedMass
    -- EN: Apply time-of-day plant moisture factor AND grain moisture factor (both raise effective load).
    -- UA: Застосовуємо коефіцієнти вологості рослини (час доби) та вологості зерна (зовнішній мод).
    local safeTime = math.max(100, self.currentTime) -- Protect against division by zero
    local rawAvgMass = (self.loadAccumulatedMass or 0) * (1000 / safeTime) * cropFactor * (self.moistureFactor or 1.0) * grainMoistureFactor
    
    -- ADAPTIVE SMOOTHING
    local loadRatio = self.currentAvgMass / math.max(0.01, self.basePerfMass)
    local smoothFactor = 0.3 + 0.4 * math.min(1.0, loadRatio)
    smoothFactor = math.min(0.7, smoothFactor)  -- Max 70% smoothing
    
    local avgMass = rawAvgMass
    if self.currentAvgMass > (0.5 * self.basePerfMass) then
        avgMass = (1 - smoothFactor) * rawAvgMass + smoothFactor * self.currentAvgMass
    end
    
    self.lastAvgMass = self.currentAvgMass
    self.currentAvgMass = avgMass
    self.rawAvgMass = rawAvgMass  
    
    -- EN: Fetch power boost for load calculation / UA: Отримуємо power boost для розрахунку навантаження
    local powerBoost = 0
    if g_realisticHarvestManager and g_realisticHarvestManager.settings then
        powerBoost = g_realisticHarvestManager.settings:getPowerBoost()
    end
    
    local maxAvgMass = (1 + 0.01 * powerBoost) * self.basePerfMass * (self.settingsEfficiency or 1.0)

    if maxAvgMass > 0 then
        self.engineLoad = self.currentAvgMass / maxAvgMass
    else
        self.engineLoad = 0
    end

end

---EN: Calculates Vehicle Speed Limit / UA: Розраховує обмеження швидкості
function LoadCalculator:calculateSpeedLimit(vehicle)
    if self.currentAvgMass == 0 then
        -- EN: If not harvesting, return to vanilla working speed / UA: Якщо не збираємо, повертаємось до ванільної робочої швидкості
        local target = self.genuineSpeedLimit > 0 and self.genuineSpeedLimit or 10.0
        if self.speedLimit > target then
            self.speedLimit = math.max(target, self.speedLimit - 0.5)
        elseif self.speedLimit < target then
            self.speedLimit = math.min(target, self.speedLimit + 0.5)
        end
        return
    end
    
    local powerBoost = 0
    local targetLoad = 0.95
    if self.combineMemory and self.combineMemory.currentSettings and self.combineMemory.currentSettings.targetEngineLoad then
        targetLoad = self.combineMemory.currentSettings.targetEngineLoad / 100.0
    end
    
    if g_realisticHarvestManager and g_realisticHarvestManager.settings then
        powerBoost = g_realisticHarvestManager.settings:getPowerBoost()
    end
    
    local maxAvgMass = (1 + 0.01 * powerBoost) * self.basePerfMass * (self.settingsEfficiency or 1.0)
    if maxAvgMass <= 0.01 then return end
    
    local loadRatio = self.currentAvgMass / maxAvgMass

    -- EN: Calculate error between target and current load
    -- UA: Розраховуємо різницю між цільовим і реальним навантаженням
    local difference = targetLoad - loadRatio

    -- EN: Deadzone of +/- 2% to prevent micro-oscillations and jitter around the target
    -- UA: Мертва зона +/- 2% щоб запобігти мікроколиванням навколо цілі
    if math.abs(difference) < 0.02 then
        difference = 0
    end

    -- EN: Proportional adjustment: hard brake on overload, smooth acceleration on underload
    -- UA: Пропорційне регулювання: швидке гальмування при перевантаженні, плавний розгін
    local step = difference * 1.5
    if difference < 0 then
        step = difference * 4.0 -- EN: Panic brake / UA: Екстренне скидання швидкості при забиванні
    end

    -- EN: Limit speed jump to avoid jittering
    -- UA: Обмежуємо максимальний стрибок швидкості за один тік, щоб уникнути ривків
    step = math.max(-2.5, math.min(0.8, step))
    
    self.speedLimit = self.speedLimit + step

    -- EN: Clamp speed within safe bounds. Only apply genuineSpeedLimit ceiling when it has been
    --     initialized (> 0). When genuineSpeedLimit = -1 (not yet set), using math.min(-1, x)
    --     would instantly pin speedLimit to the 2 km/h floor — avoid that race condition.
    --     Moisture speed factor provides an INDEPENDENT ceiling reduction on top of the
    --     load-driven reduction: wet standing crop increases resistance at the header/reel
    --     regardless of how hard the engine is working. Only applied for grain machines.
    -- UA: Обмежуємо швидкість. Стелю genuineSpeedLimit застосовуємо лише коли він встановлений (>0).
    --     Коефіцієнт швидкості вологості — незалежне зменшення стелі окрім навантаження двигуна.
    local gslCap = self.genuineSpeedLimit > 0 and self.genuineSpeedLimit or math.huge
    local machineTypeForSpeed = self.combineMemory and self.combineMemory.machineType or "grain"
    if machineTypeForSpeed ~= "forage" and machineTypeForSpeed ~= "root" then
        local speedFactor = self.moistureSpeedFactor or 1.0
        gslCap = gslCap * speedFactor
    end
    self.speedLimit = math.max(2.0, math.min(gslCap, self.speedLimit))
end

---EN: Returns current engine load factor / UA: Повертає поточне навантаження двигуна
function LoadCalculator:getEngineLoad()
    return self.engineLoad * 100
end

---EN: Returns calculated speed limit target / UA: Повертає остаточний ліміт швидкості
function LoadCalculator:getSpeedLimit()
    return self.speedLimit or 0
end

---EN: Caches base limit speed boundary / UA: Встановлює оригінальні межі ліміту
function LoadCalculator:setGenuineSpeedLimit(limit, maxCap)
    self.vanillaWorkingSpeed = limit
    self.genuineSpeedLimit = maxCap or limit
    self.speedLimit = limit
end

---EN: Fully resets accumulated internal data variables (does NOT reset session stats).
-- UA: Повністю очищує змінні бази даних (НЕ скидає статистику сесії).
function LoadCalculator:reset()
    self.totalDistance = 0
    self.totalArea = 0
    self.currentTime = 0
    self.currentAvgMass = 0
    self.engineLoad = 0
    self.cropLoss = 0
    self.headerLoss = 0
    self.plugTimer = 0
    -- EN: Do NOT clear isPlugged or pluggedTimer here — they persist until the clear timer expires.
    self.speedLimit = self.vanillaWorkingSpeed or (self.genuineSpeedLimit > 0 and self.genuineSpeedLimit or 15)
    self.productivityMass = 0
    self.productivityLiters = 0
    self.productivityTime = 0
    self.tonPerHour = 0
    self.litersPerHour = 0
    
    self.prodBuffer     = {}
    self.prodStartIndex = 1
    self.prodEndIndex   = 0
    self.prodSumTime    = 0
    self.currentBufferTime = 0

    self.yieldBuffer     = {}
    self.yieldStartIndex = 1
    self.yieldEndIndex   = 0
    self.yieldSumTime    = 0

    self.currentYield = 0
    self.instantYield = 0
end

---EN: Calculates load-based crop loss from overloading above rated capacity.
-- EN: Perfect settings at ≤100% engine load produce 0% loss here — a well-tuned combine
--     can run at full rated capacity cleanly. Settings-deviation penalties are applied
--     separately in calculateTotalCropLoss() and scale with load, so poor settings cause
--     losses even at 80% load while perfect settings give wiggle room up to 100%.
--
--   Overload curve (load > 100%):
--     100%: 0%       (rated capacity — no overload loss with perfect settings)
--     105%: ~0.2%    (Great — minor overload, machine still coping)
--     108%: ~0.5%    (Great/Good boundary)
--     110%: ~0.8%    (Good — noticeably over capacity)
--     115%: ~1.8%    (Worrying — significant overload)
--     120%: ~3.2% + linear spike → ~6%   (Bad)
--     130%: ~7.2% + linear spike → ~16%  (catastrophic — plug imminent)
-- UA: Втрати від перевантаження вище номінальної потужності. Ідеальні налаштування = 0% при ≤100%.
function LoadCalculator:calculateCropLoss()
    if not g_realisticHarvestManager or not g_realisticHarvestManager.settings then return 0 end
    if not g_realisticHarvestManager.settings.enableCropLoss then return 0 end

    -- EN: Forage harvesters (silage cutters) have no true loss mechanic — the only way
    --     crop is lost is if the spout discharge misses the trailer, which is an operator
    --     issue unrelated to machine settings. Exclude loss for forage machines entirely.
    -- UA: Кормозбиральні комбайни (силосоріза) не мають реального механізму втрат.
    if self.combineMemory and self.combineMemory.machineType == "forage" then
        self.cropLoss = 0
        return 0
    end

    local lossMultiplier = g_realisticHarvestManager.settings:getLossMultiplier()
    local load = self.engineLoad

    -- EN: No overload loss at or below rated capacity — perfect settings give clean headroom.
    local overloadLoss = 0
    if load > 1.00 then
        local overload = load - 1.00
        -- EN: Quadratic — grows slowly just above 100%, accelerates sharply past 115%.
        overloadLoss = (overload * overload) * 80
        -- EN: Linear spike above 115% — combine severely overloaded, plug risk is high.
        if load > 1.15 then
            overloadLoss = overloadLoss + ((load - 1.15) * 60)
        end
    end

    self.cropLoss = math.min(overloadLoss * lossMultiplier, 50)
    return self.cropLoss
end

-- EN: Evaluates settings penalty and stores RAW (unscaled) values.
--     Load-scaling is applied in calculateTotalCropLoss() so repeated calls
--     to that function don't double-scale the penalty.
--     rawThrSettingsLoss = max penalty from rotor/concave misadjustment at rated capacity.
--     rawCleanSettingsLoss = max penalty from fan/sieve misadjustment at rated capacity.
-- UA: Оцінює штраф налаштувань і зберігає СИРІ (немасштабовані) значення.
function LoadCalculator:updateSettingsImpact()
    self.settingsEfficiency   = 1.0
    self.rawThrSettingsLoss   = 0
    self.rawCleanSettingsLoss = 0
    if not self.combineMemory or not self.currentCrop then return end

    local effPenalty, thrLoss, cleanLoss, _ =
        self.combineMemory:checkSettingsForCrop(self.currentCrop)

    -- EN: Efficiency multiplier (affects throughput speed, not crop loss directly).
    if effPenalty < 0 then
        self.settingsEfficiency = 1.0 + (math.abs(effPenalty) * 5.0 / 100.0)
    else
        self.settingsEfficiency = 1.0 - (effPenalty / 100.0)
    end

    self.rawThrSettingsLoss   = math.max(0, thrLoss)
    self.rawCleanSettingsLoss = math.max(0, cleanLoss)

    if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
        print(string.format("RHM [LC:updateSettingsImpact] eff=%.2f rawThr=%.2f rawClean=%.2f",
            self.settingsEfficiency, self.rawThrSettingsLoss, self.rawCleanSettingsLoss))
    end
end

-- EN: Computes final per-channel losses and stores them for HUD and session tracking.
--     thrLoss   = floor/overload loss + load-scaled rotor/concave settings penalty.
--     cleanLoss = load-scaled fan/sieve settings penalty.
--     cropLoss  = total (backward-compat field used by scoring and stream sync).
--
--     Settings penalties are scaled by throughput: at low load (< 40%) wrong settings barely
--     matter because grain moves slowly through the machine. At rated capacity (100%) the
--     full penalty applies. Above rated capacity penalties amplify (cap 1.5×).
--
--     Raw penalties (rawThrSettingsLoss / rawCleanSettingsLoss) are preserved across calls
--     so repeated calls in the same tick don't compound the scaling.
-- UA: Обчислює фінальні втрати по каналах та зберігає для HUD і відстеження сесії.
function LoadCalculator:calculateTotalCropLoss()
    local baseLoss = self:calculateCropLoss()  -- EN: Floor + overload loss (already multiplied)

    local machineTypeForLoss = self.combineMemory and self.combineMemory.machineType or "grain"

    -- EN: FORAGE MACHINES — chop quality path.
    --     Forage harvesters have no grain loss (no sieves, no grain hitting the floor).
    --     However, chopLength / kernelProcessor deviations directly affect silage quality
    --     (particle size, kernel cracking). This is represented as cleanLoss so the HUD
    --     "Processing Score" (100 - cleanLoss) responds to calibration changes.
    --
    --     Key differences from grain path:
    --       1. NOT gated by enableCropLoss — that toggle is conceptually "grain falling on the
    --          floor", which doesn't apply here. Chop quality is always tracked.
    --       2. NOT load-scaled — chop quality is determined by machine settings at any throughput.
    --          A bad chopLength gives poor particle size at 20% load just as much as at 100%.
    --       3. thrLoss and cropLoss are always 0 (no physical grain loss on forage machines).
    -- UA: ФОРАЖНІ КОМБАЙНИ — шлях якості різки.
    --     Немає втрат зерна, але відхилення довжини різки/KP впливають на якість силосу.
    --     cleanLoss відображає якість обробки, незалежно від enableCropLoss та навантаження.
    if machineTypeForLoss == "forage" then
        local cropName = self.currentCrop or (self.combineMemory and self.combineMemory.currentCrop)
        local rawClean = self.rawCleanSettingsLoss or 0
        if self.combineMemory and cropName then
            local _, _, currentCleanLoss, _ = self.combineMemory:checkSettingsForCrop(cropName)
            rawClean = math.max(0, currentCleanLoss or 0)
            self.rawCleanSettingsLoss = rawClean
        end
        -- EN: Use lossMultiplier so difficulty setting still scales the sensitivity
        --     (Arcade = more forgiving feedback, Realistic = tighter tolerance).
        --     Guard against nil g_realisticHarvestManager the same way the grain path does.
        local lossMultiplier = 1.0
        if g_realisticHarvestManager and g_realisticHarvestManager.settings then
            lossMultiplier = g_realisticHarvestManager.settings:getLossMultiplier()
        end
        self.thrLoss   = 0
        self.cleanLoss = math.min(rawClean * lossMultiplier, 50)
        self.cropLoss  = 0

        if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
            print(string.format(
                "RHM [LC:calcLoss:forage] rawClean=%.2f lossMultiplier=%.2f → cleanLoss=%.2f (score=%d%%)",
                rawClean, lossMultiplier, self.cleanLoss, math.floor(100 - self.cleanLoss + 0.5)))
        end
        return 0
    end

    -- EN: Guard — if crop loss is globally disabled for grain/root machines, zero everything and bail.
    if not g_realisticHarvestManager or not g_realisticHarvestManager.settings
            or not g_realisticHarvestManager.settings.enableCropLoss then
        self.thrLoss  = 0
        self.cleanLoss = 0
        self.cropLoss  = 0
        return 0
    end

    local lossMultiplier = g_realisticHarvestManager.settings:getLossMultiplier()

    -- EN: Load-scaling factor for settings penalties.
    --     Physics rationale: at low throughput, grain has time to be separated even with imperfect
    --     settings. As throughput (load) increases, the grain layer thickens and moves faster —
    --     misadjusted rotor/sieves cannot compensate, so losses grow with load.
    --       0% scale at 40% load  (barely any grain flowing)
    --       50% scale at 70% load  (losses becoming noticeable with poor settings)
    --       100% scale at 100% load (full settings penalty — rated capacity)
    --       up to 150% scale above rated (overload amplifies settings sensitivity), capped
    local loadScale = math.min(math.max((self.engineLoad - 0.40) / 0.60, 0.0), 1.5)

    local rawThr   = self.rawThrSettingsLoss   or 0
    local rawClean = self.rawCleanSettingsLoss or 0

    -- EN: Moisture loss factor — wet crop doesn't separate cleanly through sieves/rotor.
    --     Applied only to the settings-deviation penalties (rawThr/rawClean), NOT to the base
    --     overload loss — overload loss is already captured by the higher engine load that wet
    --     crop causes through moistureLoadFactor, so applying it again here would double-count.
    --     Forage and root machines are excluded (no sieve separation mechanic).
    -- UA: Коефіцієнт втрат від вологості — вологе зерно погано проходить через решета/ротор.
    --     Застосовується лише до штрафів налаштувань, не до базових втрат від перевантаження.
    local moistLossMult = 1.0
    if machineTypeForLoss ~= "root" then
        moistLossMult = self.moistureLossFactor or 1.0
    end

    local thrLoss   = math.min(baseLoss + rawThr   * loadScale * lossMultiplier * moistLossMult, 50)
    local cleanLoss = math.min(           rawClean * loadScale * lossMultiplier * moistLossMult, 50)
    local totalLoss = math.min(thrLoss + cleanLoss, 50)

    self.thrLoss   = thrLoss
    self.cleanLoss = cleanLoss   -- EN: Scaled final value; raw preserved in rawCleanSettingsLoss.
    self.cropLoss  = totalLoss

    if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
        print(string.format(
            "RHM [LC:calcLoss] base=%.2f scale=%.2f rawThr=%.2f rawClean=%.2f → thr=%.2f clean=%.2f total=%.2f",
            baseLoss, loadScale, rawThr, rawClean, thrLoss, cleanLoss, totalLoss))
    end

    return totalLoss
end

---EN: Returns instantaneous processed metric tonnes per clock hour / UA: Перерахунок в тонни на годину
function LoadCalculator:getTonPerHour()
    return self.tonPerHour
end

---EN: Returns yield in L/h / UA: Розрахунок літрів на годину
function LoadCalculator:getLitersPerHour()
    return self.litersPerHour or 0
end

---EN: Updates sliding window rolling averages for metric evaluations.
---     Time-based 2.5-second window — tick-count windows break because onUpdateTick
---     fires at variable rates (20-60+ Hz), not the assumed 3 Hz.
--- UA: Оновлює ковзні середні продуктивності. Вікно на основі часу (2.5 с) — кількісні вікна
---     ламаються бо onUpdateTick викликається з різною частотою (20-60+ Гц), а не 3 Гц.
local PROD_WINDOW_MS = 2500  -- EN: 2.5-second rolling window / UA: Ковзне вікно 2.5 секунди

function LoadCalculator:updateProductivity(mass, liters, dt)
    self.totalOutputMass = self.totalOutputMass + mass

    self.prodBuffer     = self.prodBuffer     or {}
    self.prodStartIndex = self.prodStartIndex or 1
    self.prodEndIndex   = self.prodEndIndex   or 0
    self.prodSumTime    = self.prodSumTime    or 0

    self.prodEndIndex = self.prodEndIndex + 1
    self.prodBuffer[self.prodEndIndex] = {m = mass, l = liters or 0, t = dt}
    self.prodSumTime = self.prodSumTime + dt

    -- EN: Trim oldest samples until the buffer fits within PROD_WINDOW_MS.
    --     Keep at least one sample so the buffer is never empty.
    -- UA: Видаляємо найстаріші семпли поки вікно не вкладається в PROD_WINDOW_MS.
    while self.prodSumTime > PROD_WINDOW_MS and (self.prodEndIndex - self.prodStartIndex) >= 1 do
        self.prodSumTime = self.prodSumTime - self.prodBuffer[self.prodStartIndex].t
        self.prodBuffer[self.prodStartIndex] = nil
        self.prodStartIndex = self.prodStartIndex + 1
    end

    local sumMass   = 0
    local sumLiters = 0
    local sumTime   = 0
    for i = self.prodStartIndex, self.prodEndIndex do
        local v = self.prodBuffer[i]
        sumMass   = sumMass   + v.m
        sumLiters = sumLiters + v.l
        sumTime   = sumTime   + v.t
    end

    if sumTime > 100 then
        local hours = sumTime / 3600000
        self.tonPerHour    = (sumMass / 1000) / hours
        self.litersPerHour = sumLiters / hours
    else
        self.tonPerHour    = 0
        self.litersPerHour = 0
    end
end

---EN: Processes complete physical output block calculations / UA: Виконує розрахунки врожайності
-- EN: Yield is a SHORT rolling window (~2.5 seconds), not a field average.
--     Time-based, not count-based — onUpdateTick fires at variable rates (20-60+ Hz in FS25),
--     so a fixed sample count would produce a window far shorter than intended.
--     Formula: rawYield = (sumMass_kg / sumArea_m²) × 10  →  t/ha
--     Noise: ±5% random applied at HUD display time (DraggableHUD) — not stored here.
--
--     Startup guard: require sumArea > YIELD_MIN_AREA_M2 before publishing any reading.
--     This prevents a ÷0 or spike on the very first samples before enough area accumulates.
-- UA: Короткий ковзний вікно (~2.5 с) на основі часу. rawYield = (sumMass/sumArea)*10 → т/га.
local YIELD_WINDOW_MS   = 2500  -- EN: 2.5-second rolling window / UA: Ковзне вікно 2.5 секунди
local YIELD_MIN_AREA_M2 = 2     -- EN: ~2 m² before first reading (reached in <1 tick at typical speed)

function LoadCalculator:updateProductivityAndYield(mass, liters, area, dt)
    self:updateProductivity(mass, liters, dt)
    if area <= 0.0001 and mass <= 0.001 then
        self.currentYield = self.currentYield or 0
        return
    end

    self.yieldBuffer     = self.yieldBuffer     or {}
    self.yieldStartIndex = self.yieldStartIndex or 1
    self.yieldEndIndex   = self.yieldEndIndex   or 0
    self.yieldSumTime    = self.yieldSumTime    or 0

    self.yieldEndIndex = self.yieldEndIndex + 1
    self.yieldBuffer[self.yieldEndIndex] = {m = mass, a = area, t = dt}
    self.yieldSumTime = self.yieldSumTime + dt

    -- EN: Trim oldest samples until the buffer fits within YIELD_WINDOW_MS.
    --     Keep at least one sample so the buffer is never empty.
    -- UA: Видаляємо найстаріші семпли поки вікно не вкладається в YIELD_WINDOW_MS.
    while self.yieldSumTime > YIELD_WINDOW_MS and (self.yieldEndIndex - self.yieldStartIndex) >= 1 do
        self.yieldSumTime = self.yieldSumTime - self.yieldBuffer[self.yieldStartIndex].t
        self.yieldBuffer[self.yieldStartIndex] = nil
        self.yieldStartIndex = self.yieldStartIndex + 1
    end

    local sumMass = 0
    local sumArea = 0
    for i = self.yieldStartIndex, self.yieldEndIndex do
        local v = self.yieldBuffer[i]
        sumMass = sumMass + v.m
        sumArea = sumArea + v.a
    end

    -- EN: Require a meaningful area sample before publishing — guards against the
    --     first-sample spike where mass > 0 but distance-based area is near zero.
    -- UA: Вимагаємо достатньої площі перш ніж публікувати — захист від першого семплу.
    if sumArea >= YIELD_MIN_AREA_M2 then
        self.currentYield = (sumMass / sumArea) * 10
    end
end

function LoadCalculator:setRealTimeYield(yieldTha)
    self.yieldBuffer = self.yieldBuffer or {}
    self.yieldStartIndex = self.yieldStartIndex or 1
    self.yieldEndIndex = self.yieldEndIndex or 0
    
    self.yieldEndIndex = self.yieldEndIndex + 1
    self.yieldBuffer[self.yieldEndIndex] = yieldTha
    
    if (self.yieldEndIndex - self.yieldStartIndex + 1) > 20 then 
        self.yieldBuffer[self.yieldStartIndex] = nil
        self.yieldStartIndex = self.yieldStartIndex + 1
    end
    
    local sum = 0
    local count = self.yieldEndIndex - self.yieldStartIndex + 1
    for i = self.yieldStartIndex, self.yieldEndIndex do 
        sum = sum + self.yieldBuffer[i] 
    end
    self.currentYield = sum / count
end

---EN: Returns formatted yield string / UA: Отримує форматований рядок врожайності
-- EN: NOTE — the HUD uses UnitConverter.convertYield() directly and does NOT call this function.
--     getYieldText is kept for backwards compatibility with any external callers.
-- UA: УВАГА — HUD використовує UnitConverter.convertYield() напряму і НЕ викликає цю функцію.
function LoadCalculator:getYieldText(unitSystem, fruitType)
    local yield = self.currentYield or 0
    if yield < 0.1 then return "0.0", "t/ha" end

    if UnitConverter then
        local val, suffix = UnitConverter.convertYield(yield, unitSystem, fruitType)
        if unitSystem == 2 then
            return string.format("%.2f", val), suffix
        elseif unitSystem == 3 then
            return string.format("%.0f", val), suffix
        end
    end
    -- EN: Fallback when UnitConverter is unavailable.
    -- UA: Резервний варіант коли UnitConverter недоступний.
    if unitSystem == 2 then
        return string.format("%.2f", yield / 2.47105), "t/ac"
    elseif unitSystem == 3 then
        return string.format("%.0f", yield / 2.47105 * 36.76), "bu/ac"
    end
    return string.format("%.1f", yield), "t/ha"
end
