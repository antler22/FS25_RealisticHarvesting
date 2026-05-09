-- EN: Manages per-combine settings memory including current crop detection, operating mode (AUTO/MANUAL),
--     and per-parameter settings (fan, rotor, sieves, feeder). Interfaces with ProfileManager for
--     global persistent profiles, and sends network events when settings change in multiplayer.
-- UA: Керує пам'яттю налаштувань для кожного комбайна: detectування поточної культури,
--     режим роботи (AUTO/MANUAL), і налаштування параметрів (вентилятор, ротор, решета, подача).
--     Взаємодіє з ProfileManager для глобальних збережених профілів, і надсилає мережеві події
--     при зміні налаштувань у мультиплеєрі.
CombineMemory = {}
local CombineMemory_mt = Class(CombineMemory)

-- ============================================================================
-- EN: Upgrade tier constants.
--     Tier 0 (free)   : Manual settings only. No loss display, no hints, no auto.
--     Tier 1 ($2,500) : Calibration   — live crop loss % shown in HUD.
--     Tier 2 ($5,000) : Machine Monitor — optimal setting hints shown in GUI.
--     Tier 3 ($20,000): Auto Pilot    — combine self-applies optimal settings on crop change.
--     Each tier includes all lower tiers. Purchased once per combine (not per farm).
-- UA: Константи рівнів апгрейду.
-- ============================================================================
CombineMemory.UPGRADE_COSTS = { [1] = 2500, [2] = 5000, [3] = 10000, [4] = 20000 }
CombineMemory.UPGRADE_NAMES = {
    [0] = "No upgrades",
    [1] = "Loss Catch Pan",
    [2] = "Settings Monitoring",
    [3] = "Speed Automation",
    [4] = "Full Automation",
}
CombineMemory.UPGRADE_DESC = {
    [1] = "Shows live crop loss % and header loss in HUD",
    [2] = "Shows optimal settings hints and yield trend in GUI",
    [3] = "Activates automatic speed control to prevent overloads and plugging",
    [4] = "Auto-applies optimal settings on crop change",
}

-- EN: Creates a new CombineMemory instance tied to a specific combine vehicle.
--     Initializes all parameters to 50% and sets AUTO mode as default.
-- UA: Створює новий екземпляр CombineMemory, прив'язаний до конкретного комбайна.
--     Ініціалізує всі параметри до 50% та встановлює AUTO як режим за замовчуванням.
function CombineMemory.new(combine, machineType)
    local self = setmetatable({}, CombineMemory_mt)

    self.combine = combine
    self.machineType = machineType or "grain"

    self.currentProfile = nil -- EN: Name of the currently active profile / UA: Назва поточного активного профілю
    self.currentCrop = nil    -- EN: Currently detected crop name / UA: Поточна визначена культура

    self.debug = RHM_Debug and RHM_Debug.isEnabled("CombineMemory") or false

    -- EN: Pre-crop neutral state: 50% on all params. This is only held until the first crop
    --     is detected, at which point switchCrop() replaces it with the crop-specific baseline
    --     (~1 tolerance-step off optimal, giving ~2.5% total loss as a starting point).
    -- UA: Нейтральний стан до визначення культури: 50% на всіх параметрах. Це тимчасово —
    --     як тільки визначається культура, switchCrop() застосовує базові налаштування для неї.
    self.currentSettings = {}
    local activeParams = CombineSettingsDatabase:getParamsForMachineType(self.machineType)
    for _, paramName in ipairs(activeParams) do
        self.currentSettings[paramName] = 50
    end
    self.currentSettings["targetEngineLoad"] = 95

    self.currentYieldCalibration = 1.0

    -- EN: Upgrade level: 0=None, 1=Loss Catch Pan, 2=Settings Monitoring, 3=Speed Automation, 4=Full Automation.
    --     Purchased once per combine via the in-game shop; persists in savegame.
    -- UA: Рівень апгрейду: 0=Відсутній, 1=Піддон, 2=Моніторинг, 3=Автоматика швидкості, 4=Повна автоматика.
    self.upgradeLevel = 0

    self.mode = "AUTO"            -- EN: Starts in AUTO mode by default / UA: За замовчуванням починає в AUTO режимі
    self.autoSwitchEnabled = true -- EN: Auto-applies optimal settings on crop change / UA: Автоматично застосовує оптимальні при зміні культури
    self.swathWidth = nil  -- EN: User-defined swath/pickup width override (nil = use header width). Meters.
    self.showWarnings = true      -- EN: Show warnings for incorrect settings / UA: Показувати попередження при неправильних налаштуваннях

    return self
