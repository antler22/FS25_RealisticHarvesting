-- EN: Telemetry Provider — assembles one flat table describing everything the corner post
--     displays, from whichever source is currently authoritative.
--
--     The renderer reads ONLY this table and never learns where a value came from. That
--     separation is the point: it means the loss channels can be driven by an instructor
--     today, by a recorded scenario later, or by a real physics model eventually, with no
--     change to the drawing code at all.
--
--     Source routing:
--       loss channels   — SignalConditioner (instructor input, noised and lagged)
--       everything else — the live vehicle and the rhm_Combine spec, untouched
--
--     Every read is defensive. The corner post must degrade to zeros on an unusual machine
--     rather than throw inside a draw callback, where an error would spam the log every
--     frame and is awkward to diagnose.
--
-- UA: Постачальник телеметрії — збирає одну плоску таблицю з усім, що показує кутова стійка.
--     Рендерер читає ТІЛЬКИ цю таблицю і не знає джерела значень. Саме це розділення
--     дозволяє керувати каналами втрат інструктором зараз, записаним сценарієм пізніше або
--     реальною фізичною моделлю згодом — без жодних змін у коді малювання.
--     Усі читання захищені: на незвичайній машині стійка показує нулі, а не падає у draw.
TelemetryProvider = {}

-- EN: Reused every frame — never reallocated, because this is built inside the draw path.
-- UA: Перевикористовується щокадру — ніколи не перевиділяється (це шлях малювання).
TelemetryProvider.data = {
    -- EN: Loss columns, 0..1 conditioned, with segment counts alongside for the bars.
    --     totalLoss is DERIVED from shoe + separator, not driven — it mirrors the centre bar
    --     on the real post, which is a computed quantity rather than a sensor.
    -- UA: Колонки втрат (0..1) з кількістю сегментів. totalLoss — ПОХІДНА від решета і
    --     сепаратора, як центральна смуга на реальній стійці.
    shoeLoss = 0, totalLoss = 0, sepLoss = 0, tailings = 0,
    shoeSeg  = 0, totalSeg  = 0, sepSeg  = 0, tailSeg  = 0,

    -- EN: Real machine telemetry.
    engineRpm = 0, speedKmh = 0, fuelPct = 0, defPct = 0, coolantC = 20, grainMoisture = 0,
    tankPct = 0, yieldTha = 0, engineLoad = 0, tonPerHour = 0,

    -- EN: Machine settings, drawn on the schematic row. Doubles as the instructor's readout
    --     of what the student has actually changed.
    fan = 0, rotor = 0, concave = 0, upperSieve = 0, lowerSieve = 0,
    machineType = "grain",

    -- EN: UI / state.
    -- EN: activeShoe/Sep/Tail mark columns being driven right now. There is no armed
    --     selection any more — every channel has its own key pair and all are live.
    activeShoe = false, activeSep = false, activeTail = false,
    isTrainingMode = false,
    hasVehicle = false, isThreshing = false, cropName = "",
}

-- ============================================================================
-- EN: Defensive readers
-- UA: Захищені читачі
-- ============================================================================

-- EN: Engine RPM. FS25 exposes getLastMotorRpm() on the motor; the raw field is read as a
--     fallback because some modded motors replace the accessor.
-- UA: Оберти двигуна. Резервне читання поля — деякі моди замінюють аксесор.
local function readEngineRpm(vehicle)
    local m = vehicle and vehicle.spec_motorized and vehicle.spec_motorized.motor
    if not m then return 0 end

    if type(m.getLastMotorRpm) == "function" then
        local ok, rpm = pcall(m.getLastMotorRpm, m)
        if ok and type(rpm) == "number" then return rpm end
    end
    if type(m.lastMotorRpm) == "number" then return m.lastMotorRpm end
    return 0
end

-- EN: Fuel as a 0..100 percentage. Walks the motorized consumers to find whichever energy
--     fill type this machine actually uses — diesel, electric or methane — rather than
--     assuming diesel and reading a wrong or absent unit.
-- UA: Паливо у відсотках. Шукає серед споживачів потрібний тип енергії (дизель, електрика,
--     метан), а не припускає дизель.
local function readFuelPct(vehicle)
    local sm = vehicle and vehicle.spec_motorized
    if not sm then return 0 end

    local consumers = sm.consumersByFillTypeName
    if type(consumers) == "table" then
        for _, name in ipairs({ "diesel", "electriccharge", "methane" }) do
            local c = consumers[name]
            if c and c.fillUnitIndex and type(vehicle.getFillUnitFillLevelPercentage) == "function" then
                local ok, pct = pcall(vehicle.getFillUnitFillLevelPercentage, vehicle, c.fillUnitIndex)
                if ok and type(pct) == "number" then return pct * 100 end
            end
        end
    end

    -- EN: Fallback — some vehicles expose the index directly.
    -- UA: Резервний шлях — деякі машини надають індекс напряму.
    if sm.fuelFillUnitIndex and type(vehicle.getFillUnitFillLevelPercentage) == "function" then
        local ok, pct = pcall(vehicle.getFillUnitFillLevelPercentage, vehicle, sm.fuelFillUnitIndex)
        if ok and type(pct) == "number" then return pct * 100 end
    end

    return 0