end

-- EN: Attempts to purchase the specified upgrade tier for this combine.
--     Deducts cost from the player's farm budget. Sends a network sync event.
--     Returns true + "success" on success, or false + reason string on failure.
--     Buying tier 3 directly skips tier 1 and 2 (you get all features).
-- UA: Намагається придбати вказаний рівень апгрейду для цього комбайна.
function CombineMemory:purchaseUpgrade(targetLevel)
    if targetLevel <= (self.upgradeLevel or 0) then
        return false, "already_owned"
    end
    if targetLevel < 1 or targetLevel > 4 then
        return false, "invalid_level"
    end

    local cost = CombineMemory.UPGRADE_COSTS[targetLevel] or 0

    -- EN: Resolve player farm using a fallback chain.
    --     g_currentMission.player.farmId is unreliable when the player is seated in a vehicle
    --     (the player entity may be detached or report spectator farmId = 0).
    --     The vehicle's ownerFarmId is the most reliable source in that case.
    -- UA: Отримуємо ферму гравця через ланцюжок запасних варіантів.
    --     g_currentMission.player.farmId ненадійний коли гравець сидить у транспорті.
    --     ownerFarmId транспортного засобу — найнадійніше джерело в такому випадку.
    local farmId = g_currentMission and g_currentMission.player and g_currentMission.player.farmId
    -- Fallback 1: use the combine vehicle's own owner farm
    if (not farmId or farmId == 0) and self.combine then
        farmId = self.combine.ownerFarmId
    end
    -- Fallback 2: iterate all farms for the first non-spectator farm (single-player safe)
    if (not farmId or farmId == 0) and g_farmManager then
        for id, _ in pairs(g_farmManager.farms or {}) do
            if id ~= FarmManager.SPECTATOR_FARM_ID then
                farmId = id
                break
            end
        end
    end
    local farm = farmId and farmId > 0 and g_farmManager and g_farmManager:getFarmById(farmId)
    if not farm then
        return false, "no_farm"
    end

    local balance = farm.money or 0
    if balance < cost then
        return false, "insufficient_funds"
    end

    -- EN: Deduct money. FS25 uses addMoney with negative value + MoneyType.
    g_currentMission:addMoney(-cost, farmId, MoneyType.SHOP_PROPERTY_BUY, true, true)

    self.upgradeLevel = targetLevel

    -- EN: Sync upgrade level to server / all clients via CombineSettingsEvent.
    if g_client and self.combine then
        local event = CombineSettingsEvent.new(self.combine, "UPGRADE_LEVEL", targetLevel)
        if not g_server then
            g_client:getServerConnection():sendEvent(event)
        else
            local conn = g_currentMission and g_currentMission.player and g_currentMission.player.serverConnection or nil
            event:run(conn)
        end
    end

    if self.debug then
        print(string.format("RHM: [Upgrade] Purchased tier %d (%s) for $%d",
            targetLevel, CombineMemory.UPGRADE_NAMES[targetLevel] or "?", cost))
    end
    return true, "success"
end

-- EN: Saves the current settings as a global profile for the given crop in ProfileManager.
--     Profiles persist across sessions in the user's modSettings folder.
-- UA: Зберігає поточні налаштування як глобальний профіль для заданої культури в ProfileManager.
--     Профілі зберігаються між сесіями в папці modSettings користувача.
function CombineMemory:saveCurrentProfile(cropName)
    local pm = g_realisticHarvestManager and g_realisticHarvestManager.profileManager
    if pm then
        pm:saveProfile(cropName, self.currentSettings)
        if self.debug then
            print(string.format("RHM: [OK] Profile saved globally: %s", cropName))
        end
        return true
    end
    if self.debug then
        print("RHM: [!] Failed to save global profile: ProfileManager not found")
    end
    return false
end

-- EN: Applies automatic or default settings for a specified crop.
--     AUTO mode adds a small random deviation around the optimal values (server-only randomness).
--     RESET mode (forceOptimal=false) sets all parameters to neutral 50%.
-- UA: Застосовує автоматичні або стандартні налаштування для заданої культури.
--     AUTO режим додає невелике випадкове відхилення від оптимальних значень (тільки на сервері).
--     Режим RESET (forceOptimal=false) встановлює всі параметри на нейтральні 50%.
function CombineMemory:autoConfigureForCrop(cropName, forceOptimal)
    print(string.format("RHM: [MEM] autoConfigureForCrop ENTER cropName=%s | forceOptimal=%s | prevMode=%s | machineType=%s",
        tostring(cropName), tostring(forceOptimal), tostring(self.mode), tostring(self.machineType)))
    if not cropName then
        print("RHM: [MEM] autoConfigureForCrop EXIT — nil cropName")
        return false
    end

    local optimalSettings = CombineSettingsDatabase:getSettingsForCrop(cropName)

    if not optimalSettings then
        if self.debug then print(string.format("RHM: [!] No settings found for crop: %s", cropName)) end
        -- EN: Crop is unknown but we still proceed with defaults.
        -- UA: Культура невідома, але продовжуємо зі значеннями за замовчуванням.
    end

    if forceOptimal and optimalSettings then
        -- EN: AUTO mode: apply exact optimal values for the current crop.
        --     No randomness — AUTO is a deterministic on/off toggle. The player sees exactly
        --     optimal settings snap in immediately when AUTO is enabled.
        -- UA: AUTO режим: застосовуємо точні оптимальні значення для культури. Без випадковості.
        local activeParams = CombineSettingsDatabase:getParamsForMachineType(self.machineType)
        for _, pName in ipairs(activeParams) do
            if optimalSettings[pName] then
                self.currentSettings[pName] = math.max(0, math.min(100, optimalSettings[pName].optimal))
            else
                self.currentSettings[pName] = 50
            end
        end

        self.mode = "AUTO"
        if self.debug then
            print(string.format("RHM: [AUTO] Exact optimal settings applied for: %s", tostring(cropName)))
        end
    else
        -- EN: BASELINE mode: set each param one tolerance-step off optimal in the direction
        --     of the most common novice mistake for that parameter type. This gives ~2.5% total
        --     loss ("Good" rating) — playable out of the box, but with clear room to improve
        --     through manual tuning or by purchasing upgrades. Falls back to 50% if the crop
        --     has no database entry (unknown mod crop).
        -- UA: Базовий режим: кожен параметр відхилений від оптимального на один крок tolerance.
        --     Дає ~2.5% загальних втрат ("Good") — можна грати одразу, але є куди покращувати.
        local activeParams = CombineSettingsDatabase:getParamsForMachineType(self.machineType)
        local baseline = CombineSettingsDatabase:getBaselineForCrop(cropName)
        for _, pName in ipairs(activeParams) do
            self.currentSettings[pName] = (baseline and baseline[pName]) or 50
        end

        self.mode = "MANUAL"
        if self.debug then
            if baseline then
                print(string.format("RHM: [OK] Baseline settings applied for: %s (novice offset from optimal)", cropName))
            else
                print(string.format("RHM: [OK] Default settings (50%%) applied for: %s (unknown crop)", cropName))
            end
        end
    end

    -- EN: Reset yield calibration when switching to a new crop without an existing profile.
    -- UA: Скидаємо калібрування врожайності при переключенні на нову культуру без існуючого профілю.
    local pm = g_realisticHarvestManager and g_realisticHarvestManager.profileManager
    if not pm or not pm:getProfile(cropName) then
        self.currentYieldCalibration = 1.0
    end

    self.currentCrop = cropName

    local s = self.currentSettings or {}
    print(string.format("RHM: [MEM] autoConfigureForCrop EXIT mode=%s | fan=%s rotor=%s upper=%s lower=%s concave=%s feeder=%s",
        tostring(self.mode),
        tostring(s.fan), tostring(s.rotor), tostring(s.upperSieve), tostring(s.lowerSieve),
        tostring(s.concave), tostring(s.feeder)))
    return true
end

-- EN: Toggles AUTO mode on/off.
--     If currently MANUAL → switch to AUTO and apply optimal settings immediately.
--     If currently AUTO   → switch to MANUAL (player takes control).
--     Sends a network event so the server applies the change authoritatively.
-- UA: Перемикає режим AUTO вкл/викл. MANUAL→AUTO: застосовує оптимальні відразу. AUTO→MANUAL: гравець керує.
function CombineMemory:requestAutoSettings()
    if g_client and self.combine then
        local targetIsAuto = (self.mode ~= "AUTO")  -- EN: Toggle: if not AUTO, turn it on; if AUTO, turn off.
        local eventType    = targetIsAuto and "AUTO_SET" or "MANUAL_SET"
        local event        = CombineSettingsEvent.new(self.combine, eventType, 1)
        if not g_server then
            g_client:getServerConnection():sendEvent(event)
        else
            event:run(nil)
        end
        if self.debug then
            print(string.format("RHM: [AUTO] Toggle requested: %s → %s",
                self.mode, targetIsAuto and "AUTO" or "MANUAL"))
        end
    end