end

-- EN: DEF (diesel exhaust fluid) level as 0..100. Not every machine has a DEF tank —
--     older and non-emissions-tier models simply do not — so a missing unit returns 0 and
--     the gauge reads empty rather than the display erroring or inventing a value.
-- UA: Рівень DEF у відсотках. Не кожна машина має бак DEF — відсутність повертає 0,
--     і датчик показує порожньо, а не вигадане значення.
local function readDefPct(vehicle)
    local sm = vehicle and vehicle.spec_motorized
    if not sm or type(vehicle.getFillUnitFillLevelPercentage) ~= "function" then return 0 end

    local consumers = sm.consumersByFillTypeName
    if type(consumers) == "table" then
        for _, name in ipairs({ "def", "adblue", "urea" }) do
            local c = consumers[name]
            if c and c.fillUnitIndex then
                local ok, pct = pcall(vehicle.getFillUnitFillLevelPercentage, vehicle, c.fillUnitIndex)
                if ok and type(pct) == "number" then return pct * 100 end
            end
        end
    end
    return 0
end

-- EN: Coolant temperature in degrees C.
--     This turned out to be REAL telemetry rather than something needing simulation: FS25's
--     Motorized spec maintains spec_motorized.motorTemperature.value, warming from 20 C at
--     start toward a 120 C ceiling under load. So the gauge reflects the actual engine, and
--     a cold start genuinely reads cold.
--     Falls back to the ambient 20 C floor when a machine has no temperature model, which
--     reads as "cold engine" rather than as a fault.
-- UA: Температура охолоджувальної рідини, °C. Виявилось, це РЕАЛЬНІ дані, а не симуляція:
--     FS25 веде spec_motorized.motorTemperature.value (від 20 °C до стелі 120 °C).
--     Отже датчик показує справжній двигун, і холодний старт справді читається холодним.
local function readCoolantC(vehicle)
    local sm = vehicle and vehicle.spec_motorized
    local mt = sm and sm.motorTemperature
    if mt and type(mt.value) == "number" then
        return mt.value
    end
    return 20
end

-- EN: Grain tank fill as 0..100. Prefers the combine's own accessor, which already knows
--     which unit is the grain tank, and falls back to unit 1.
-- UA: Заповнення бункера у відсотках. Спершу власний аксесор комбайна, потім юніт 1.
local function readTankPct(vehicle)
    if type(vehicle.getCombineFillLevelPercentage) == "function" then
        local ok, pct = pcall(vehicle.getCombineFillLevelPercentage, vehicle)
        if ok and type(pct) == "number" then return pct * 100 end
    end
    if type(vehicle.getFillUnitFillLevelPercentage) == "function" then
        local ok, pct = pcall(vehicle.getFillUnitFillLevelPercentage, vehicle, 1)
        if ok and type(pct) == "number" then return pct * 100 end
    end
    return 0
end

local function readSpeed(vehicle)
    if type(vehicle.getLastSpeed) == "function" then
        local ok, s = pcall(vehicle.getLastSpeed, vehicle)
        if ok and type(s) == "number" then return s end
    end
    return 0
end