end

-- EN: Sends a network request to the server to reset all settings to 50%.
-- UA: Надсилає мережевий запит на сервер для скидання всіх налаштувань до 50%.
function CombineMemory:requestResetSettings()
    if not self.currentCrop then return end

    if g_client and self.combine then
        local event = CombineSettingsEvent.new(self.combine, "RESET_SET", 1)
        if not g_server then
            g_client:getServerConnection():sendEvent(event)
        else
            event:run(nil)
        end
        if self.debug then print("RHM: [Sync] Requested RESET settings from server") end
    end
end

-- EN: Loads the global user-saved profile for the current crop from ProfileManager.
--     If in multiplayer (client), sends a CombineSettingsEvent with the full profile.
--     Returns false if no profile exists.
-- UA: Завантажує глобально збережений профіль користувача для поточної культури з ProfileManager.
--     У мультиплеєрі (клієнт) надсилає CombineSettingsEvent з повним профілем.
--     Повертає false якщо профіль відсутній.
function CombineMemory:loadUserPreset()
    print(string.format("RHM: [MEM] loadUserPreset ENTER | currentCrop=%s | pm=%s",
        tostring(self.currentCrop),
        tostring(g_realisticHarvestManager and g_realisticHarvestManager.profileManager ~= nil)))

    if not self.currentCrop then
        print("RHM: [MEM] loadUserPreset EXIT — no currentCrop")
        return false
    end

    local pm = g_realisticHarvestManager and g_realisticHarvestManager.profileManager
    if not pm then
        print("RHM: [MEM] loadUserPreset EXIT — no ProfileManager")
        return false
    end

    local profile = pm:getProfile(self.currentCrop)
    print(string.format("RHM: [MEM] loadUserPreset profile lookup for %s → %s",
        tostring(self.currentCrop), tostring(profile ~= nil)))
    if profile then
        if g_client and not g_server and self.combine then
            -- EN: True multiplayer client — send a full-profile event to the server for network sync.
            --     The event format is limited to the params CombineSettingsEvent serialises;
            --     for singleplayer we use the direct path below to avoid those limitations.
            -- UA: Справжній мультиплеєр — відправляємо подію на сервер.
            local event = CombineSettingsEvent.new(self.combine, "", 0, true, profile)
            g_client:getServerConnection():sendEvent(event)
        else
            -- EN: Singleplayer (g_server ~= nil) or dedicated-server execution.
            --     Apply ALL params directly from the profile using the machine-type param list.
            --     This avoids the CombineSettingsEvent hardcoded-6-param limitation and correctly
            --     restores concave, forage params (chopLength/kernelProcessor/acceleratorGap),
            --     root params (shakingIntensity), and any future additions.
            -- UA: Синглплеєр або виконання на виділеному сервері.
            --     Застосовуємо ВСІ параметри напряму, без обмежень мережевої події.
            local activeParams = CombineSettingsDatabase:getParamsForMachineType(self.machineType)
            for _, pName in ipairs(activeParams) do
                if self.currentSettings[pName] ~= nil then
                    local val = profile[pName]
                    -- EN: Legacy compat — old saves wrote "feeder" for what is now "concave".
                    if val == nil and pName == "concave" then val = profile.feeder end
                    self.currentSettings[pName] = val or 50
                end
            end
            self.currentSettings.targetEngineLoad = profile.targetEngineLoad or 95
            self.mode = "MANUAL"
            self.autoSwitchEnabled = false
        end
        if self.debug then print(string.format("RHM: [OK] Global profile applied for %s", self.currentCrop)) end
        return true
    else
        if self.debug then print(string.format("RHM: No global user preset found for %s", self.currentCrop)) end
        return false
    end
end