-- ============================================================================
-- EN: Main assembly — called once per frame before drawing.
-- UA: Головне збирання — раз на кадр перед малюванням.
-- ============================================================================
function TelemetryProvider.update(vehicle)
    local d = TelemetryProvider.data

    d.isTrainingMode = TrainingMode and TrainingMode.isActive or false

    -- ---- Instructor-driven loss channels -------------------------------------------
    -- EN: Read through the conditioner so these carry the same noise and lag character a
    --     real sensor would. Segment counts are precomputed here so the renderer does no
    --     arithmetic of its own.
    -- UA: Читаємо через кондиціонер — той самий характер шуму та затримки, що й у реального
    --     датчика. Кількість сегментів рахуємо тут, щоб рендерер не рахував нічого сам.
    if SignalConditioner and d.isTrainingMode then
        d.shoeLoss  = SignalConditioner.getValue("shoeLoss")
        d.sepLoss   = SignalConditioner.getValue("sepLoss")
        d.tailings  = SignalConditioner.getValue("tailings")
        d.totalLoss = SignalConditioner.getValue("totalLoss")  -- EN: derived, see getTotalLoss

        d.shoeSeg  = SignalConditioner.getSegments("shoeLoss")
        d.sepSeg   = SignalConditioner.getSegments("sepLoss")
        d.tailSeg  = SignalConditioner.getSegments("tailings")
        d.totalSeg = SignalConditioner.getSegments("totalLoss")
    else
        d.shoeLoss, d.sepLoss, d.tailings, d.totalLoss = 0, 0, 0, 0
        d.shoeSeg, d.sepSeg, d.tailSeg, d.totalSeg = 0, 0, 0, 0
    end

    if TrainingMode and TrainingMode.isChannelActive then
        d.activeShoe = TrainingMode.isChannelActive("shoeLoss")
        d.activeSep  = TrainingMode.isChannelActive("sepLoss")
        d.activeTail = TrainingMode.isChannelActive("tailings")
    end

    -- ---- Real machine telemetry ----------------------------------------------------
    d.hasVehicle = vehicle ~= nil
    if not vehicle then
        d.engineRpm, d.speedKmh, d.fuelPct, d.defPct = 0, 0, 0, 0
        d.coolantC = 20
        d.tankPct, d.yieldTha, d.engineLoad, d.tonPerHour = 0, 0, 0, 0
        d.grainMoisture = 0
        d.isThreshing, d.cropName = false, ""
        d.fan, d.rotor, d.concave, d.upperSieve, d.lowerSieve = 0, 0, 0, 0, 0
        return d
    end

    d.engineRpm = readEngineRpm(vehicle)
    d.speedKmh  = readSpeed(vehicle)
    d.fuelPct   = readFuelPct(vehicle)
    d.defPct    = readDefPct(vehicle)
    d.coolantC  = readCoolantC(vehicle)
    d.tankPct   = readTankPct(vehicle)

    if type(vehicle.getIsTurnedOn) == "function" then
        local ok, on = pcall(vehicle.getIsTurnedOn, vehicle)
        d.isThreshing = ok and on or false
    else
        d.isThreshing = false
    end

    -- EN: Values sourced from the mod's own spec. These stay real in training mode — engine
    --     load especially, since it drives the speed limiter and a combine that does not
    --     slow in heavy crop would teach a falsehood.
    -- UA: Значення з власної спеціалізації мода. У режимі навчання вони залишаються
    --     реальними — особливо навантаження двигуна, яке керує обмежувачем швидкості.
    local spec = vehicle.spec_rhm_Combine
    if spec and spec.data then
        d.engineLoad    = spec.data.load or 0
        d.yieldTha      = spec.data.yield or 0
        d.tonPerHour    = spec.data.tonPerHour or 0
        d.grainMoisture = spec.data.grainMoisture or spec.data.moisture or 0
    else
        d.engineLoad, d.yieldTha, d.tonPerHour, d.grainMoisture = 0, 0, 0, 0
    end

    -- ---- Machine settings (schematic row) -------------------------------------------
    -- EN: In training mode this row is how the instructor sees what the student changed,
    --     which is why it is populated even though nothing here affects the loss bars.
    -- UA: У режимі навчання цей рядок показує інструктору, що змінив студент.
    local mem = spec and spec.combineMemory
    if mem and mem.currentSettings then
        local cs = mem.currentSettings
        d.fan        = cs.fan or 0
        d.rotor      = cs.rotor or 0
        d.concave    = cs.concave or cs.feeder or 0
        d.upperSieve = cs.upperSieve or 0
        d.lowerSieve = cs.lowerSieve or 0
        d.cropName    = mem.currentCrop or ""
        d.machineType = mem.machineType or "grain"
    else
        d.fan, d.rotor, d.concave, d.upperSieve, d.lowerSieve = 0, 0, 0, 0, 0
        d.cropName, d.machineType = "", "grain"
    end

    return d
end

function TelemetryProvider.get()
    return TelemetryProvider.data
end

-- ============================================================================
-- EN: Debug dump — the pre-renderer test surface. Steps 1-3 of this module are verifiable
--     entirely through this text output, with no artwork in existence yet.
-- UA: Налагоджувальний вивід — тестова поверхня до появи рендерера.
-- ============================================================================
function TelemetryProvider.toDebugString()
    local d = TelemetryProvider.data
    return string.format(
        "TRAIN[%s] moving=%-12s | SHOE %.2f(%d) TOTAL %.2f(%d) SEP %.2f(%d) TAIL %.2f(%d) | " ..
        "rpm=%.0f spd=%.1f fuel=%.0f%% def=%.0f%% cool=%.0fC tank=%.0f%% moist=%.1f load=%.0f%% yield=%.2f | " ..
        "fan=%d rotor=%d conc=%d up=%d lo=%d crop=%s",
        d.isTrainingMode and "ON" or "off",
        ((d.activeShoe and "S" or "-") .. (d.activeSep and "R" or "-") .. (d.activeTail and "T" or "-")),
        d.shoeLoss, d.shoeSeg, d.totalLoss, d.totalSeg, d.sepLoss, d.sepSeg, d.tailings, d.tailSeg,
        d.engineRpm, d.speedKmh, d.fuelPct, d.defPct, d.coolantC, d.tankPct, d.grainMoisture, d.engineLoad, d.yieldTha,
        d.fan, d.rotor, d.concave, d.upperSieve, d.lowerSieve,
        d.cropName ~= "" and d.cropName or "-")
end