-- EN: Evaluates all current settings against the crop's optimal database values.
--     Returns separate efficiency (speed) and loss penalties, plus a warnings table.
--     Feeder/Rotor affect efficiency (throughput), Fan/Sieves affect crop loss (separation quality).
-- UA: Оцінює всі поточні налаштування відносно оптимальних значень бази даних для культури.
--     Повертає окремо штрафи за ефективність (швидкість) і втрати врожаю, плюс таблицю попереджень.
--     Подача/Ротор впливають на ефективність (пропускну здатність), Вентилятор/Решета — на втрати (якість очищення).
-- EN: Evaluates current combine settings against optimal values for a given crop.
--     Returns four values:
--       effPenalty  — throughput/speed penalty (%) from rotor/concave/feeder misadjustment.
--       thrLoss     — threshing loss (%) from rotor/concave: grain that exits with straw unthreshed.
--       cleanLoss   — cleaning loss (%) from fan/sieves: grain blown over or falling through the shoe.
--       warnings    — table of out-of-tolerance parameters for hint display.
--
--     Physical routing rationale:
--       feeder       → efficiency only   (feed rate affects throughput, not directly grain loss)
--       rotor/concave→ efficiency + threshing loss (dual effect: slow/uneven threshing drops grain)
--       fan/sieves   → cleaning loss only (separation quality in the cleaning shoe)
-- UA: Оцінює поточні налаштування відносно оптимальних для культури.
--     Повертає чотири значення: effPenalty, thrLoss, cleanLoss, warnings.
function CombineMemory:checkSettingsForCrop(cropName)
    local optimalSettings = CombineSettingsDatabase:getSettingsForCrop(cropName)
    if not optimalSettings then return 0, 0, 0, {} end

    local warnings     = {}
    local effScore     = 0   -- EN: Throughput speed penalty / UA: Штраф пропускної здатності
    local thrScore     = 0   -- EN: Threshing loss (rotor/concave) / UA: Втрати обмолоту (ротор/дека)
    local cleanScore   = 0   -- EN: Cleaning loss (fan/sieves) / UA: Втрати очистки (вентилятор/решета)
    local effCount     = 0
    local thrCount     = 0
    local cleanCount   = 0

    for param, value in pairs(self.currentSettings) do
        if optimalSettings[param] then
            local optimal   = optimalSettings[param].optimal
            local tolerance = optimalSettings[param].tolerance
            local deviation = math.abs(value - optimal)

            local score = 0
            if deviation <= tolerance then
                -- EN: GREEN ZONE: slight bonus at perfect centre, fades to 0 at tolerance edge.
                score = (deviation / tolerance - 0.5) * 1.0
            else
                -- EN: RED ZONE: linear penalty above tolerance, capped at 6.0.
                local excess = deviation - tolerance
                score = math.min(6.0, 0.5 + excess * 0.33)
                table.insert(warnings, {
                    param     = param,
                    current   = value,
                    optimal   = optimal,
                    deviation = deviation,
                    penalty   = score,
                })
            end

            if param == "feeder" then
                -- EN: Feed rate → throughput only.
                effScore = effScore + score
                effCount = effCount + 1
            elseif param == "rotor" or param == "concave" then
                -- EN: Rotor/concave → both throughput AND threshing loss (dual physical effect).
                effScore = effScore + score ;  effCount = effCount + 1
                thrScore = thrScore + score ;  thrCount = thrCount + 1
            elseif param == "fan" or param == "upperSieve" or param == "lowerSieve" then
                -- EN: Fan/sieves → cleaning loss only.
                cleanScore = cleanScore + score
                cleanCount = cleanCount + 1
            elseif param == "chopLength" or param == "kernelProcessor" then
                -- EN: Forage cut/processing quality → nutritional loss (mapped to cleanScore channel).
                cleanScore = cleanScore + score
                cleanCount = cleanCount + 1
            elseif param == "acceleratorGap" then
                -- EN: ASYMMETRIC — direction of deviation matters.
                --   Too tight (value < optimal): rotor must push crop through a narrower gap → extra
                --     power draw → speed penalty. Real machines slow down under the extra load.
                --   Too open  (value > optimal): crop is under-accelerated → doesn't reach the wagon,
                --     silage spills at the spout → processing/discharge quality penalty. No power
                --     cost, so no speed hit (the engine actually has headroom to go faster).
                --   At optimal: balanced — discharge quality bonus, no speed penalty.
                -- UA: АСИМЕТРИЧНО — напрямок відхилення визначає канал штрафу.
                --   Занадто тісний зазор → зайве навантаження двигуна → штраф швидкості.
                --   Занадто великий зазор → слабке прискорення маси → штраф якості виходу.
                local signed = value - optimal  -- negative = too tight, zero/positive = optimal or too open
                if signed < 0 then
                    -- Gap too tight → power cost → speed penalty
                    effScore   = effScore   + score ;  effCount   = effCount   + 1
                    if self.machineType == "forage" then
                        -- EN: Tight accelerator gaps also bruise/overwork forage, so the
                        --     processing score must drop even when engine load is low.
                        cleanScore = cleanScore + score ;  cleanCount = cleanCount + 1
                    end
                else
                    -- Optimal or gap too open → discharge quality penalty (or bonus at centre)
                    cleanScore = cleanScore + score ;  cleanCount = cleanCount + 1
                end
            else
                -- EN: Unknown param → split evenly across all three channels.
                effScore   = effScore   + score * 0.5 ;  effCount   = effCount   + 0.5
                thrScore   = thrScore   + score * 0.3 ;  thrCount   = thrCount   + 0.3
                cleanScore = cleanScore + score * 0.2 ;  cleanCount = cleanCount + 0.2
            end
        end
    end

    -- EN: Normalize so that machines with fewer parameters reach the same scale as a
    --     5-parameter grain combine (2 eff params, 2 thr params, 3 clean params).
    if effCount   > 0 then effScore   = effScore   * (2.0 / effCount)   end
    if thrCount   > 0 then thrScore   = thrScore   * (2.0 / thrCount)   end
    if cleanCount > 0 then cleanScore = cleanScore * (3.0 / cleanCount) end

    local effPenalty = math.max(-1.0, math.min(effScore,   20.0))
    local thrLoss    = math.max(-0.5, math.min(thrScore,   20.0))
    local cleanLoss  = math.max(-1.5, math.min(cleanScore, 20.0))

    if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
        print(string.format("RHM [checkSettings] crop=%s  eff=%.2f  thr=%.2f  clean=%.2f  warns=%d",
            tostring(cropName), effPenalty, thrLoss, cleanLoss, #warnings))
    end

    return effPenalty, thrLoss, cleanLoss, warnings
end

-- EN: Sets a single parameter value (0-100) and switches to MANUAL mode.
-- UA: Встановлює значення одного параметру (0-100) і перемикає в MANUAL режим.
function CombineMemory:setParameter(paramName, value)
    -- EN: DIAG — always log so we can see every parameter touch.
    local prev = self.currentSettings and self.currentSettings[paramName]
    if self.currentSettings[paramName] ~= nil then
        if paramName == "targetEngineLoad" then
            self.currentSettings[paramName] = math.max(70, math.min(110, value))
            print(string.format("RHM: [MEM] setParameter %s: %s -> %s (targetEngineLoad)",
                tostring(paramName), tostring(prev), tostring(self.currentSettings[paramName])))
            return true
        end
        self.currentSettings[paramName] = math.max(0, math.min(100, value))
        self.mode = "MANUAL" -- EN: Any manual change overrides AUTO mode / UA: Будь-яка ручна зміна скасовує AUTO режим
        print(string.format("RHM: [MEM] setParameter %s: %s -> %s | mode=MANUAL",
            tostring(paramName), tostring(prev), tostring(self.currentSettings[paramName])))
        return true
    end
    print(string.format("RHM: [MEM] setParameter REJECTED (%s not in currentSettings) | value=%s",
        tostring(paramName), tostring(value)))
    return false
end

-- EN: Switches operating mode to AUTO or MANUAL.
--     AUTO: applies optimal crop settings immediately if a crop is already detected.
--           on a dedicated server without a crop yet, marks pending AUTO and waits.
--     MANUAL: disables auto-configuration.
-- UA: Переключає режим роботи на AUTO або MANUAL.
--     AUTO: застосовує оптимальні налаштування для культури якщо вона вже визначена.
--           на виділеному сервері без культури — позначає очікуючий AUTO і чекає.
--     MANUAL: вимикає автоконфігурацію.
function CombineMemory:setMode(mode)
    if mode == "AUTO" then
        if self.currentCrop then
            self:autoConfigureForCrop(self.currentCrop, true)
        else
            -- EN: Dedicated server: crop not yet detected. Store mode for later when crop is first harvested.
            -- UA: Виділений сервер: культура ще не визначена. Зберігаємо режим до першого збору врожаю.
            self.mode = "AUTO"
            self.autoSwitchEnabled = true
            if self.debug then
                print("RHM: [AUTO] currentCrop is nil on DS, pending AUTO mode set. Will apply when crop detected.")
            end
        end
    elseif mode == "MANUAL" then
        self.mode = "MANUAL"
    end
end

-- EN: Returns the number of profiles currently available.
--     Returns cached count (not iterated per-call for performance).
-- UA: Повертає кількість поточно доступних профілів.
--     Повертає кешоване значення (не перебирає кожен виклик для продуктивності).
function CombineMemory:getProfileCount()
    return self.profileCount or 0
end

-- EN: Returns an alphabetically sorted list of all saved profile names.
-- UA: Повертає алфавітно відсортований список всіх збережених назв профілів.
function CombineMemory:getProfileNames()
    local names = {}
    for profileName, _ in pairs(self.savedProfiles) do
        table.insert(names, profileName)
    end
    table.sort(names)
    return names
end

-- EN: Updates harvesting statistics for the current profile: total harvested and rolling average loss.
--     Uses the crop's actual fill type density from g_fillTypeManager for accurate mass calculation.
-- UA: Оновлює статистику збирання для поточного профілю: загальний збір і ковзаюче середнє втрат.
--     Використовує реальну густину типу врожаю з g_fillTypeManager для точного розрахунку маси.
function CombineMemory:updateStatistics(harvestedLiters, cropLoss, cropName)
    if self.currentProfile and self.savedProfiles[self.currentProfile] then
        local profile = self.savedProfiles[self.currentProfile]

        -- EN: Get density from fill type manager, fallback to 0.75 kg/L if not available.
        -- UA: Отримуємо густину з менеджера типів врожаю, запасний варіант 0.75 кг/л.
        local density = 0.75
        if cropName and g_fillTypeManager and CombineSettingsDatabase then
            local cropData = CombineSettingsDatabase:getCropData(cropName)
            if cropData and cropData.fillType then
                local fillTypeObj = g_fillTypeManager:getFillTypeByIndex(cropData.fillType)
                if fillTypeObj and fillTypeObj.massPerLiter and fillTypeObj.massPerLiter > 0 then
                    density = fillTypeObj.massPerLiter * 1000 -- EN: t/L → kg/L / UA: т/л → кг/л
                end
            end
        end

        local tons = harvestedLiters * density / 1000
        profile.stats.totalHarvested = profile.stats.totalHarvested + tons

        -- EN: Update rolling average loss (5% blend toward new value).
        -- UA: Оновлюємо ковзаюче середнє втрат (5% змішування до нового значення).
        if profile.stats.averageLoss == 0 then
            profile.stats.averageLoss = cropLoss
        else
            profile.stats.averageLoss = profile.stats.averageLoss * 0.95 + cropLoss * 0.05
        end
    end
end

-- EN: Switches to a new crop: saves the current crop's profile, sets the new crop,
--     then loads its profile or applies auto/default settings depending on mode.
-- UA: Переключається на нову культуру: зберігає профіль поточної культури, встановлює нову,
--     а потім завантажує її профіль або застосовує авто/стандартні налаштування залежно від режиму.
function CombineMemory:switchCrop(newCropName)
    -- EN: DIAG — loud print so we can see every time switchCrop is called and with what context.
    --     The #1 suspect when loaded settings appear to reset is an unwanted switchCrop firing
    --     right after onPostLoad (e.g. crop auto-detect kicking in on spawn).
    print(string.format("RHM: [MEM] switchCrop ENTER newCrop=%s | prevCrop=%s | mode=%s | autoSwitch=%s | tier=%s",
        tostring(newCropName), tostring(self.currentCrop), tostring(self.mode),
        tostring(self.autoSwitchEnabled), tostring(self.upgradeLevel)))

    if not newCropName or newCropName == self.currentCrop then
        print(string.format("RHM: [MEM] switchCrop EXIT early (no change) newCrop=%s", tostring(newCropName)))
        return
    end

    if self.currentCrop then
        print(string.format("RHM: [MEM] switchCrop saving profile for old crop=%s", tostring(self.currentCrop)))
        self:saveCurrentProfile(self.currentCrop)
    end

    self.currentCrop = newCropName

    local pm = g_realisticHarvestManager and g_realisticHarvestManager.profileManager
    if pm and pm:getProfile(newCropName) then
        print(string.format("RHM: [MEM] switchCrop — existing profile found for %s, calling loadUserPreset()", newCropName))
        self:loadUserPreset()
    else
        -- EN: Auto-apply optimal settings only if Auto Pilot upgrade (tier 4) is installed.
        --     Lower tiers keep 50% neutral defaults — player must set manually.
        -- UA: Автоматичне застосування оптимальних налаштувань тільки з апгрейдом Автопілот (рівень 4).
        local hasAutoPilot = (self.upgradeLevel or 0) >= 4
        if self.autoSwitchEnabled and hasAutoPilot then
            print(string.format("RHM: [MEM] switchCrop — no profile, AUTO PILOT active → autoConfigureForCrop(%s, true)", newCropName))
            self:autoConfigureForCrop(newCropName, true)
        else
            print(string.format("RHM: [MEM] switchCrop — no profile, applying BASELINE defaults for %s (hasAutoPilot=%s, autoSwitch=%s)",
                newCropName, tostring(hasAutoPilot), tostring(self.autoSwitchEnabled)))
            self:autoConfigureForCrop(newCropName, false)
        end
    end

    local s = self.currentSettings or {}
    print(string.format("RHM: [MEM] switchCrop EXIT currentCrop=%s | fan=%s rotor=%s upper=%s lower=%s concave=%s",
        tostring(self.currentCrop),
        tostring(s.fan), tostring(s.rotor), tostring(s.upperSieve), tostring(s.lowerSieve), tostring(s.concave)))
end

-- ============================================================================
-- EN: GUI HELPER WRAPPERS — simplify interaction between GUI and memory.
-- UA: ОБГОРТКИ ДЛЯ GUI — спрощують взаємодію між GUI і пам'яттю.
-- ============================================================================

-- EN: Updates a single setting and sends a network event to the server in multiplayer.
--     Automatically switches to MANUAL mode and disables auto-switch.
-- UA: Оновлює одне налаштування і надсилає мережеву подію серверу в мультиплеєрі.
--     Автоматично переключається в MANUAL режим і вимикає автоперемикання.
function CombineMemory:updateSetting(param, value)
    local success = self:setParameter(param, value)
    if success then
        if param ~= "targetEngineLoad" then
            self.autoSwitchEnabled = false
            self.mode = "MANUAL"
        end

        -- EN: Persist the updated setting to the crop profile so the player never loses
        --     manually-configured values even if they exit without a crop switch.
        --     Debounced to at most one disk write per second — the scroll wheel and slider drag
        --     can fire updateSetting many times per second; we mark dirty and let the clock gate.
        --     Only saves when a crop is active — avoids creating a phantom "nil" profile entry.
        -- UA: Зберігаємо оновлене налаштування у профіль культури (з дебаунсом 1с).
        if self.currentCrop then
            local now = g_currentMission and g_currentMission.time or 0
            self._profileDirty = true
            if not self._lastProfileSaveTime or (now - self._lastProfileSaveTime) >= 1000 then
                self._lastProfileSaveTime = now
                self._profileDirty = false
                self:saveCurrentProfile(self.currentCrop)
            end
        end

        if g_client and self.combine then
            local event = CombineSettingsEvent.new(self.combine, param, self.currentSettings[param], false, nil)
            if not g_server then
                g_client:getServerConnection():sendEvent(event)
            else
                local conn = g_currentMission and g_currentMission.player and g_currentMission.player.serverConnection or nil
                event:run(conn)
            end
        end
    end
    return success
end

-- EN: Toggles the auto-switch mode flag. In multiplayer, sends a network event to the server.
--     In singleplayer, applies locally and immediately configures for the current crop if switching to AUTO.
-- UA: Перемикає прапорець режиму автоперемикання. У мультиплеєрі надсилає мережеву подію серверу.
--     В однокористувацькій грі застосовує локально і негайно налаштовує для поточної культури при переключенні в AUTO.
function CombineMemory:toggleAutoMode()
    if g_client and self.combine and not g_server then
        -- EN: Multiplayer client: send request to server.
        -- UA: Клієнт мультиплеєру: надсилаємо запит на сервер.
        local targetMode = not self.autoSwitchEnabled
        local event = CombineSettingsEvent.new(self.combine, "AUTO_MODE", targetMode and 1 or 0)
        g_client:getServerConnection():sendEvent(event)
        if self.debug then
            print(string.format("RHM: [Sync] Sent AUTO mode request to server: %s", targetMode and "ON" or "OFF"))
        end
    else
        -- EN: Singleplayer or server: apply immediately.
        -- UA: Однокористувацька або сервер: застосовуємо негайно.
        self.autoSwitchEnabled = not self.autoSwitchEnabled

        if self.autoSwitchEnabled then
            self.mode = "AUTO"
            if self.currentCrop then
                self:autoConfigureForCrop(self.currentCrop, true)
            end
        else
            self.mode = "MANUAL"
        end
        if self.debug then
            print(string.format("RHM: Auto Switch %s", self.autoSwitchEnabled and "ENABLED" or "DISABLED"))
        end
    end
end

-- EN: Alias for saveCurrentProfile for backward compatibility with GUI code.
-- UA: Псевдонім для saveCurrentProfile для зворотної сумісності з кодом GUI.
function CombineMemory:saveProfile(cropName)
    return self:saveCurrentProfile(cropName)
end

print("[OK] CombineMemory class loaded")
