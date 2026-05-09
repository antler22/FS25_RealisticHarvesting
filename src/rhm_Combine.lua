-- EN: Core FS25 vehicle specialization for the Realistic Harvesting mod.
--     Overrides key combine functions (addCutterArea, addFillUnitFillLevel, getSpeedLimit, etc.)
--     to integrate physics-based load calculation, crop-loss simulation, and combine settings.
--     Handles savegame serialization, multiplayer network streams, and input action registration.
--     Supports modular harvesting systems like NEXAT via hierarchy-aware input hooks.
-- UA: Основна спеціалізація транспортного засобу FS25 для мода Realistic Harvesting.
--     Перевизначає ключові функції комбайна (addCutterArea, addFillUnitFillLevel, getSpeedLimit тощо)
--     для інтеграції фізичного розрахунку навантаження, симуляції втрат врожаю та налаштувань комбайна.
--     Обробляє серіалізацію збереження, мережеві потоки мультиплеєра та реєстрацію дій вводу.
--     Підтримує модульні системи збирання як NEXAT через хуки вводу з урахуванням ієрархії.
rhm_Combine = {}
rhm_Combine.debug = false

-- EN: Capture mod name at file-load time, while g_currentModName is still valid.
--     By the time vehicle lifecycle events (onLoad, onPostLoad, etc.) fire, g_currentModName
--     is nil or belongs to a different mod — using this captured value is the only safe approach.
-- UA: Зберігаємо назву моду під час завантаження файлу, поки g_currentModName ще дійсний.
local RHM_MOD_NAME = g_currentModName or "FS25_RealisticHarvesting"

-- EN: Checks if the vehicle has the base Combine specialization.
--     Returns true for all machines including modular systems like NEXAT.
-- UA: Перевіряє чи транспортний засіб має базову спеціалізацію Combine.
--     Повертає true для всіх машин, включаючи модульні системи на кшталт NEXAT.
function rhm_Combine.prerequisitesPresent(specializations)
    -- EN: Print all specialization class names for diagnostic logging.
    -- UA: Виводимо всі назви класів спеціалізацій для діагностичного логування.
    print("========================================")
    print("RHM: Checking prerequisites for vehicle")
    print("Available specializations:")
    for specName, specTable in pairs(specializations) do
        if type(specTable) == "table" and specTable.className then
            print("  - " .. specTable.className)
        end
    end
    
    -- Перевіряємо базову specialization Combine
    local hasCombine = SpecializationUtil.hasSpecialization(Combine, specializations)
    print("Has Combine: " .. tostring(hasCombine))
    
    -- Для Nexat: тимчасово спрощуємо перевірку
    -- Повертаємо true якщо просто є Combine
    print("Result: " .. tostring(hasCombine))
    print("========================================")
    
    return hasCombine
end

-- EN: Registers rhm_Combine's overwritten (proxied) functions before event listeners.
--     These intercept combine core behaviors to inject our load and speed logic.
-- UA: Реєструє перевизначені (proxy) функції rhm_Combine до подій-прислухачів.
--     Ці функції перехоплюють основні поведінки комбайна для вбудованої логіки навантаження і швидкості.
function rhm_Combine.registerOverwrittenFunctions(vehicleType)
    print("RHM: Registering overwritten functions for rhm_Combine")
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "addCutterArea", rhm_Combine.addCutterArea)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "addFillUnitFillLevel", rhm_Combine.addFillUnitFillLevel)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSpeedLimit", rhm_Combine.getSpeedLimit)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "startThreshing", rhm_Combine.startThreshing)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "stopThreshing", rhm_Combine.stopThreshing)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "verifyCombine", rhm_Combine.verifyCombine)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanBeTurnedOn", rhm_Combine.getCanBeTurnedOn)
end

-- EN: Canonical FS25 specialization lifecycle hook. Called by SpecializationManager:initSpecializations()
--     AFTER Vehicle.xmlSchemaSavegame has been created (Vehicle.init runs first). This is THE
--     correct place to register savegame XML schema paths — it's what every base-game spec does
--     (see Combine.initSpecialization in scripts/vehicles/specializations/Combine.lua, which
--     registers "vehicles.vehicle(?).combine#isSwathActive" etc. at this hook).
--
--     Previously we tried to register schema in registerEventListeners (too early — schema is nil)
--     and fell back to a deferred registration in onLoad (works but fragile). This is the canonical
--     time and removes timing questions entirely.
--
--     We still keep the onLoad fallback as a defensive net in case this hook is skipped for any
--     reason (e.g. hot-reload path that bypasses initSpecializations).
-- UA: Канонічний хук життєвого циклу спеціалізації FS25. Викликається SpecializationManager:initSpecializations()
--     ПІСЛЯ створення Vehicle.xmlSchemaSavegame. Це правильне місце для реєстрації шляхів XML
--     збереження — так роблять всі базові спеціалізації (див. Combine.initSpecialization).
function rhm_Combine.initSpecialization()
    print("RHM: [INIT] rhm_Combine.initSpecialization() fired")
    if Vehicle and Vehicle.xmlSchemaSavegame then
        local basePath = string.format("vehicles.vehicle(?).%s.rhm_Combine", RHM_MOD_NAME)
        rhm_Combine.registerXMLPaths(Vehicle.xmlSchemaSavegame, basePath)
        rhm_Combine._schemaRegistered = true
        print(string.format("RHM: [INIT] Savegame XML schema registered at canonical hook | basePath=%s", basePath))
    else
        print(string.format("RHM: [INIT] WARNING — Vehicle.xmlSchemaSavegame still nil in initSpecialization | Vehicle=%s",
            tostring(Vehicle ~= nil)))
    end
end

-- EN: Registers XML paths for vehicle config (shop/modDesc XML). Persists combine settings per-vehicle.
-- UA: Реєструє шляхи XML для конфігурації засобу (XML магазину/modDesc). Зберігає налаштування комбайна для кожного засобу.
function rhm_Combine.registerXMLPaths(schema, basePath)
    local cur = basePath .. ".combineMemory.current"
    schema:register(XMLValueType.STRING, cur .. "#mode",         "Combine settings mode", "AUTO")
    schema:register(XMLValueType.STRING, cur .. "#currentCrop",  "Current crop", "")
    schema:register(XMLValueType.BOOL,   cur .. "#autoSwitch",   "Auto switch enabled", true)
    schema:register(XMLValueType.INT,    cur .. "#fan",          "Fan", 50)
    schema:register(XMLValueType.INT,    cur .. "#upperSieve",   "Upper sieve", 50)
    schema:register(XMLValueType.INT,    cur .. "#lowerSieve",   "Lower sieve", 50)
    schema:register(XMLValueType.INT,    cur .. "#rotor",        "Rotor", 50)
    schema:register(XMLValueType.INT,    cur .. "#concave",      "Concave gap (grain) / Feed roll (others)", 50)
    schema:register(XMLValueType.INT,    cur .. "#feeder",       "Feeder (legacy / forage+root+cotton)", 50)
    schema:register(XMLValueType.INT,    cur .. "#upgradeLevel",       "Upgrade tier (0-4)", 0)
    schema:register(XMLValueType.INT,    cur .. "#targetEngineLoad",   "Target engine load % (0-100)", 95)
end

-- EN: Mirrors registerXMLPaths for the savegame vehicles.xml schema.
--     Called automatically by FS25 for every specialization when the savegame schema is registered.
-- UA: Дзеркально дублює registerXMLPaths для схеми vehicles.xml збереження.
--     Викликається автоматично FS25 для кожної спеціалізації при реєстрації схеми збереження.
function rhm_Combine.registerSavegameXMLPaths(schema, basePath)
    rhm_Combine.registerXMLPaths(schema, basePath)
end

-- EN: Registers event listeners for the spec's lifecycle hooks:
--     onLoad, onUpdateTick, onDraw, stream read/write, XML save/load, input actions.
--     Also registers savegame XML schema paths via Vehicle.xmlSchemaSavegame as a critical fix
--     for programmatically-added specializations that are otherwise missed.
-- UA: Реєструє подій-прислухачі для хуків життєвого циклу спец:
--     onLoad, onUpdateTick, onDraw, читання/запис потоків, XML збереження/завантаження, дії вводу.
--     Також реєструє шляхи XML схеми збереження через Vehicle.xmlSchemaSavegame як критичне виправлення
--     для спеціалізацій доданих програмно, які інакше пропускаються.
function rhm_Combine.registerEventListeners(vehicleType)
    print("RHM: Registering event listeners for rhm_Combine")
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", rhm_Combine)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", rhm_Combine)
    SpecializationUtil.registerEventListener(vehicleType, "onDraw", rhm_Combine)

    -- SAVEGAME: Збереження та завантаження стану
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", rhm_Combine)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", rhm_Combine)

    -- SAVEGAME XML:
    -- EN: saveToXMLFile is called DIRECTLY per-spec by Vehicle:saveToXMLFile (not through the event
    --     system). Registering it as an event listener would cause a second call with wrong arguments.
    --     We do NOT register it here — the function is picked up automatically because it exists on
    --     the rhm_Combine class table and Vehicle.lua checks v191_.saveToXMLFile ~= nil.
    -- EN: onPostLoad IS a proper spec event — register normally.
    -- UA: saveToXMLFile викликається напряму з Vehicle:saveToXMLFile, НЕ через систему подій.
    --     onPostLoad — справжня подія спеціалізації.
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", rhm_Combine)

    -- MULTIPLAYER: Синхронізація даних між сервером і клієнтом
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", rhm_Combine)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", rhm_Combine)

    -- INPUT: Реєструємо події введення
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", rhm_Combine)

    -- EN: Register savegame XML schema paths for our spec. FS25 only auto-registers schema paths
    --     for configuration item classes; programmatically-added specializations like ours must do
    --     this manually via Vehicle.xmlSchemaSavegame.
    -- UA: Реєструємо шляхи XML схеми збереження для нашої спец. FS25 робить це автоматично тільки
    --     для класів конфігурації; програмно додані спеціалізації мають зробити це вручну.
    if Vehicle and Vehicle.xmlSchemaSavegame then
        -- EN: Use module-level RHM_MOD_NAME — g_currentModName unreliable at validateTypes time.
        -- UA: Використовуємо RHM_MOD_NAME — g_currentModName ненадійний під час validateTypes.
        local basePath = string.format("vehicles.vehicle(?).%s.rhm_Combine", RHM_MOD_NAME)
        rhm_Combine.registerXMLPaths(Vehicle.xmlSchemaSavegame, basePath)
        print(string.format("RHM: [SCHEMA-DIAG] Registered savegame XML schema paths | basePath=%s", basePath))
    else
        print(string.format("RHM: [SCHEMA-DIAG] WARNING - Vehicle.xmlSchemaSavegame is %s | Vehicle=%s",
            tostring(Vehicle and Vehicle.xmlSchemaSavegame),
            tostring(Vehicle ~= nil)))
    end
end

-- EN: Global hook for non-combine vehicles in a modular system (e.g. NEXAT main tractor).
--     The standard rhm_Combine:onRegisterActionEvents only fires for vehicles that have spec_rhm_Combine.
--     For NEXAT, the player drives the main tractor which doesn't. We solve this by hooking
--     Vehicle.onRegisterActionEvents globally: if the vehicle doesn't have our spec but IS in
--     a hierarchy that contains one, we still register RHM_OPEN_MENU on it.
-- UA: Глобальний хук для транспортних засобів шо не є комбайнами в модульній системі (напр. головний трактор NEXAT).
--     Стандартний rhm_Combine:onRegisterActionEvents викликається лише для засобів з spec_rhm_Combine.
--     Для NEXAT гравець керує трактором який цього не має. Ми вирішуємо це хуком
--     глобального Vehicle.onRegisterActionEvents: якщо засіб не має нашої спец, але IE в ієрархії з нею, ми все одно реєструємо RHM_OPEN_MENU.

local function RHM_globalOnRegisterActionEvents(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    -- Skip if this is already a combine with our spec (handled by rhm_Combine:onRegisterActionEvents)
    if vehicle.spec_rhm_Combine then
        return
    end
    
    -- Only register if the player is actively in this vehicle
    if not isActiveForInputIgnoreSelection then
        return
    end
    
    -- Only on client
    if not vehicle.isClient then
        return
    end
    
    -- Check if there's a combine with our spec in the hierarchy
    local function hasCombineInHierarchy(v, visited)
        if not v or visited[v] then return false end
        visited[v] = true
        if v.spec_rhm_Combine then return true end
        if v.rootVehicle and hasCombineInHierarchy(v.rootVehicle, visited) then return true end
        if v.attacherVehicle and hasCombineInHierarchy(v.attacherVehicle, visited) then return true end
        if v.getAttachedImplements then
            for _, impl in ipairs(v:getAttachedImplements() or {}) do
                if impl.object and hasCombineInHierarchy(impl.object, visited) then return true end
            end
        end
        return false
    end
    
    local searchRoot = vehicle.rootVehicle or vehicle
    if not hasCombineInHierarchy(searchRoot, {}) then
        return
    end
    
    -- Register RHM_OPEN_MENU for this NEXAT-style vehicle
    if not vehicle._rhmActionEvents then
        vehicle._rhmActionEvents = {}
    end
    vehicle:clearActionEventsTable(vehicle._rhmActionEvents)
    
    if InputAction.RHM_OPEN_MENU then
        local _, eventId = vehicle:addActionEvent(vehicle._rhmActionEvents, InputAction.RHM_OPEN_MENU, vehicle,
            function(self, ...)
                if g_realisticHarvestManager then
                    g_realisticHarvestManager:toggleMenu(self)
                end
            end, false, true, false, true, nil)
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
        -- print("RHM: [NEXAT] Registered RHM_OPEN_MENU for non-combine vehicle: " .. tostring(vehicle:getFullName()))
    end
end

-- Apply global hook ONCE (guard against double-loading)
if not rhm_Combine._nexatHookApplied then
    rhm_Combine._nexatHookApplied = true
    Vehicle.onRegisterActionEvents = Utils.appendedFunction(
        Vehicle.onRegisterActionEvents,
        RHM_globalOnRegisterActionEvents
    )
    print("RHM: [NEXAT] Global Vehicle.onRegisterActionEvents hook applied.")
end
-- ============================================================================

-- EN: Called when the combine vehicle is loaded. Creates and wires up all subsystems:
--     LoadCalculator, machineType detection, CombineMemory, HUD data table, dirty flags,
--     and network throttling. Loads settings from XML if savegame exists.
-- UA: Викликається при завантаженні комбайна. Створює і підключає всі підсистеми:
--     LoadCalculator, визначення типу машини, CombineMemory, таблиця даних HUD, прапорці "dirty",
--     і тротлінг мережі. Завантажує налаштування з XML якщо існує збереження.
function rhm_Combine:onLoad(savegame)
    -- EN: Deferred savegame schema registration.
    --     Vehicle.xmlSchemaSavegame is nil during registerEventListeners (too early), but IS
    --     available by the time onLoad fires. Schema validation is lazy (per-getValue call),
    --     so registering here — before onPostLoad's getValue calls — is sufficient.
    --     The class-level flag ensures we only do this once regardless of how many combines load.
    -- UA: Відкладена реєстрація схеми збереження.
    --     Vehicle.xmlSchemaSavegame є nil під час registerEventListeners, але доступний до onLoad.
    if not rhm_Combine._schemaRegistered then
        if Vehicle and Vehicle.xmlSchemaSavegame then
            local basePath = string.format("vehicles.vehicle(?).%s.rhm_Combine", RHM_MOD_NAME)
            rhm_Combine.registerXMLPaths(Vehicle.xmlSchemaSavegame, basePath)
            rhm_Combine._schemaRegistered = true
            print(string.format("RHM: [SCHEMA] Savegame XML schema registered (deferred to onLoad) | basePath=%s", basePath))
        else
            Logging.warning("[RHM] Vehicle.xmlSchemaSavegame is still nil in onLoad — savegame persistence unavailable")
        end
    end

    -- EN: Use the module-level captured mod name (safe at event-call time).
    -- UA: Використовуємо захоплену назву моду рівня модуля (безпечна під час подій).
    local modName = RHM_MOD_NAME
    local specName = string.format("spec_%s.rhm_Combine", modName)

    self.spec_rhm_Combine = self[specName]
    local spec = self.spec_rhm_Combine

    if not spec then
        Logging.error("RHM: Failed to initialize spec for combine: %s (specName: %s)",
            tostring(self:getFullName()), tostring(specName))
        return
    end

    -- Синхронізація дебаг-прапорця з основним менеджером
    rhm_Combine.debug = RHM_Debug.isEnabled("Combine")
    
    if rhm_Combine.debug then
        print(string.format("RHM: onLoad called for %s (has savegame: %s)", 
            tostring(self:getFullName()), tostring(savegame ~= nil)))
    end
    
    -- Створюємо LoadCalculator з modDirectory
    local modDir = g_realisticHarvestManager and g_realisticHarvestManager.modDirectory or g_currentModDirectory
    
    if not LoadCalculator then
        Logging.error("RHM: LoadCalculator class is missing! Check script loading order.")
        return
    end

    spec.loadCalculator = LoadCalculator.new(modDir)
    
    if not spec.loadCalculator then
        Logging.error("RHM: Failed to create LoadCalculator for combine: %s", self:getFullName())
        return
    end
    
    -- EN: Calculate base throughput from engine horsepower (set before machine type detection).
    -- UA: Розраховуємо базову пропускну здатність з потужності двигуна (встановлюється до визначення типу машини).
    local basePerf = spec.loadCalculator:getBasePerformanceFromPower(self)
    spec.loadCalculator:setBasePerformance(basePerf)
    
    -- EN: Detect machine type from FS25 specialization signals (verified from log analysis).
    --     Grain:  allowThreshingDuringRain=false and strawEffects.n>0
    --     Root:   spec_fruitPreparer present OR (cutter present, no pipe)
    --     Forage: allowThreshingDuringRain=true AND pipe AND no cutter
    --     Cotton: grain spec but fill unit stores FillType.COTTON
    -- UA: Визначаємо тип машини за сигналами спеціалізацій FS25 (підтверджено аналізом логів).
    --     Зернова: allowThreshingDuringRain=false і strawEffects.n>0
    --     Коренеплід: є spec_fruitPreparer АБО (є cutter, немає pipe)
    --     Форажна: allowThreshingDuringRain=true І pipe І немає cutter
    --     Бавовна: spec зернової але fill unit зберігає FillType.COTTON

    local machineType = "grain"  -- safe default
    local sc = self.spec_combine

    if sc then
        -- EN: Detection Priorities:
        -- 1. Explicit harvester specializations (ForageHarvester / CottonPicker / RootHarvester)
        -- 2. Physical features (Straw effects = Grain combine)
        -- 3. Capability signals (Rain work + Pipe + No Cutter = Forage)
        
        local isForageHarvester = SpecializationUtil.hasSpecialization(ForageHarvester, self.specializations)
        -- EN: FS25 API: iterate fill units to check if any supports COTTON (getFillUnitIndexByFillType does not exist in FS25).
        -- UA: API FS25: ітеруємо fill units щоб перевірити чи будь-яка підтримує COTTON (getFillUnitIndexByFillType не існує в FS25).
        local isCottonHarvester = false
        if FillType.COTTON then
            local fillUnits = self:getFillUnits()
            if fillUnits then
                for _, fillUnit in ipairs(fillUnits) do
                    if fillUnit.supportedFillTypes and fillUnit.supportedFillTypes[FillType.COTTON] then
                        isCottonHarvester = true
                        break
                    end
                end
            end
        end
        local hasStrawEffects = sc.strawEffects and #sc.strawEffects > 0
        local canThreshInRain = sc.allowThreshingDuringRain

        if self.spec_fruitPreparer then
            -- Cleaning / dirt removal → Root harvester
            machineType = "root"
        elseif isForageHarvester then
            machineType = "forage"
        elseif isCottonHarvester then
            machineType = "cotton"
        elseif hasStrawEffects then
            -- Grain combine always has straw effects, regardless of rain capability
            machineType = "grain"
        elseif canThreshInRain then
            local hasPipe   = self.spec_pipe   ~= nil
            local hasCutter = self.spec_cutter ~= nil

            if hasPipe and not hasCutter then
                -- Forage harvester fallback (if spec check failed)
                machineType = "forage"
            elseif hasCutter and not hasPipe then
                -- Direct-cut vegetable harvester
                machineType = "root"
            else
                machineType = "root"
            end
        else
            -- Unknown: treat as grain
            machineType = "grain"
        end
    end

    spec.machineType = machineType
    print(string.format("RHM: [OK] Machine type detected: %s (pipe=%s, cutter=%s, rainOK=%s, fruitPrep=%s)",
        machineType,
        tostring(self.spec_pipe ~= nil),
        tostring(self.spec_cutter ~= nil),
        tostring(sc and sc.allowThreshingDuringRain),
        tostring(self.spec_fruitPreparer ~= nil)))


    -- EN: Create the combine memory system for current settings. Link it to LoadCalculator
    --     so that setting adjustments affect the live load and loss calculations.
    -- UA: Створюємо систему пам'яті для поточних налаштувань. Підключаємо до LoadCalculator
    --     щоб регулювання налаштувань впливало на поточні розрахунки навантаження і втрат.
    spec.combineMemory = CombineMemory.new(self, machineType)
    spec.loadCalculator.combineMemory = spec.combineMemory

    -- EN: For vehicles newly purchased from the store: read the selected rhm_upgradeTier
    --     configuration index and apply it as the starting upgrade level.
    --     (For vehicles loaded from savegame, onPostLoad takes MAX of XML and store values.)
    -- UA: Для нових транспортних засобів, куплених у магазині: зчитуємо вибраний індекс
    --     конфігурації rhm_upgradeTier і встановлюємо його як початковий рівень апгрейду.
    if RHMShopIntegration then
        local storeLevel = RHMShopIntegration.getUpgradeLevelFromConfig(self)
        if storeLevel and storeLevel > 0 then
            spec.combineMemory.upgradeLevel = storeLevel
            print(string.format("RHM: [Shop] New vehicle — upgrade level set to %d from store config", storeLevel))
        end
    end

    print("RHM: [OK] Combine Settings System initialized")

    
    -- EN: HUD live data table — all fields are updated every tick on the server and synced to clients.
    -- UA: Таблиця живих даних HUD — всі поля оновлюються кожний тік на сервері і синхронізуються на клієнти.
    spec.data = {
        speed = 0,
        load = 0,
        cropLoss = 0,          -- EN: Total crop loss % (thrLoss + cleanLoss) / UA: Загальні втрати врожаю (%)
        thrLoss  = 0,          -- EN: Threshing loss % (overload + rotor/concave) / UA: Втрати обмолоту (%)
        cleanLoss = 0,         -- EN: Cleaning loss % (fan/sieves) / UA: Втрати очистки (%)
        headerLoss = 0,        -- EN: Speed-related header loss (%) / UA: Втрати від швидкості на жатці (%)
        tonPerHour = 0,
        litersPerHour = 0,
        yield = 0,
        recommendedSpeed = 0,  -- EN: Updated by server tick, synced to clients / UA: Оновлюється сервером, синхронізується на клієнти
        overloadLevel = 0,     -- EN: 0=normal, 1=HIGH (120%+), 2=CRITICAL (150%+) — synced for warning display / UA: 0=норма, 1=ВИСОКЕ (120%+), 2=КРИТИЧНЕ (150%+)
        isPlugged = false,     -- EN: True when rotor plug is active / UA: True коли активне засмічення ротора
        moistureLabel = "",    -- EN: Short label for current moisture condition (legacy — not drawn anymore) / UA: Коротка мітка поточного стану вологості (застаріле)
        grainMoisture = 13.0,  -- EN: Grain moisture % — always shown on HUD. External Moisture System mod overrides; otherwise derived from time of day. / UA: Вологість зерна у % — завжди на HUD. Зовнішній мод перекриває; інакше — похідне від часу доби.
        moistureSource = "time-of-day",  -- EN: "external" = from Moisture System mod, "time-of-day" = our own computation / UA: Джерело
        plugTimerPct = 0,      -- EN: 0-100% progress toward plug (for HUD warning ramp-up) / UA: 0-100% прогрес до засмічення
    }

    -- EN: Start session tracking immediately on load.
    -- UA: Починаємо відстеження сесії відразу при завантаженні.
    spec.loadCalculator:startSession()
    
    -- EN: Area accumulators — lastArea kept for legacy; totalCumulativeArea/prevCumulativeArea
    --     power the timing-safe delta calculation in onUpdateTick.
    -- UA: Акумулятори площі — lastArea збережено для сумісності.
    spec.lastArea = 0
    spec.lastLiters = 0
    spec.totalCumulativeArea  = 0
    spec.prevCumulativeArea   = 0
    
    -- Відстеження поточної жатки для визначення зміни
    spec.currentCutter = nil
    
    -- Прапорець чи активне обмеження швидкості
    spec.isSpeedLimitActive = false
    
    -- MULTIPLAYER: Dirty flags для роздільної синхронізації
    -- spec.dataDirtyFlag: часто оновлювана телеметрія (throttle)
    -- spec.settingsDirtyFlag: зміни налаштувань CombineMemory (тільки при зміні)
    spec.dataDirtyFlag = self:getNextDirtyFlag()
    spec.settingsDirtyFlag = self:getNextDirtyFlag()
    spec.dirtyFlag = spec.dataDirtyFlag -- Fallback if needed
    
    -- Тротлінг мережевих оновлень (MP/DS)
    spec.lastDataUpdateTime = 0
    spec.dataUpdateInterval = 200 -- 5 разів на секунду
    spec.lastSyncedData = {}
    
    -- INPUT: Таблиця для подій введення
    spec.actionEvents = {}
    
    -- TEST: Прапорець для показу тестового повідомлення
    spec.testMessageShown = false
end

-- EN: Override for addFillUnitFillLevel — tracks actual liters added to the bunker (hopper).
--     Only counts when actively cutting (lastRawArea > 0) to avoid counting offloading.
--     The fill type is captured for yield density lookup.
-- UA: Перевизначення addFillUnitFillLevel — відстежує фактичні літри додані до бункера (бункеру).
--     Рахує лише при активному косінні (lastRawArea > 0) щоб не рахувати вивантаження.
--     Тип врожаю захоплюється для пошуку густини врожаю.
function rhm_Combine:addFillUnitFillLevel(superFunc, ...)
    local r1, r2, r3, r4, r5, r6 = superFunc(self, ...)
    local actualAdded = r1 -- Base game returns actual delta as first arg

    -- ── FORAGE-FILL diagnostic ───────────────────────────────────────────────
    -- Fires on EVERY call so we can see whether the forage harvester's fill unit
    -- is receiving liters and whether the isCutting guard lets them through.
    local fdbg = self.spec_rhm_Combine
    if fdbg and fdbg.combineMemory and fdbg.combineMemory.machineType == "forage" then
        local _, fillUnitIndex, fillLevelDelta, fillTypeIndex = ...
        local ftName = "nil"
        if fillTypeIndex and g_fillTypeManager then
            local ftd = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if ftd then ftName = ftd.name or "?" end
        end
        local isCutting = (fdbg.totalCumulativeArea or 0) > (fdbg.prevCumulativeArea or 0)
        print(string.format(
            "RHM: [FORAGE-FILL] unit=%s fillType=%s delta=%.3f actualAdded=%s isCutting=%s totalArea=%.6f prevArea=%.6f lastLiters=%.3f",
            tostring(fillUnitIndex), ftName, fillLevelDelta or 0, tostring(actualAdded),
            tostring(isCutting),
            fdbg.totalCumulativeArea or 0, fdbg.prevCumulativeArea or 0,
            fdbg.lastLiters or 0))
    end
    -- ────────────────────────────────────────────────────────────────────────

    local spec = self.spec_rhm_Combine
    if spec and actualAdded and type(actualAdded) == "number" and actualAdded > 0 then
        -- EN: Count liters only when the machine is actively harvesting.
        --
        --     isCutting path (grain combines + direct-cut forage like corn silage):
        --       totalCumulativeArea grows each tick via addCutterArea → isCutting = true.
        --       Filters out auger-unload and tank-sync events (area stops growing when idle).
        --
        --     isForagePickup path (pickup forage headers picking up windrows):
        --       Pickup heads collect windrows by removing the fill-type density map directly —
        --       they NEVER call addCutterArea, so totalCumulativeArea is permanently 0 and
        --       isCutting is permanently false even while material is flowing.
        --       For forage machines in this state we trust actualAdded > 0 on a non-UNKNOWN
        --       fill type as the harvest signal.  Forage harvesters have no external fill
        --       source that could produce false positives here (no auger-unload into self).
        --
        -- UA: Рахуємо літри тільки при активному збиранні.
        --     isCutting — для зернових та прямого зрізу форажних.
        --     isForagePickup — для підбиральних форажних голівок (підбирач валків).
        local isCutting = (spec.totalCumulativeArea or 0) > (spec.prevCumulativeArea or 0)

        local farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData = ...
        local pickupCropName = nil
        if spec.combineMemory
           and spec.combineMemory.machineType == "forage"
           and fillTypeIndex ~= nil
           and fillTypeIndex ~= FillType.UNKNOWN
           and CombineSettingsDatabase then
            pickupCropName = CombineSettingsDatabase:getCropNameFromFillType(fillTypeIndex)
        end

        local isForagePickup = pickupCropName ~= nil and spec._foragePickupFillReady == true

        if isCutting or isForagePickup then
            spec.lastLiters = (spec.lastLiters or 0) + actualAdded

            if fillTypeIndex and fillTypeIndex ~= FillType.UNKNOWN then
                spec.lastFillType = fillTypeIndex

                -- EN: For forage pickup: addCutterArea is never called so currentCrop is never
                --     set via the normal path.  Derive it from the output fill type here so the
                --     forage throughput curve and HUD crop label both resolve correctly.
                --     (Direct-cut forage sets currentCrop in addCutterArea; this block is a no-op
                --     for that path because isCutting=true but isForagePickup is skipped.)
                -- UA: Для форажного підбирача: addCutterArea не викликається — встановлюємо
                --     currentCrop з типу наповнення щоб крива продуктивності та HUD відображали
                --     правильну культуру.
                if isForagePickup and not isCutting then
                    local cropName = pickupCropName
                    local currentCrop = spec.combineMemory and spec.combineMemory.currentCrop
                    if currentCrop == "TRITICALE_WINDROW" or currentCrop == "TRITICALE_FORAGE" then
                        local outName = nil
                        if g_fillTypeManager then
                            local outDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                            outName = outDesc and outDesc.name and string.upper(outDesc.name) or nil
                        end
                        if outName == "GRASS_WINDROW" or outName == "GRASS" then
                            cropName = currentCrop
                        end
                    end
                    if currentCrop == "PINTOBEAN_FORAGE" then
                        local outName = nil
                        if g_fillTypeManager then
                            local outDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                            outName = outDesc and outDesc.name and string.upper(outDesc.name) or nil
                        end
                        if outName == "CHAFF" then
                            cropName = currentCrop
                        end
                    end
                    if cropName and spec.loadCalculator then
                        spec.loadCalculator.currentCrop = cropName
                    end
                    if cropName and spec.combineMemory
                       and cropName ~= spec.combineMemory.currentCrop then
                        -- EN: Immediate switch — no debounce needed here; fill-type changes
                        --     only happen when the user physically changes what windrow the
                        --     machine is picking up, not tick-by-tick noise.
                        -- UA: Негайне перемикання — захист від дребезгу тут не потрібен.
                        rhm_Combine.onCropTypeChanged(self, cropName)
                    end
                end
            end
        end
    end
    
    return r1, r2, r3, r4, r5, r6
end

-- EN: Returns true when the attached cutter is a pickup-type header that collects windrowed
--     material (e.g. PICKUPHEADER_GRASS / hay pickup). Pickup headers are identified by having
--     spec_cutter.fillTypeConverter set — this is the FS25 mechanism that routes windrow
--     fill-type → harvester output and is absent on all direct-cut headers.
--
--     Why this matters for yield: the game's pixel-harvest area for a pickup header reflects
--     only the narrow physical pickup width (~12 ft / 3.65 m), NOT the original swath width
--     (e.g. 48 ft) that determined the crop mass.  Using pixel area here inflates yield ~4×.
--     When this function returns true, onUpdateTick uses (distance × manual swathWidth) instead.
-- UA: Повертає true коли підключена жатка є підбирачем валків (PICKUPHEADER_GRASS тощо).
--     Підбирачі ідентифікуються за наявністю spec_cutter.fillTypeConverter — механізм FS25,
--     що маршрутизує fill-тип валка → вивід комбайна; відсутній у всіх жатках прямого зрізу.
local function isPickupHeader(vehicle)
    local sc = vehicle.spec_combine
    if not sc or not sc.attachedCutters then return false end
    for cutter, _ in pairs(sc.attachedCutters) do
        if cutter.spec_cutter and cutter.spec_cutter.fillTypeConverter ~= nil then
            return true
        end
    end
    return false
end

-- EN: Override for addCutterArea — intercepts the raw (pixel-count) cutting area per tick.
--     Converts pixels to square meters using g_currentMission:getFruitPixelsToSqm().
--     Also captures fallback liters from the return value for forage harvesters without hoppers.
-- UA: Перевизначення addCutterArea — перехоплює сиру (піксельну) площу зрізу за тік.
--     Перетворює пікселі в квадратні метри з допомогою g_currentMission:getFruitPixelsToSqm().
--     Також зберігає запасні літри з поверненого значення для форажних комбайнів без бункера.
function rhm_Combine:addCutterArea(superFunc, ...)
    local area, realArea, inputFruitType, outputFillType, strawRatio, strawGroundType, farmId, cutterLoad = ...
    
    -- EN: Call super first to get the real data (liters, crop type) before we intercept.
    -- UA: Викликаємо super спочатку щоб отримати реальні дані (літри, тип культури) перед перехопленням.
    local r1, r2, r3, r4, r5, r6, r7, r8, r9, r10 = superFunc(self, ...)
    local retLiters = r1

    local spec = self.spec_rhm_Combine
    if not spec or not spec.loadCalculator then
        return r1, r2, r3, r4, r5, r6, r7, r8, r9, r10
    end

    -- ── FORAGE-CUT diagnostic ────────────────────────────────────────────────
    -- Fires on every addCutterArea call for forage machines.
    -- "area"     = pixel count passed by the cutter (2nd variadic arg in FS25 = area pixels)
    -- "liters_in"= liters the cutter computed before passing to Combine (3rd variadic arg)
    -- "retLiters"= what base-game Combine:addCutterArea returned (this feeds _fallbackLiters)
    -- If retLiters is always 0 while area > 0, the base game is short-circuiting the return.
    if spec.combineMemory and spec.combineMemory.machineType == "forage" then
        local _area, _litersIn, _inFT, _outFT = ...
        local outName, inName = "nil", "nil"
        if _outFT and g_fillTypeManager then
            local ftd = g_fillTypeManager:getFillTypeByIndex(_outFT)
            if ftd then outName = ftd.name or "?" end
        end
        if _inFT and g_fruitTypeManager then
            local ftd = g_fruitTypeManager:getFruitTypeByIndex(_inFT)
            if ftd then inName = ftd.name or "?" end
        end
        -- throttle: print every 30 calls so the log stays readable but dense
        spec._cutDbgCount = (spec._cutDbgCount or 0) + 1
        if spec._cutDbgCount % 30 == 1 then
            print(string.format(
                "RHM: [FORAGE-CUT #%d] area=%.4f liters_in=%.4f out=%s(%s) in=%s(%s) retLiters=%.4f fallbackAcc=%.4f",
                spec._cutDbgCount,
                _area or 0, _litersIn or 0,
                tostring(_outFT), outName, tostring(_inFT), inName,
                retLiters or 0,
                (spec._fallbackLiters or 0)))
        end
    end
    -- ────────────────────────────────────────────────────────────────────────
    
    -- EN: lastMultiplier kept for compatibility with older logic paths.
    -- UA: lastMultiplier збережено для сумісності зі старими логічними шляхами.
    local multiplier = 1.0
    
    -- EN: Convert 'area' (pixel-count) to real square metres using the mission's pixel-to-sqm ratio.
    --     This reliable formula works independently of map scale and Precision Farming bonuses.
    -- UA: Конвертуємо 'area' (кількість пікселів) у реальні квадратні метри використовуючи коефіцієнт місії.
    --     Ця надійна формула працює незалежно від масштабу карти і бонусів Precision Farming.
    local sqmMultiplier = 1.0
    if g_currentMission and type(g_currentMission.getFruitPixelsToSqm) == "function" then
        sqmMultiplier = g_currentMission:getFruitPixelsToSqm()
    end
    
    local areaForYield = area * sqmMultiplier

    -- EN: Swath/pickup width correction — if the user has defined a swath width override
    --     (for windrow pickup work), scale area so yield reflects the original cutting width
    --     rather than the narrow pickup header width.
    --     correction = swathWidth / headerWorkWidth. Only applied when swathWidth is set.
    --
    --     For pickup headers (isPickupHeader == true) we skip this block entirely:
    --     onUpdateTick calculates area as (distance × swathWidth) which already embeds the
    --     correct width.  Applying a pixel-area correction here as well would double-count.
    if spec.combineMemory and spec.combineMemory.swathWidth and spec.combineMemory.swathWidth > 0 then
        if isPickupHeader(self) then
            -- EN: Pickup header — area will be computed geometrically in onUpdateTick.
            --     No pixel-area correction needed or desired here.
            -- UA: Підбирач — площа буде розрахована геометрично в onUpdateTick.
            --     Корекція піксельної площі тут не потрібна.
        else
            -- EN: Walk attached cutters to find the working header width.
            --     spec_combine.attachedCutters is the authoritative FS25 source; spec.combine is nil.
            -- UA: Обходимо підключені жатки щоб знайти робочу ширину заголовника.
            local headerW = 0
            local sc = self.spec_combine
            if sc and sc.attachedCutters then
                for c, _ in pairs(sc.attachedCutters) do
                    local wa = c.spec_workArea
                    if wa and wa.workAreas and wa.workAreas[1] then
                        headerW = wa.workAreas[1].workWidth or 0
                    end
                    if headerW <= 0 and type(c.getWorkAreaWidth) == "function" then
                        headerW = c:getWorkAreaWidth(1) or 0
                    end
                    if headerW > 0 then break end
                end
            end
            if headerW > 0.5 then
                areaForYield = areaForYield * (spec.combineMemory.swathWidth / headerW)
            end
        end
    end

    -- EN: Accumulate area monotonically — never reset between ticks.
    --     onUpdateTick computes the per-tick delta (totalArea - prevArea), which eliminates
    --     the timing dependency between the cutter's onUpdateTick and the combine's onUpdateTick.
    --     The old lastRawArea/lastArea reset-per-tick pattern broke forage harvesters because
    --     FS25 updates the combine (parent) before the attached header, so addCutterArea fired
    --     AFTER onUpdateTick had already read and reset the accumulator.
    -- UA: Накопичуємо площу монотонно — ніколи не скидаємо між тіками.
    spec.totalCumulativeArea = (spec.totalCumulativeArea or 0) + areaForYield
    spec.lastArea = (spec.lastArea or 0) + (areaForYield * multiplier)  -- EN: kept for legacy / UA: збережено для сумісності
    spec.lastMultiplier = multiplier
    
    -- EN: Save fallback liters from the return value for forage harvesters without hoppers.
    --     If there's a hopper, addFillUnitFillLevel will capture precise liters instead.
    -- UA: Зберігаємо запасні літри з поверненого значення для форажних комбайнів без бункера.
    --     Якщо бункер є, addFillUnitFillLevel перехопить точні літри натомість.
    if (retLiters or 0) > 0 then
        spec._fallbackLiters = (spec._fallbackLiters or 0) + retLiters
    end
    
    -- EN: Store crop type and handle change
    -- UA: Зберігаємо тип культури та обробляємо зміну
    if outputFillType and outputFillType ~= FillType.UNKNOWN then
        spec.lastFillType = outputFillType
        
        -- === YIELD CALCULATION REMOVED ===
        -- Reason: Calculating yield per-slice (addCutterArea) is statistically wrong because
        -- it treats small slices (partial overlap) equally to large slices in the moving average buffer.
        -- We now rely on 'onUpdateTick' which aggregates Total Mass / Total Area for the frame,
        -- providing a mathematically correct weighted average.
        
        -- if (retLiters or 0) > 0 and areaForYield > 0.001 then
        --    ...
        -- end

        -- EN: Determine crop name from CombineSettingsDatabase — full table including
        --     grain, roots (POTATO/ONION/CARROT), vegetables (SPINACH/GREENBEAN), and forage outputs.
        -- UA: Визначаємо назву культури через CombineSettingsDatabase — повна таблиця включаючи
        --     зернові, коренеплоди (POTATO/ONION/CARROT), овочі (SPINACH/GREENBEAN) та форажні виводи.
        local cropName = CombineSettingsDatabase:getCropNameFromFillType(outputFillType)
        
        -- EN: Fallback for forage harvesters: they output CHAFF but inputFruitType=MAIZE.
        --     getCropNameFromFillType(CHAFF) returns "MAIZE_FORAGE" usually, but try inputFruitType if not.
        -- UA: Резервний варіант для форажних комбайнів: вони виводять CHAFF але inputFruitType=MAIZE.
        --     getCropNameFromFillType(CHAFF) зазвичай повертає "MAIZE_FORAGE", але спробуємо inputFruitType якщо ні.
        if not cropName and inputFruitType and inputFruitType ~= FillType.UNKNOWN then
            cropName = CombineSettingsDatabase:getCropNameFromFillType(inputFruitType)
        end
        
        if cropName then
            -- EN: Update current crop in LoadCalculator.
            -- UA: Оновлюємо поточну культуру в LoadCalculator.
            spec.loadCalculator.currentCrop = cropName
            
            -- EN: Detect crop change with 2-second debounce to avoid thrash when header
            --     partially overlaps two crop types and flips between them each tick.
            -- UA: Визначаємо зміну культури з 2-секундним захистом від дребезгу щоб уникнути
            --     переключення коли жатка частково перекриває два типи культур і перемикає між ними кожен тік.
            if cropName ~= spec.combineMemory.currentCrop then
                -- DEBOUNCE: чекаємо 2 секунди перед перемикання
                -- Без цього жатка може детектувати різні культури кожен тік і створювати петлю
                local now = g_currentMission.time
                spec._lastCropSwitchTime = spec._lastCropSwitchTime or 0
                
                if spec._pendingCrop ~= cropName then
                    -- EN: New crop candidate detected / UA: Виявлено нового кандидата
                    spec._pendingCrop = cropName
                    spec._lastCropSwitchTime = now
                elseif (now - spec._lastCropSwitchTime) >= 2000 then
                    -- EN: Confirmed after 2 seconds / UA: Підтверджено після 2 секунд
                    spec._pendingCrop = nil
                    if rhm_Combine and rhm_Combine.debug then
                        print(string.format("RHM: [CROP] Detected crop: %s", cropName))
                    end
                    rhm_Combine.onCropTypeChanged(self, cropName)
                end
            else
                -- EN: Same crop, cancel any staged switch.
                -- UA: Та сама культура, скасовуємо заплановане перемикання.
                spec._pendingCrop = nil
            end
        end
    else
        -- EN: No crop coming through (not harvesting) — clear staged crop.
        -- UA: Не надходить культура (не збираємо) — очищаємо плановану культуру.
        spec._pendingCrop = nil
    end
    
    -- EN: One-shot cut-area diagnostic — fires once per unique (outputFillType, inputFruitType) pair.
    --     Always active (no debug flag needed). Search log for "[CUT-DIAG]" when a new windrow
    --     crop produces no yield/load: it shows exactly what fill type and fruit type the game
    --     passed, letting you add the missing entry to CombineSettingsDatabase.fillTypeMapping.
    -- UA: Одноразова діагностика зрізу — спрацьовує один раз на унікальну пару типів.
    if areaForYield > 0 then
        if not spec._cutDiagPrinted then spec._cutDiagPrinted = {} end
        local diagKey = tostring(outputFillType) .. "_" .. tostring(inputFruitType)
        if not spec._cutDiagPrinted[diagKey] then
            spec._cutDiagPrinted[diagKey] = true
            local outName, inName = "nil", "nil"
            if g_fillTypeManager and outputFillType then
                local ftd = g_fillTypeManager:getFillTypeByIndex(outputFillType)
                if ftd then outName = ftd.name or "?" end
            end
            if g_fruitTypeManager and inputFruitType then
                local ftd = g_fruitTypeManager:getFruitTypeByIndex(inputFruitType)
                if ftd then inName = ftd.name or "?" end
            end
            local detectedCrop = spec.loadCalculator and spec.loadCalculator.currentCrop or "nil"
            print(string.format(
                "RHM: [CUT-DIAG] outputFillType=%s(%s) inputFruitType=%s(%s) retLiters=%.2f area=%.4f detectedCrop=%s machineType=%s",
                tostring(outputFillType), outName,
                tostring(inputFruitType), inName,
                retLiters or 0,
                areaForYield,
                detectedCrop,
                tostring(spec.combineMemory and spec.combineMemory.machineType or "nil")))
        end
    end

    return r1, r2, r3, r4, r5, r6, r7, r8, r9, r10
end

-- EN: Called when the detected crop type changes. Delegates to CombineMemory:switchCrop which
--     saves the old profile, loads the new one, and triggers network sync.
--     Does NOT set currentCrop directly — switchCrop handles all state transitions.
-- UA: Викликається при зміні визначеного типу культури. Делегує до CombineMemory:switchCrop який
--     зберігає старий профіль, завантажує новий та запускає мережеву синхронізацію.
--     НЕ встановлює currentCrop напряму — switchCrop обробляє всі переходи стану.
function rhm_Combine:onCropTypeChanged(newCropName)
    local spec = self.spec_rhm_Combine
    if not spec or not spec.combineMemory then
        return
    end
    
    -- EN: Delegate to switchCrop — it sets currentCrop, saves old profile, loads new one.
    --     Do NOT set currentCrop here directly!
    -- UA: Делегуємо до switchCrop — він встановлює currentCrop, зберігає старий, завантажує новий.
    --     НЕ встановлювати currentCrop тут напряму!
    spec.combineMemory:switchCrop(newCropName)
    
    -- EN: Sync crop change and settings to clients in multiplayer.
    -- UA: Синхронізуємо зміну культури та налаштувань для клієнтів у мультиплеєрі.
    if self.isServer then
        self:raiseDirtyFlags(spec.dirtyFlag)
    end
end

-- EN: Override for getSpeedLimit. Returns a dynamically calculated speed cap from LoadCalculator
--     that maintains ~90% engine load target. Disabled on clients (uses synced recommendedSpeed).
--     Respects the Arcade difficulty mode (no speed limiting), the enableSpeedLimit setting,
--     and only activates when the cutter is actually lowered and working.
-- UA: Перевизначення getSpeedLimit. Повертає динамічний ліміт швидкості від LoadCalculator
--     який підтримує ~90% навантаження двигуна. Вимкнено на клієнтах (використовує synced recommendedSpeed).
--     Поважає режим складності Arcade (без обмеження швидкості), налаштування enableSpeedLimit,
--     та активується лише коли жатка реально опущена і працює.
function rhm_Combine:getSpeedLimit(superFunc, onlyIfWorking)
    local spec = self.spec_rhm_Combine
    
    -- EN: Call original to get the game's base speed limit and check flag.
    -- UA: Викликаємо оригінал щоб отримати базовий ліміт швидкості гри і прапорець перевірки.
    local limit, doCheckSpeedLimit = superFunc(self, onlyIfWorking)
    
    -- EN: If spec not initialized (vehicle loading), return original limit unchanged.
    -- UA: Якщо spec не ініціалізований (завантаження транспорту), повертаємо оригінальний ліміт без змін.
    if not spec or not spec.loadCalculator then
        return limit, doCheckSpeedLimit
    end

    -- EN: PLUG OVERRIDE: When rotor is plugged, bring the combine to a near-stop (1 km/h).
    --     This applies regardless of Speed Control tier — a plugged combine cannot move.
    -- UA: ПЕРЕВИЗНАЧЕННЯ ПРИ ЗАСМІЧЕННІ: При засміченні ротора зупиняємо комбайн (1 км/год).
    if spec.loadCalculator.isPlugged then
        spec.isSpeedLimitActive = true
        return math.min(limit, 1.0), doCheckSpeedLimit
    end

    -- EN: Skip speed limiting if the thresher is off.
    -- UA: Пропускаємо обмеження швидкості якщо молотарка вимкнена.
    if not self:getIsTurnedOn() then
        spec.isSpeedLimitActive = false
        return limit, doCheckSpeedLimit
    end
    
    -- EN: CRITICAL FIX: Check if the cutter is actually WORKING (not just attached).
    --     If the cutter is raised or not cutting — do NOT limit speed.
    --     Same check as onUpdateTick: isTurnedOn + speed > 0.5 + lowered (or allowCuttingWhileRaised).
    -- UA: КРИТИЧНЕ ВИПРАВЛЕННЯ: Перевіряємо чи жатка дійсно ПРАЦЮЄ (не просто прикріплена).
    --     Якщо жатка піднята або не косить — НЕ обмежуємо швидкість.
    --     Та ж перевірка що й у onUpdateTick: isTurnedOn + speed > 0.5 + опущена (або allowCuttingWhileRaised).
    local spec_combine = self.spec_combine
    local cutterIsWorking = false
    
    if spec_combine and spec_combine.attachedCutters then
        for cutter, _ in pairs(spec_combine.attachedCutters) do
            if cutter.spec_cutter then
                local spec_cutter = cutter.spec_cutter
                -- FIX: Use same check as onUpdateTick - do NOT check movingDirection,
                -- as Courseplay can set it differently. Only check isTurnedOn + speed + isLowered.
                cutterIsWorking = cutter:getIsTurnedOn()
                    and self:getLastSpeed() > 0.5
                    and (spec_cutter.allowCuttingWhileRaised or cutter:getIsLowered(true))
                
                if cutterIsWorking then
                    break -- Знайшли працюючу жатку
                end
            end
        end
    end
    
    -- Якщо жатка НЕ працює - знімаємо обмеження відразу
    if not cutterIsWorking then
        spec.isSpeedLimitActive = false
        return limit, doCheckSpeedLimit
    end
    
    -- EN: Speed Automation requires Level 3 (Speed Automation upgrade).
    --     Below level 3 the combine has no auto speed control — player manages speed manually.
    --     The old enableSpeedLimit toggle has been removed; upgrade level is the sole gate.
    -- UA: Автоматика швидкості вимагає рівня 3 (Speed Automation).
    --     Нижче рівня 3 комбайн не має автоматичного контролю швидкості.
    if spec.combineMemory and (spec.combineMemory.upgradeLevel or 0) < 3 then
        spec.isSpeedLimitActive = false
        return limit, doCheckSpeedLimit
    end

    -- EN: In Arcade difficulty mode, don't limit speed (like vanilla game).
    -- UA: В режимі складності Arcade не обмежуємо швидкість (як у ванільній грі).
    if g_realisticHarvestManager and g_realisticHarvestManager.settings
            and g_realisticHarvestManager.settings.difficultyMotor == 1 then
        spec.isSpeedLimitActive = false
        return limit, doCheckSpeedLimit
    end
    
    -- EN: If the cutter changed, reset genuineSpeedLimit to recalibrate for the new header's speed range.
    -- UA: Якщо жатка змінилась, скидаємо genuineSpeedLimit для рекалібрування під новий діапазон швидкостей.
    if spec_combine and spec_combine.attachedCutters then
        local currentCutter = nil
        for cutter, _ in pairs(spec_combine.attachedCutters) do
            currentCutter = cutter
            break -- Беремо першу жатку
        end
        
        -- Якщо жатка змінилася, скидаємо genuineSpeedLimit
        if currentCutter ~= spec.currentCutter and currentCutter ~= nil then
            spec.currentCutter = currentCutter
            spec.loadCalculator.genuineSpeedLimit = -1 -- EN: Reset to initial value / UA: Скидаємо до початкового значення
        end
    end
    
    -- EN: Enforce a minimum harvestable speed of 8 mph (12.87 km/h) so players can always reach
    --     speeds where header losses become significant, regardless of a header's XML maxWorkingSpeed.
    --     The calculatedLimit from LoadCalculator can still drop below this when the combine is
    --     overloaded — this floor only sets the ceiling, not the active limit.
    -- UA: Мінімальна швидкість збирання 8 mph (12.87 км/год) — щоб гравці могли досягти швидкостей,
    --     при яких виникають втрати жатки, незалежно від maxWorkingSpeed у XML жатки.
    local MIN_HARVEST_KMH = 12.87
    if limit ~= math.huge and limit < MIN_HARVEST_KMH then
        limit = MIN_HARVEST_KMH
    end

    -- EN: Set genuineSpeedLimit ONCE. Cap at 20 km/h (12.4 mph) — no grain combine should harvest
    --     faster than that. The vanilla limit passed here is the vehicle's ROAD speed (40-55 km/h
    --     for modern combines), NOT the working speed, because grain cutter doCheckSpeedLimit=false
    --     means the cutter does not contribute a lower cap. Without this cap the recommendedSpeed
    --     display would climb to the vehicle's road speed when the combine is under-loaded.
    -- UA: Встановлюємо genuineSpeedLimit ОДИН РАЗ. Обмежуємо 20 км/год — жоден зерновий комбайн
    --     не повинен збирати швидше. Ванільний ліміт тут — дорожня швидкість (40-55 км/год),
    --     а не робоча, бо жатка не знижує ліміт (doCheckSpeedLimit=false).
    if spec.loadCalculator.genuineSpeedLimit == -1 and limit ~= math.huge then
        local harvestCap = math.min(limit, 20.0)
        spec.loadCalculator:setGenuineSpeedLimit(harvestCap, harvestCap)
    end
    
    -- EN: MULTIPLAYER FIX: LoadCalculator only runs on the server.
    --     Clients must use the synced spec.data.recommendedSpeed value.
    -- UA: ВИПРАВЛЕННЯ МУЛЬТИПЛЕЕРА: LoadCalculator оновлюється лише на сервері.
    --     Клієнти повинні використовувати синхронізоване значення spec.data.recommendedSpeed.
    if not self.isServer then
        -- CLIENT: Use synced value from server
        if spec.data and spec.data.recommendedSpeed then
            local syncedLimit = spec.data.recommendedSpeed
            
            -- Apply synced limit if it's actively limiting (< genuineSpeedLimit)
            if syncedLimit < spec.loadCalculator.genuineSpeedLimit then
                spec.isSpeedLimitActive = true
                limit = syncedLimit
            else
                spec.isSpeedLimitActive = false
            end
        end
        
        return limit, doCheckSpeedLimit
    end
    
    -- === SERVER: Continue with normal LoadCalculator logic ===
    -- Отримуємо обмеження з LoadCalculator
    local calculatedLimit = spec.loadCalculator:getSpeedLimit()
    local engineLoad = spec.loadCalculator:getEngineLoad()
    
    -- Діагностика: логуємо розрахунки (рідше)
    if not self._speedLimitLogTime or (g_currentMission.time - self._speedLimitLogTime) > 2000 then
        -- Logging.info("RHM: [getSpeedLimit] Load: %.1f%%, Calc limit: %.1f, Orig limit: %.1f", 
        --     engineLoad, calculatedLimit, limit)
        self._speedLimitLogTime = g_currentMission.time
    end
    
    -- EN: ALWAYS apply the calculated limit, BUT NEVER exceed vanilla game limits (ModHub requirement).
    --     This ensures root harvesters (like Dewulf) don't run at 11km/h when their base workspeed is 8km/h.
    -- UA: ЗАВЖДИ застосовуємо розрахований ліміт, АЛЕ НІКОЛИ не перевищуємо ванільні ліміти гри (вимога ModHub).
    --     Це гарантує, що коренезбиральні комбайни (як Dewulf) не їдуть 11 км/год, коли їх базова робоча швидкість 8 км/год.
    spec.isSpeedLimitActive = true
    
    -- MODHUB FIX: Cap speed to the game's actual base limit
    limit = math.min(limit, calculatedLimit)
    
    -- Логуємо тільки коли РЕАЛЬНО обмежуємо
    if not self._lastLimitLog or math.abs(self._lastLimitLog - limit) > 0.5 then
        -- Logging.info("RHM: [getSpeedLimit] *** LIMITING SPEED to %.1f km/h (load: %.1f%%) ***", 
        --     limit, engineLoad)
        self._lastLimitLog = limit
    end
    
    return limit, doCheckSpeedLimit
end

-- EN: Override for getCanBeTurnedOn. Blocks thresher start if any attached cutter is not ready
--     (e.g. a folded header that hasn't been unfolded). Falls back to vanilla logic if no cutters.
-- UA: Перевизначення getCanBeTurnedOn. Блокує запуск молотарки якщо будь-яка прикріплена жатка
--     не готова (напр. складена жатка що не розкладена). Повертається до ванільної логіки без жаток.
function rhm_Combine:getCanBeTurnedOn(superFunc)
    local spec_combine = self.spec_combine
    
    -- EN: No cutters attached — use vanilla logic.
    -- UA: Немає прикріплених жаток — використовуємо ванільну логіку.
    if spec_combine.numAttachedCutters <= 0 then
        return superFunc(self)
    end
    
    -- EN: Check each attached cutter — if any is not ready (e.g. folded), block thresher start.
    -- UA: Перевіряємо кожну прикріплену жатку — якщо хоча б одна не готова (напр. складена), блокуємо запуск.
    for cutter, _ in pairs(spec_combine.attachedCutters) do
        if cutter ~= self and cutter.getCanBeTurnedOn ~= nil then
            -- EN: Use pcall to prevent infinite loops if cutter's getCanBeTurnedOn invokes the combine
            -- UA: Використовуємо pcall щоб уникнути нескінченних циклів
            local success, canTurnOn = pcall(cutter.getCanBeTurnedOn, cutter)
            if success and not canTurnOn then
                return false
            end
        end
    end

    return superFunc(self)
end

-- EN: Override for startThreshing. Conditionally starts attached cutters based on settings.
--     If Independent Launch is enabled: cutters only auto-start for AI (not the player).
--     If Independent Launch is disabled: cutters always auto-start (classic vanilla behavior).
--     Always plays threshing animations and sounds regardless of cutter start logic.
-- UA: Перевизначення startThreshing. Умовно запускає прикріплені жатки залежно від налаштувань.
--     Якщо Незалежний Запуск увімкнений: жатки автоматично запускаються лише для AI (не для гравця).
--     Якщо Незалежний Запуск вимкнений: жатки завжди запускаються автоматично (класична ванільна поведінка).
--     Завжди відтворює анімації та звуки молотарки незалежно від логіки запуску жатки.
function rhm_Combine:startThreshing(superFunc)
    -- EN: INTENTIONAL OMISSION OF superFunc(self)
    --     We DO NOT call superFunc(self) here. The game's vanilla startThreshing method automatically
    --     forces all attached cutters to turn on (and lowers them) for the player.
    --     By omitting it and replicating the animations/sounds manually, we enable the "Independent Launch"
    --     feature which allows players to control the thresher and cutter separately.
    -- UA: СВІДОМИЙ ПРОПУСК superFunc(self)
    --     Ми НЕ викликаємо superFunc(self). Ванільний метод автоматично запускає і опускає всі жатки гравця.
    --     Пропускаючи його і відтворюючи анімації вручну, ми робимо можливим "Незалежний запуск".
    local spec_combine = self.spec_combine
    
    -- EN: Read Independent Launch setting from manager.
    -- UA: Читаємо налаштування Незалежного Запуску з менеджера.
    local isIndependentLaunchEnabled = false
    if g_realisticHarvestManager and g_realisticHarvestManager.settings then
        isIndependentLaunchEnabled = g_realisticHarvestManager.settings.enableIndependentLaunch
    end
    
    -- EN: Cutter start logic:
    --     - Independent launch OFF → always start cutters (vanilla behavior)
    --     - Independent launch ON  → only start for AI workers
    -- UA: Логіка запуску жатки:
    --     - Незалежний запуск ВИМКНЕНИЙ → завжди запускаємо жатки (ванільна поведінка)
    --     - Незалежний запуск УВІМКНЕНИЙ → запускаємо лише для AI
    local isAIActive = self:getIsAIActive()
    local shouldStartCutters = (not isIndependentLaunchEnabled) or (isIndependentLaunchEnabled and isAIActive)
    
    if spec_combine.numAttachedCutters > 0 and shouldStartCutters then
        -- EN: Start cutters — always for AI, for player only when Independent Launch is disabled.
        -- UA: Запускаємо жатки — завжди для AI, для гравця лише коли Незалежний Запуск вимкнений.
        local isTurning = type(self.rootVehicle.getAIFieldWorkerIsTurning) == "function" and self.rootVehicle:getAIFieldWorkerIsTurning()
        local allowLowering = not self:getIsAIActive() or not isTurning
        
        for _, cutter in pairs(spec_combine.attachedCutters) do
            if allowLowering and cutter ~= self then
                local jointDescIndex = self:getAttacherJointIndexFromObject(cutter)
                self:setJointMoveDown(jointDescIndex, true, true)
            end
            
            cutter:setIsTurnedOn(true, true)
        end
    end
    
    -- Анімації та звуки молотарки (завжди)
    if spec_combine.threshingStartAnimation ~= nil and self.playAnimation ~= nil then
        self:playAnimation(spec_combine.threshingStartAnimation, spec_combine.threshingStartAnimationSpeedScale, self:getAnimationTime(spec_combine.threshingStartAnimation), true)
    end
    
    if self.isClient then
        g_soundManager:stopSample(spec_combine.samples.stop)
        g_soundManager:stopSample(spec_combine.samples.work)
        g_soundManager:playSample(spec_combine.samples.start)
        g_soundManager:playSample(spec_combine.samples.work, 0, spec_combine.samples.start)
    end
    
    SpecializationUtil.raiseEvent(self, "onStartThreshing")
end

-- EN: Override for stopThreshing. Stops threshing sounds/animations and disables fill mode.
--     Does NOT stop cutters automatically (player controls them independently via Independent Launch).
-- UA: Перевизначення stopThreshing. Зупиняє звуки/анімації молотарки та вимикає режим наповнення.
--     НЕ вимикає жатки автоматично (гравець керує ними незалежно через Незалежний Запуск).
function rhm_Combine:stopThreshing(superFunc)
    -- EN: INTENTIONAL OMISSION OF superFunc(self)
    --     Like startThreshing, we DO NOT call superFunc(self) here to prevent the base game from 
    --     automatically turning off the attached cutters when the thresher stops.
    -- UA: СВІДОМИЙ ПРОПУСК superFunc(self)
    --     Як і в startThreshing, ми НЕ викликаємо superFunc(self) щоб завадити базовій грі
    --     автоматично вимикати жатки при зупинці молотарки.
    local spec_combine = self.spec_combine
    
    if self.isClient then
        g_soundManager:stopSample(spec_combine.samples.start)
        g_soundManager:stopSample(spec_combine.samples.work)
        g_soundManager:playSample(spec_combine.samples.stop)
    end
    
    self:setCombineIsFilling(false, false, true)
    local isFull = self:getCombineFillLevelPercentage() > 0.999
    if isFull and self.rootVehicle.setCruiseControlState ~= nil then
        self.rootVehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF)
    end
    
    -- EN: Do NOT stop cutters automatically — player controls them independently.
    -- UA: НЕ вимикаємо жатки автоматично — гравець керує ними незалежно.
    
    if spec_combine.threshingStartAnimation ~= nil and spec_combine.playAnimation ~= nil then
        self:playAnimation(spec_combine.threshingStartAnimation, -spec_combine.threshingStartAnimationSpeedScale, self:getAnimationTime(spec_combine.threshingStartAnimation), true)
    end
    
    SpecializationUtil.raiseEvent(self, "onStopThreshing")
end

-- EN: Override for verifyCombine. Blocks harvesting when the thresher is off
--     (prevents collecting crop when only the cutter is running without the thresher).
--     AI is exempt from this check.
-- UA: Перевизначення verifyCombine. Блокує збирання врожаю коли молотарка вимкнена
--     (запобігає збору культури коли увімкнена лише жатка без молотарки).
--     AI звільнений від цієї перевірки.
function rhm_Combine:verifyCombine(superFunc, fruitType, outputFillType)
    local isAIActive = self:getIsAIActive()
    
    -- EN: Block harvesting if thresher is off (unless AI is active).
    -- UA: Блокуємо збирання якщо молотарка вимкнена (якщо тільки AI не активний).
    if not self:getIsTurnedOn() and not isAIActive then
        return nil  -- Блокуємо харвестинг
    end
    
    return superFunc(self, fruitType, outputFillType)
end

---Check for safety warnings (Client Side)
function rhm_Combine:updateWarnings(dt)
    -- Only for active vehicle
    if not self:getIsActiveForInput(true) then
        return
    end

    local isCombineOn = self:getIsTurnedOn()
    local spec_combine = self.spec_combine
    
    -- Iterate attached cutters
    if spec_combine.attachedCutters then
        for cutter, _ in pairs(spec_combine.attachedCutters) do
            local isCutterOn = cutter:getIsTurnedOn()
            local isLowered = cutter:getIsLowered()
            
            -- CASE 1: Cutter ON but Thresher OFF (Critical)
            if isCutterOn and not isCombineOn then
                g_currentMission:showBlinkingWarning(g_i18n:getText("rhm_warning_turn_on_combine"), 2000)
                break -- Priority warning
            end
            
            -- CASE 2: Thresher ON but Cutter OFF and Lowered (Likely forgot to turn on)
            if isCombineOn and not isCutterOn and isLowered then
                g_currentMission:showBlinkingWarning(g_i18n:getText("rhm_warning_turn_on_cutter"), 2000)
                break
            end
        end
    end
end

-- EN: Called on every game tick. Runs warning checks on client, load/yield/speed calculations on server.
--     Server side: detects if thresher or cutter is off and resets HUD data accordingly.
--     Passes harvested mass and area to LoadCalculator for physics-based engine load calculation.
-- UA: Викликається кожен тік гри. Запускає перевірки попереджень на клієнті, розрахунки навантаження/врожайності/швидкості на сервері.
--     Серверна сторона: визначає якщо молотарка або жатка вимкнена і скидає дані HUD відповідно.
--     Передає зібрану масу та площу до LoadCalculator для фізичного розрахунку навантаження двигуна.
function rhm_Combine:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    -- EN: Client-side: update safety warnings only.
    -- UA: Клієнтська сторона: лише оновлення попереджень безпеки.
    if self.isClient then
        rhm_Combine.updateWarnings(self, dt)
    end
    
    if not self.isServer then
        return
    end
    
    local spec = self.spec_rhm_Combine
    local spec_combine = self.spec_combine
    
    if not spec or not spec.loadCalculator then
        return
    end
    spec._foragePickupFillReady = true

    -- EN: Tick the time-of-day moisture update BEFORE any early-return paths so the
    --     HUD's moistureLabel / moisturePercent are refreshed even when the cutter is
    --     off, reversing, or idle. The updater is 60-second throttled internally so
    --     this costs next-to-nothing per tick.
    -- UA: Оновлюємо вологість часу доби до будь-яких ранніх виходів, щоб HUD мав свіжі
    --     moistureLabel/moisturePercent навіть коли жатка вимкнена.
    spec.loadCalculator:updateMoistureFactor(dt)

    -- EN: Check if combine thresher is on and driving forward; reset load if not.
    -- UA: Перевіряємо чи молотарка увімкнена і рухається вперед; скидаємо навантаження якщо ні.
    if not self:getIsTurnedOn() or self.movingDirection == -1 then
        -- EN: Thresher off or reversing — reset load calculation.
        -- UA: Молотарка вимкнена або рухається назад — скидаємо розрахунок навантаження.
        spec.loadCalculator:reset()
        if spec.data then
            spec.data.load = 0
            -- EN: Keep moisture fields populated from time-of-day so the HUD row stays visible
            --     even when the thresher is off / reversing (the updater ticked just above).
            -- UA: Тримаємо поля вологості заповненими навіть коли молотарка вимкнена.
            local lcOff = spec.loadCalculator
            spec.data.grainMoisture  = (lcOff and lcOff.moisturePercent) or 13.0
            spec.data.moistureLabel  = (lcOff and lcOff.moistureLabel) or ""
            spec.data.moistureSource = "time-of-day"
        end
        spec.isSpeedLimitActive = false
        return
    end
    
    -- EN: Check if the cutter is working. Uses same logic as getSpeedLimit:
    --     isTurnedOn AND speed > 0.5 AND lowered (or allowCuttingWhileRaised).
    --     Avoids movingDirection check that Courseplay can break.
    -- UA: Перевіряємо чи жатка працює. Використовує ту ж логіку що й getSpeedLimit:
    --     isTurnedOn І speed > 0.5 І опущена (або allowCuttingWhileRaised).
    --     Уникає перевірки movingDirection яку Courseplay може порушити.
    local cutterIsTurnedOn = false
    for cutter, _ in pairs(spec_combine.attachedCutters) do
        if cutter.spec_cutter then
            local spec_cutter = cutter.spec_cutter
            if cutter:getIsTurnedOn() 
                and self:getLastSpeed() > 0.5 
                and (spec_cutter.allowCuttingWhileRaised or cutter:getIsLowered(true)) then
                cutterIsTurnedOn = true
                break  -- EN: Found a working cutter — exit / UA: Знайшли працюючу — виходимо
            end
        end
    end
    
    if not cutterIsTurnedOn then
        -- EN: Cutter not working — still tick the plug countdown so it clears even while stopped.
        --     When plugged the speed drops to ~0, making cutterIsTurnedOn false, so without this
        --     the timer would never count down and the plug would never clear.
        -- UA: Жатка не працює — все одно тікаємо таймер засмічення щоб він очищувався навіть стоячи.
        if spec.loadCalculator.isPlugged then
            local plugChanged = spec.loadCalculator:updatePlugState(dt)
            if plugChanged then
                -- Plug cleared — sync state to clients.
                spec.data.isPlugged   = false
                spec.data.plugTimerPct = 0
                self:raiseDirtyFlags(spec.dataDirtyFlag)
            end
            -- EN: Don't return yet — fall through to sync below.
        end

        -- EN: Reset indicators so they don't stay visible while cutter is off.
        -- UA: Скидаємо індикатори щоб вони не висіли поки жатка вимкнена.
        spec.loadCalculator:reset()
        if spec.data then
            spec.data.load = 0
            spec.data.cropLoss = 0
            spec.data.tonPerHour = 0
            spec.data.litersPerHour = 0
            spec.data.yield = 0
            spec.data.recommendedSpeed = 0
            -- EN: Keep moisture fields populated from time-of-day even when idle so the HUD
            --     row renders a plant-material label (and grain % if external mod is active).
            --     moistureSource is forced to "time-of-day" while idle because the external
            --     mod's live-field query requires the cutter to be on.
            -- UA: Тримаємо поля вологості заповненими навіть в режимі простою.
            local lcIdle = spec.loadCalculator
            spec.data.grainMoisture  = (lcIdle and lcIdle.moisturePercent) or 13.0
            spec.data.moistureLabel  = (lcIdle and lcIdle.moistureLabel) or ""
            spec.data.moistureSource = "time-of-day"
        end
        spec.isSpeedLimitActive = false

        -- EN: Sync reset to clients so their HUD clears too.
        -- UA: Синхронізуємо скидання на клієнти щоб їх HUD теж очистився.
        self:raiseDirtyFlags(spec.dataDirtyFlag)

        return
    end
    
    -- EN: Crop detection was moved to addCutterArea with 2s debounce.
    --     Removed from onUpdateTick to prevent detection conflicts after bunker dump (false positives).
    -- UA: Детекція культури перенесена в addCutterArea з 2-сек захистом від дребезгу.
    --     Видалено з onUpdateTick щоб уникнути конфліктів після скидання бункера (хибні позитиви).
    
    -- EN: Calculate harvested mass from liters + fillType density. Forage harvesters use fallback liters.
    -- UA: Розраховуємо зібрану масу з літрів + густини fillType. Форажні комбайни використовують запасні літри.
    local massKg = 0
    local liters = spec.lastLiters or 0

    -- ── FORAGE-TICK diagnostic (pre-mass) ────────────────────────────────────
    if spec.combineMemory and spec.combineMemory.machineType == "forage" then
        spec._tickDbgCount = (spec._tickDbgCount or 0) + 1
        if spec._tickDbgCount % 30 == 1 then
            print(string.format(
                "RHM: [FORAGE-TICK #%d] lastLiters=%.4f _fallbackLiters=%.4f lastFillType=%s totalCumArea=%.6f prevCumArea=%.6f",
                spec._tickDbgCount,
                spec.lastLiters or 0,
                spec._fallbackLiters or 0,
                tostring(spec.lastFillType),
                spec.totalCumulativeArea or 0,
                spec.prevCumulativeArea or 0))
        end
    end
    -- ────────────────────────────────────────────────────────────────────────

    -- EN: Fall back to liters captured by addCutterArea for forage harvesters (no hopper).
    -- UA: Використовуємо запасні літри з addCutterArea для форажних комбайнів (без бункера).
    if liters <= 0 and (spec._fallbackLiters or 0) > 0 then
        liters = spec._fallbackLiters
    end
    
    if liters > 0 then
        -- EN: Use our real-world density table (UnitConverter) rather than FS25's internal
        --     fillType.massPerLiter, which is incorrect for at least sorghum (~3× too dense),
        --     causing yield and engine load to read ~3× too high for that crop.
        --     Falls back to the FS25 value only for fill types not in our table (e.g. custom mods),
        --     and finally to a generic 0.75 kg/L if neither source is available.
        -- UA: Використовуємо нашу таблицю реальних густин замість внутрішнього massPerLiter FS25,
        --     який некоректний для деяких культур (зокрема сорго — ~3× завищено), що призводить
        --     до надмірно завищеної врожайності та навантаження двигуна для цих культур.
        local density = UnitConverter and UnitConverter.getCropDensityKgL
                        and UnitConverter.getCropDensityKgL(spec.lastFillType)
        if density
           and spec.combineMemory
           and spec.combineMemory.currentCrop == "PINTOBEAN_FORAGE"
           and g_fillTypeManager
           and spec.lastFillType then
            local ft = g_fillTypeManager:getFillTypeByIndex(spec.lastFillType)
            local ftName = ft and ft.name and string.upper(ft.name) or nil
            if ftName == "CHAFF" then
                density = 0.150
            end
        end
        if density then
            massKg = liters * density
            -- EN: One-time diagnostic per fill type — confirms the density table is hit and
            --     shows what density value is used (0.721 for SORGHUM is the correct fix).
            -- UA: Одноразова діагностика на тип заповнення — підтверджує що таблиця щільності
            --     використовується і показує значення (0.721 для SORGHUM — правильне виправлення).
            if not spec._densityDiagLogged then
                spec._densityDiagLogged = {}
            end
            if not spec._densityDiagLogged[spec.lastFillType] then
                spec._densityDiagLogged[spec.lastFillType] = true
                local ftName = "?"
                if g_fillTypeManager then
                    local ft = g_fillTypeManager:getFillTypeByIndex(spec.lastFillType)
                    if ft then ftName = ft.name or "?" end
                end
                print(string.format("RHM: [DENSITY-DIAG] First use: fillType=%d (%s) density=%.4f kg/L (table hit)",
                    spec.lastFillType, ftName, density))
            end
        elseif spec.lastFillType and g_fillTypeManager then
            -- EN: Fallback: FS25 fill type density (rarely reached once table is populated).
            -- UA: Запасний варіант: густина FS25 (рідко досягається після ініціалізації таблиці).
            local fillType = g_fillTypeManager:getFillTypeByIndex(spec.lastFillType)
            if fillType and fillType.massPerLiter then
                -- EN: FS25 stores massPerLiter as: XML_kg_per_L × 0.001 (see FillTypeDesc.lua).
                --     Multiplying by 1000 recovers the actual kg/L density for the mass calculation.
                --     Example: wheat stored as 0.000772 → × 1000 = 0.772 kg/L (correct).
                -- UA: FS25 зберігає massPerLiter як: XML_кг_на_л × 0.001 (FillTypeDesc.lua).
                --     Множення на 1000 відновлює реальну густину кг/л для розрахунку маси.
                massKg = liters * fillType.massPerLiter * 1000
                -- EN: One-time fallback diagnostic — warns that this crop isn't in our table.
                if not spec._densityDiagLogged then spec._densityDiagLogged = {} end
                if not spec._densityDiagLogged[spec.lastFillType] then
                    spec._densityDiagLogged[spec.lastFillType] = true
                    print(string.format("RHM: [DENSITY-DIAG] FALLBACK: fillType=%d density=%.4f kg/L (FS25 massPerLiter=%.6f) - not in RHM density table",
                        spec.lastFillType, fillType.massPerLiter * 1000, fillType.massPerLiter))
                end
            else
                massKg = liters * 0.75
            end
        else
            massKg = liters * 0.75
        end
    end
    
    -- ── FORAGE-MASS diagnostic (post-density) ───────────────────────────────
    if spec.combineMemory and spec.combineMemory.machineType == "forage" then
        if (spec._tickDbgCount or 0) % 30 == 1 then
            local srcLabel = (spec.lastLiters or 0) > 0 and "hopper" or ((spec._fallbackLiters or 0) > 0 and "fallback" or "NONE")
            print(string.format(
                "RHM: [FORAGE-MASS #%d] liters=%.4f massKg=%.6f lastFillType=%s src=%s",
                spec._tickDbgCount or 0,
                liters, massKg,
                tostring(spec.lastFillType), srcLabel))
        end
    end
    -- ────────────────────────────────────────────────────────────────────────

    -- EN: Per-tick area — delta of the monotonic cumulative counter since last tick.
    --     Used for the isCutting guard and engine load calculations, NOT for yield display.
    -- UA: Площа за тік — різниця монотонного лічильника з минулого тіку.
    local prevArea     = spec.prevCumulativeArea or 0
    local pixelAreaDelta = (spec.totalCumulativeArea or 0) - prevArea
    spec.prevCumulativeArea = spec.totalCumulativeArea or 0

    -- EN: Area for yield calculation — pixel area is the primary source.
    --     spec.totalCumulativeArea delta (pixelAreaDelta) is the true m² of terrain cleared by the
    --     cutter each tick, independent of header geometry. This removes the 3-10× yield inflation
    --     caused by spec_cutter.workWidth returning a single-row width for row-crop corn/sorghum
    --     headers instead of the full working width.
    --     FALLBACK: geometric area (dist × _cachedCutWidth) for windrow/pickup scenarios where
    --     addCutterArea is not triggered but grain is still accumulated.
    --     spec._cachedCutWidth is still populated here for the DraggableHUD ac/hr display.
    -- UA: Площа для розрахунку врожайності — піксельна площа є основним джерелом.
    --     Delta spec.totalCumulativeArea (pixelAreaDelta) — реальна m² ґрунту за тік, незалежна
    --     від геометрії жатки. Усуває 3-10× інфляцію від spec_cutter.workWidth для кукурудзяних
    --     жаток рядкового типу (повертає ширину одного рядка замість повної ширини жатки).
    local areaForYield = 0
    if massKg > 0 or pixelAreaDelta > 0 then
        -- EN: Probe/cache cutter width for the DraggableHUD ac/hr display.
        --     Only updated once (when not yet cached) to avoid per-tick cutter iteration.
        -- UA: Зондуємо/кешуємо ширину жатки для відображення га/год у HUD.
        if not spec._cachedCutWidth or spec._cachedCutWidth <= 0 then
            local swathW = spec.combineMemory and spec.combineMemory.swathWidth
            if swathW and swathW > 0 then
                spec._cachedCutWidth = swathW
            else
                local sc = self.spec_combine
                if sc and sc.attachedCutters then
                    for c, _ in pairs(sc.attachedCutters) do
                        local cw = 0
                        if c.spec_cutter and (c.spec_cutter.workWidth or 0) > 0 then
                            cw = c.spec_cutter.workWidth
                        elseif type(c.getWorkAreaWidth) == "function" then
                            cw = c:getWorkAreaWidth(1) or 0
                        elseif c.spec_workArea and c.spec_workArea.workAreas
                               and c.spec_workArea.workAreas[1] then
                            cw = c.spec_workArea.workAreas[1].workWidth or 0
                        end
                        if cw > 0 then
                            spec._cachedCutWidth = cw
                            break
                        end
                    end
                end
            end
        end

        -- EN: PRIMARY (pickup header): distance × manual swath width.
        --     For pickup headers the game pixel-area reflects only the narrow pickup aperture
        --     (~12 ft), while the harvested mass came from a swath that may be 4× wider.
        --     Using pixel area here would inflate yield by that ratio.  When the user has set
        --     a manual swath width we always prefer the geometric calculation.
        -- UA: PRIMARY (підбирач): відстань × ручна ширина валка.
        --     Для підбирачів піксельна площа відповідає вузькій апертурі підбирача (~12 фт),
        --     тоді як зібрана маса надійшла з ширшого валка (може бути в 4 рази ширше).
        --     Використання піксельної площі тут роздуває врожайність на цей коефіцієнт.
        local swathW = spec.combineMemory and spec.combineMemory.swathWidth
        local _isPickup = isPickupHeader(self)
        if _isPickup and swathW and swathW > 0 then
            local dist = self.lastMovedDistance or 0
            areaForYield = dist * swathW
            -- EN: Diagnostic — throttled to every 120 ticks so the log stays readable.
            spec._pickupDbgCount = (spec._pickupDbgCount or 0) + 1
            if spec._pickupDbgCount % 120 == 1 then
                print(string.format(
                    "RHM: [PICKUP-AREA #%d] isPickup=true swathW=%.3fm dist=%.4fm areaForYield=%.4fm²",
                    spec._pickupDbgCount, swathW, dist, areaForYield))
            end
        elseif _isPickup and (not swathW or swathW <= 0) then
            -- EN: Pickup header detected but no manual swath width set — warn once, use cached width as best-effort.
            -- UA: Підбирач виявлено, але ширина валка не вказана — попереджаємо, використовуємо кешовану ширину.
            if not spec._pickupNoSwathWarned then
                spec._pickupNoSwathWarned = true
                print("RHM: [PICKUP-AREA] WARNING — pickup header detected but no manual swath width set. " ..
                      "Please set your swath width in the Calibration GUI for accurate yield. " ..
                      "Falling back to pixel/cached area (yield will be inflated).")
            end
            if pixelAreaDelta > 0 then
                areaForYield = pixelAreaDelta
            elseif spec._cachedCutWidth and spec._cachedCutWidth > 0 then
                local dist = self.lastMovedDistance or 0
                areaForYield = dist * spec._cachedCutWidth
            end
        elseif pixelAreaDelta > 0 then
            -- EN: PRIMARY (direct-cut): pixel area — actual m² of terrain cleared this tick.
            -- UA: PRIMARY (пряме зрізання): піксельна площа — реальні m² ґрунту за тік.
            areaForYield = pixelAreaDelta
        elseif spec._cachedCutWidth and spec._cachedCutWidth > 0 then
            -- EN: FALLBACK: geometric area when no cutter pixels detected.
            -- UA: FALLBACK: геометрична площа коли піксели жатки не виявлені.
            local dist = self.lastMovedDistance or 0
            areaForYield = dist * spec._cachedCutWidth
        end
    end
    
    -- EN: Time-of-day moisture factor is now updated at the very top of onUpdateTick
    --     (before any early-return paths), so the HUD always has fresh values.
    -- UA: Коефіцієнт вологості часу доби тепер оновлюється на початку onUpdateTick.

    -- EN: Pass accumulated MASS to LoadCalculator (not area) — mass is the main driver now.
    -- UA: Передаємо накопичену МАСУ в LoadCalculator (не площу) — маса тепер основний показник.
    spec.loadCalculator:update(self, dt, massKg)
    
    -- EN: Update productivity and yield rolling average. Called even when not cutting
    --     so the t/h display smoothly fades to 0 between passes.
    -- UA: Оновлюємо ковзне середнє продуктивності та врожайності. Викликається навіть без косіння
    --     щоб показник т/год плавно падав до 0 між проходами.
    spec.loadCalculator:updateProductivityAndYield(massKg, liters, areaForYield, dt) 
    
    -- EN: Calculate header loss based on current travel speed (server side only).
    -- UA: Розраховуємо втрати на жатці виходячи з поточної швидкості (тільки на сервері).
    local headerLoss = spec.loadCalculator:calculateHeaderLoss(self)

    -- EN: Update plug state machine — 130%+ load for 10s → plug.
    -- UA: Оновлюємо стан засмічення — навантаження 130%+ протягом 10с → засмічення.
    local plugChanged = spec.loadCalculator:updatePlugState(dt)
    if plugChanged and spec.loadCalculator.isPlugged then
        -- EN: Plug event — show warning. Speed automation will force speed to ~0.
        -- UA: Подія засмічення — показуємо попередження.
        if g_i18n then
            g_currentMission:showBlinkingWarning(g_i18n:getText("rhm_warn_rotor_plugged"), 8000)
        end
    end

    -- EN: Apply physical crop loss: remove lost grain from the fill unit on the server.
    --     This makes crop loss visible as a real reduction in tank fill level.
    -- UA: Застосовуємо фізичні втрати врожаю: видаляємо втрачене зерно з fill unit на сервері.
    --     Це робить втрати врожаю видимими як реальне зменшення рівня наповнення бункера.
    if liters > 0 and self.isServer then
        -- EN: Calculate total crop loss including settings deviation penalty.
        -- UA: Розраховуємо загальні втрати врожаю включаючи штраф за відхилення налаштувань.
        local cropLoss = spec.loadCalculator:calculateTotalCropLoss()
        local thrLoss   = spec.loadCalculator.thrLoss  or 0
        local cleanLoss = spec.loadCalculator.cleanLoss or 0
        spec.combineMemory:updateStatistics(liters, cropLoss, spec.combineMemory.currentCrop)

        if RHM_Debug and RHM_Debug.isEnabled("LoadCalculator") then
            print(string.format("RHM [Combine tick] cropLoss=%.2f thr=%.2f clean=%.2f hdr=%.2f liters=%.1f",
                cropLoss, thrLoss, cleanLoss, headerLoss, liters))
        end

        -- EN: Update session statistics — new signature includes liters and split losses.
        -- UA: Оновлюємо статистику сесії — новий підпис включає літри та розділені втрати.
        spec.loadCalculator:updateSession(massKg, areaForYield, liters, thrLoss, cleanLoss, headerLoss)
        
        if cropLoss > 0 and g_realisticHarvestManager and g_realisticHarvestManager.settings then
            if g_realisticHarvestManager.settings.enableCropLoss then
                local lossRatio = cropLoss / 100
                local lostLiters = liters * lossRatio
                
                local fillUnitIndex = 1
                local spec_fillUnit = self.spec_fillUnit
                if spec_fillUnit and spec_fillUnit.fillUnits and spec_fillUnit.fillUnits[fillUnitIndex] then
                    self:addFillUnitFillLevel(
                        self:getOwnerFarmId(),
                        fillUnitIndex,
                        -lostLiters,
                        spec.lastFillType,
                        ToolType.UNDEFINED,
                        nil
                    )
                    
                    if rhm_Combine.debug or cropLoss > 10 then
                        print(string.format("RHM: [LOSS] Crop Loss Applied: %.1f L lost (%.1f%% of %.1f L harvest)",
                            lostLiters, cropLoss, liters))
                    end
                else
                    print("RHM: Warning - Could not find fill unit for crop loss removal")
                end
            end
        end
    end
    -- ========================================================================
    
    -- EN: Reset all per-tick accumulators after processing.
    -- UA: Скидаємо всі накопичувачі за тік після обробки.
    spec.lastArea = 0
    spec.lastLiters = 0
    spec._fallbackLiters = 0
    
    -- EN: Read field moisture from external 'Moisture System' mod (if installed and enabled).
    --     Field position is the primary source — this reflects the moisture of the standing
    --     crop being cut, which is what affects threshing difficulty and grain losses.
    --     Grain-tank moisture (getObjectMoisture) is intentionally omitted here because the
    --     MoistureSystem mod already displays it in the fillUnit UI, and it represents the
    --     average of already-harvested grain, not the live field condition.
    -- UA: Зчитуємо вологість поля з зовнішнього моду (якщо встановлений і увімкнений).
    --     Позиція поля — основне джерело: відображає вологість стоячої культури, яку ріжемо.
    local grainMoisture = 0
    if MoistureAdapter and MoistureAdapter.isActive
       and g_realisticHarvestManager and g_realisticHarvestManager.settings
       and g_realisticHarvestManager.settings.enableMoisture
       and cutterIsTurnedOn then
        local mx, _, mz = getWorldTranslation(self.components[1].node)
        grainMoisture = MoistureAdapter.getMoistureAtPosition(mx, mz)
        -- EN: Fallback: object-level moisture if position query returns nothing.
        -- UA: Запасний варіант: вологість об'єкта якщо позиційний запит нічого не повернув.
        if grainMoisture == 0 then
            local fillType = spec_combine.lastValidInputFruitType or FillType.UNKNOWN
            if fillType ~= FillType.UNKNOWN then
                grainMoisture = MoistureAdapter.getObjectMoisture(self.components[1].node, fillType)
            end
        end
    end

    -- EN: Cache per-effect moisture factors on the LoadCalculator so calculateEngineLoad(),
    --     calculateTotalCropLoss(), and calculateSpeedLimit() can use them without re-querying
    --     the moisture API every tick. Factors update every tick alongside the moisture read.
    --     One-tick lag on factor changes is imperceptible at normal game speeds.
    -- UA: Кешуємо коефіцієнти вологості на LoadCalculator для використання в розрахунках.
    local lc = spec.loadCalculator
    if lc then
        lc.grainMoisture = grainMoisture
        if MoistureCalculator and grainMoisture > 0 then
            local cropName = spec.combineMemory and spec.combineMemory.currentCrop
            lc.moistureLoadFactor  = MoistureCalculator.enableLoad  and MoistureCalculator.getLoadFactor(cropName, grainMoisture)  or 1.0
            lc.moistureLossFactor  = MoistureCalculator.enableLoss  and MoistureCalculator.getLossFactor(cropName, grainMoisture)  or 1.0
            lc.moistureSpeedFactor = MoistureCalculator.enableSpeed and MoistureCalculator.getSpeedFactor(cropName, grainMoisture) or 1.0
        else
            lc.moistureLoadFactor  = 1.0
            lc.moistureLossFactor  = 1.0
            lc.moistureSpeedFactor = 1.0
        end
    end

    -- EN: Update HUD live data table from LoadCalculator outputs.
    -- UA: Оновлюємо таблицю живих даних HUD з виводів LoadCalculator.
    if spec.data then
        local lc = spec.loadCalculator
        spec.data.load             = lc:getEngineLoad()
        spec.data.cropLoss         = lc:calculateTotalCropLoss()  -- EN: total, for backward compat
        spec.data.thrLoss          = lc.thrLoss   or 0
        spec.data.cleanLoss        = lc.cleanLoss or 0
        spec.data.headerLoss       = lc.headerLoss or 0
        spec.data.tonPerHour       = lc:getTonPerHour()
        spec.data.litersPerHour    = lc:getLitersPerHour()
        spec.data.yield            = lc.currentYield or 0
        spec.data.isPlugged        = lc.isPlugged or false
        spec.data.moistureLabel    = lc.moistureLabel or ""
        -- EN: Grain moisture display — always a percentage, regardless of external mod or upgrade tier.
        --     Real-life combines always have a moisture meter, so ours does too. Priority:
        --       1. External Moisture System mod (if active AND returned >0 for live field/object)
        --       2. LoadCalculator.moisturePercent (time-of-day derived: Optimal~13%, Night Dew~24%)
        -- UA: Відображення вологості зерна — завжди у відсотках, незалежно від модів і апгрейдів.
        --     Реальні комбайни завжди мають вологомір, отже і наш має. Пріоритет:
        --       1. Зовнішній мод Moisture System (якщо активний і повернув >0)
        --       2. LoadCalculator.moisturePercent (похідне від часу доби)
        if grainMoisture and grainMoisture > 0 then
            spec.data.grainMoisture = grainMoisture
            spec.data.moistureSource = "external"  -- EN: Provenance tag for debugging / UA: Джерело для діагностики
        else
            spec.data.grainMoisture = lc.moisturePercent or 13.0
            spec.data.moistureSource = "time-of-day"
        end
        -- EN: plugTimerPct: 0-100% progress toward a plug, for HUD pre-warning ramp.
        -- UA: plugTimerPct: 0-100% прогрес до засмічення для попереднього попередження HUD.
        spec.data.plugTimerPct     = math.min(100, ((lc.plugTimer or 0) / 10000) * 100)
        -- EN: Speed limit display — only show when actively limiting (speedLimit has headroom below ceiling).
        --     When the combine is under-loaded the speed climbs toward genuineSpeedLimit; showing that
        --     climbing number is misleading ("/ 8.0 mph" growing while you drive at 5 mph). We hide it
        --     once speedLimit reaches 95% of the ceiling — at that point we're not usefully limiting.
        --     Always show when plugged (forces 0) or when genuinely throttling below ceiling.
        -- UA: Показуємо ліміт швидкості тільки коли він реально обмежує (нижче за стелю).
        if lc.isPlugged then
            spec.data.recommendedSpeed = 0
        else
            local calcLimit  = lc:getSpeedLimit()
            local ceiling    = lc.genuineSpeedLimit
            -- Show limit only when it's meaningfully below the ceiling (actively limiting)
            if ceiling > 0 and calcLimit < ceiling * 0.95 then
                spec.data.recommendedSpeed = calcLimit
            else
                spec.data.recommendedSpeed = 0
            end
        end
    end
    
    -- === AI / COURSEPLAY WORKAROUND (Server Side) ===
    -- Courseplay uses its own speed controller that bypasses getSpeedLimit().
    -- We must enforce the requested speed limit directly on the motor.
    -- FIX: Only apply if the cutter is actually working (cutterIsTurnedOn from above)
    if self.isServer and self:getIsAIActive() and cutterIsTurnedOn then
        if self.spec_motorized and self.spec_motorized.motor then
            local motor = self.spec_motorized.motor
            local currentLimit = spec.loadCalculator:getSpeedLimit()
            
            -- EN: ALWAYS apply the calculated limit (both up and down).
            --     Previously we only called setSpeedLimit when lowering, so after a heavy windrow
            --     the motor limit stayed at 1-2 km/h permanently (Courseplay speed-lock bug).
            --     Cap at genuineSpeedLimit so we never restore above the original ceiling.
            -- UA: ЗАВЖДИ застосовуємо розрахований ліміт (і вниз, і вгору).
            --     Раніше ми викликали setSpeedLimit лише при зниженні, тому після важких рядків
            --     ліміт мотора назавжди залишався на 1-2 км/год (баг блокування швидкості Courseplay).
            --     Обмежуємо genuineSpeedLimit щоб не перевищити оригінальну стелю.
            local ceiling = spec.loadCalculator.genuineSpeedLimit
            if ceiling and ceiling > 0 then
                currentLimit = math.min(currentLimit, ceiling)
            end
            motor:setSpeedLimit(currentLimit)
        end
    end
    
    -- EN: OVERLOAD WARNING: Server determines level (0=normal, 1=HIGH 120%+, 2=CRITICAL 150%+).
    --     Displayed to whoever controls the combine — in SP that's the server; in DS it flows via streams.
    -- UA: ПОПЕРЕДЖЕННЯ ПЕРЕВАНТАЖЕННЯ: Сервер визначає рівень (0=норма, 1=ВИСОК. 120%+, 2=КРИТИЧ. 150%+).
    --     Відображається тому хто керує комбайном — у SP це сервер; у DS приходить через потоки.
    if self.isServer and spec.data then
        local load = spec.data.load
        if load >= 150 then
            spec.data.overloadLevel = 2
        elseif load >= 120 then
            spec.data.overloadLevel = 1
        else
            spec.data.overloadLevel = 0
        end
    end
    
    -- WARNING DISPLAY: показуємо завжди в того хто керує комбайном
    -- в SP: isServer=true і getIsControlled()=true — працює
    -- в DS client: isServer=false і overloadLevel приходить через stream — працює
    -- FIX: деякі DLC/мод-транспорти (напр. NH 8040) можуть не мати getIsControlled
    local isControlled = type(self.getIsControlled) == "function" and self:getIsControlled()
    if spec.data and isControlled then
        local level = spec.data.overloadLevel or 0
        local now = g_currentMission.time
        spec._lastOverloadWarn = spec._lastOverloadWarn or 0
        
        local warnInterval = nil
        local warnText = nil
        
        if level == 2 then
            warnInterval = 5000
            warnText = g_i18n:getText("rhm_warn_overload_critical")
        elseif level == 1 then
            warnInterval = 8000
            warnText = g_i18n:getText("rhm_warn_overload_high")
        else
            spec._lastOverloadWarn = 0
        end
        
        if warnText and (now - spec._lastOverloadWarn) >= warnInterval then
            spec._lastOverloadWarn = now
            if g_realisticHarvestManager.settings.showLoadWarnings then
                g_currentMission:showBlinkingWarning(warnText, 3000)
            end
        end
    end
    -- === END OVERLOAD WARNING ===
    
    -- EN: MULTIPLAYER: Throttled dirty flag raising — only sync when data has changed significantly
    --     or at least once per second. Sensitivity thresholds reduce network traffic.
    -- UA: МУЛЬТИПЛЕЕР: Тротлінговий підйом dirty flag — синхронізуємо лише коли дані суттєво змінились
    --     або принаймні раз на секунду. Пороги чутливості зменшують мережевий трафік.
    if self.isServer then
        local now = g_currentMission.time
        local interval = spec.dataUpdateInterval or 200
        
        -- Перевіряємо чи пройшло достатньо часу
        if (now - spec.lastDataUpdateTime) >= interval then
            local data = spec.data
            local last = spec.lastSyncedData
            
            -- Перевіряємо чи є "суттєві" зміни
            local hasSignificantChange = false
            if last.load == nil then
                hasSignificantChange = true
            else
                -- Пороги чутливості для зменшення трафіку
                if math.abs((data.load or 0) - (last.load or 0)) > 2.0 then hasSignificantChange = true
                elseif math.abs((data.cropLoss  or 0) - (last.cropLoss  or 0)) > 0.5 then hasSignificantChange = true
                elseif math.abs((data.cleanLoss or 0) - (last.cleanLoss or 0)) > 0.3 then hasSignificantChange = true
                elseif math.abs((data.recommendedSpeed or 0) - (last.recommendedSpeed or 0)) > 0.2 then hasSignificantChange = true
                elseif math.abs((data.yield or 0) - (last.yield or 0)) > 0.1 then hasSignificantChange = true
                elseif data.overloadLevel ~= last.overloadLevel then hasSignificantChange = true
                elseif (data.isPlugged ~= last.isPlugged) then hasSignificantChange = true
                elseif math.abs((data.headerLoss or 0) - (last.headerLoss or 0)) > 0.3 then hasSignificantChange = true
                end
            end
            
            -- Також форсуємо оновлення раз на секунду
            if hasSignificantChange or (now - spec.lastDataUpdateTime) >= 1000 then
                spec.lastDataUpdateTime = now
                spec.lastSyncedData.load            = data.load
                spec.lastSyncedData.cropLoss        = data.cropLoss
                spec.lastSyncedData.thrLoss         = data.thrLoss
                spec.lastSyncedData.cleanLoss       = data.cleanLoss
                spec.lastSyncedData.headerLoss      = data.headerLoss
                spec.lastSyncedData.recommendedSpeed= data.recommendedSpeed
                spec.lastSyncedData.yield           = data.yield
                spec.lastSyncedData.overloadLevel   = data.overloadLevel
                spec.lastSyncedData.isPlugged       = data.isPlugged
                
                self:raiseDirtyFlags(spec.dataDirtyFlag)
            end
        end
    end
end

-- EN: Called every frame when the player is in the combine.
--     HUD is drawn centrally in RealisticHarvestManager:draw() via hierarchy scanning,
--     so we don't draw here to avoid duplication.
-- UA: Викликається кожен кадр коли гравець в комбайні.
--     HUD малюється централізовано в RealisticHarvestManager:draw() через сканування ієрархії,
--     тому тут не малюємо — щоб уникнути дублювання.
function rhm_Combine:onDraw(isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
end

-- ============================================================================
-- SAVEGAME FUNCTIONS  
-- ============================================================================

-- EN: Saves combine settings (mode, currentCrop, fan/rotor/sieve/feeder values) to the savegame XML file.
--     Uses pcall for each setValue so schema validation errors don't crash the save.
-- UA: Зберігає налаштування комбайна (режим, поточна культура, значення вентилятора/ротора/решета/подачі) у XML файл збереження.
--     Використовує pcall для кожного setValue щоб помилки валідації схеми не падали при збереженні.
function rhm_Combine:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self.spec_rhm_Combine
    -- EN: DIAG — print even if we bail early so we can confirm the function fires.
    print(string.format("RHM: [SAVE-DIAG] saveToXMLFile called for %s | key=%s | hasSpec=%s | hasMem=%s",
        self:getName() or "?",
        tostring(key),
        tostring(spec ~= nil),
        tostring(spec and spec.combineMemory ~= nil)))
    if not spec or not spec.combineMemory then return end

    local cur = key .. ".combineMemory.current"
    local mem = spec.combineMemory
    local settings = mem.currentSettings

    -- EN: DIAG — dump state snapshot so we can see exactly what's being written.
    print(string.format("RHM: [SAVE-DIAG]   cur path = %s", cur))
    print(string.format("RHM: [SAVE-DIAG]   currentCrop=%s | mode=%s | fan=%s | rotor=%s | upper=%s | lower=%s | target=%s",
        tostring(mem.currentCrop),
        tostring(mem.mode),
        tostring(settings.fan),
        tostring(settings.rotor),
        tostring(settings.upperSieve),
        tostring(settings.lowerSieve),
        tostring(settings.targetEngineLoad)))

    -- EN: Use pcall for each setValue to prevent schema validation crashes.
    --     DIAG: now prints both success and failure so we know if schema rejects anything.
    -- UA: pcall для кожного setValue щоб помилки схеми не падали. DIAG: виводимо успіх і помилку.
    local function safeSet(path, value)
        local ok, err = pcall(function() xmlFile:setValue(path, value) end)
        if not ok then
            print("RHM: [SAVE] FAILED set " .. tostring(path) .. " = " .. tostring(value) .. " | err: " .. tostring(err))
        else
            print("RHM: [SAVE-DIAG]   OK  " .. tostring(path) .. " = " .. tostring(value))
        end
    end

    safeSet(cur .. "#mode",         mem.mode or "AUTO")
    safeSet(cur .. "#autoSwitch",   mem.autoSwitchEnabled ~= false)
    safeSet(cur .. "#currentCrop",  mem.currentCrop or "")
    safeSet(cur .. "#fan",          settings.fan or 50)
    safeSet(cur .. "#upperSieve",   settings.upperSieve or 50)
    safeSet(cur .. "#lowerSieve",   settings.lowerSieve or 50)
    safeSet(cur .. "#rotor",        settings.rotor or 50)
    safeSet(cur .. "#upgradeLevel",     mem.upgradeLevel or 0)
    safeSet(cur .. "#targetEngineLoad", settings.targetEngineLoad or 95)
    -- EN: Save concave (grain) or feeder (forage/root/cotton) under their respective keys.
    --     Both keys registered in schema; unused one gets 50 (default).
    if spec.machineType == "grain" then
        safeSet(cur .. "#concave", settings.concave or 50)
    else
        safeSet(cur .. "#feeder",  settings.feeder or 50)
    end

    print(string.format("RHM: [SAVE] saveToXMLFile complete for %s (crop=%s)",
        self:getName() or "?", tostring(mem.currentCrop)))
end

-- EN: Called by FS25 after a vehicle has finished loading from a savegame.
--     `savegame` is nil for vehicles that are new (not loaded from save) — guard required.
--     The XML key for our data mirrors what saveToXMLFile writes:
--       savegame.key = "vehicles.vehicle(N)"  →  append "." .. modName .. ".rhm_Combine"
--     NOTE: loadFromXMLFile is a Vehicle-level method, not a spec event — it is never raised.
--           This onPostLoad is the correct hook for specialization-level XML loading.
-- UA: Викликається FS25 після завершення завантаження транспорту зі збереження.
--     `savegame` є nil для нових (не завантажених) транспортних засобів — потрібна перевірка.
function rhm_Combine:onPostLoad(savegame)
    local spec = self.spec_rhm_Combine
    -- EN: DIAG — print even if we bail early so we can confirm the function fires.
    print(string.format("RHM: [LOAD-DIAG] onPostLoad called for %s | savegame=%s | hasSpec=%s | hasMem=%s",
        self:getName() or "?",
        tostring(savegame ~= nil),
        tostring(spec ~= nil),
        tostring(spec and spec.combineMemory ~= nil)))
    if not spec or not spec.combineMemory then return end
    if not savegame then
        print("RHM: [LOAD-DIAG]   savegame is nil — new vehicle, skipping XML load")
        return
    end

    -- EN: DIAG — show exactly what key FS25 gave us and the full path we'll read from.
    local cur = savegame.key .. "." .. RHM_MOD_NAME .. ".rhm_Combine.combineMemory.current"
    print(string.format("RHM: [LOAD-DIAG]   savegame.key = %s", tostring(savegame.key)))
    print(string.format("RHM: [LOAD-DIAG]   RHM_MOD_NAME = %s", tostring(RHM_MOD_NAME)))
    print(string.format("RHM: [LOAD-DIAG]   full cur path = %s", cur))

    local xmlFile = savegame.xmlFile

    -- EN: Check if the node exists before reading. hasProperty() does NOT validate schema,
    --     so it safely returns false when our data simply hasn't been saved yet (first load
    --     after installing the mod, or when schema registration failed on a previous session).
    --     If the node is absent, we keep the CombineMemory.new() defaults (all 50s) and exit
    --     cleanly — no "path not registered" spam, no nil settings, no line-1637 crash.
    -- UA: Перевіряємо наявність вузла перед читанням. hasProperty() не валідує схему,
    --     тому безпечно повертає false коли наші дані ще не були збережені.
    local nodeExists = xmlFile:hasProperty(cur .. "#mode")
    print(string.format("RHM: [LOAD-DIAG]   node exists (has #mode)? %s", tostring(nodeExists)))

    if not nodeExists then
        -- EN: No saved data for this combine — keep CombineMemory defaults (all 50s, AUTO mode).
        --     This is expected on the first load after installing RHM, or when saving failed.
        -- UA: Немає збережених даних — залишаємо дефолти CombineMemory (все 50, режим AUTO).
        print(string.format("RHM: [LOAD-DIAG]   No RHM data in savegame — keeping defaults for %s", self:getName() or "?"))
        -- EN: Still blend with store-purchased upgrade tier if present.
        -- UA: Все одно враховуємо рівень апгрейду зі стору якщо є.
        if RHMShopIntegration then
            local storeLevel = RHMShopIntegration.getUpgradeLevelFromConfig(self)
            if storeLevel and storeLevel > 0 then
                spec.combineMemory.upgradeLevel = math.max(spec.combineMemory.upgradeLevel or 0, storeLevel)
            end
        end
        return
    end

    spec.combineMemory.mode              = xmlFile:getValue(cur .. "#mode",       "AUTO") or "AUTO"
    spec.combineMemory.autoSwitchEnabled = xmlFile:getValue(cur .. "#autoSwitch", true)
    local savedCrop = xmlFile:getValue(cur .. "#currentCrop", "") or ""
    spec.combineMemory.currentCrop = (savedCrop ~= "" and savedCrop) or nil

    spec.combineMemory.currentSettings.fan             = xmlFile:getValue(cur .. "#fan",             50) or 50
    spec.combineMemory.currentSettings.upperSieve      = xmlFile:getValue(cur .. "#upperSieve",      50) or 50
    spec.combineMemory.currentSettings.lowerSieve      = xmlFile:getValue(cur .. "#lowerSieve",      50) or 50
    spec.combineMemory.currentSettings.rotor           = xmlFile:getValue(cur .. "#rotor",           50) or 50
    spec.combineMemory.currentSettings.targetEngineLoad = xmlFile:getValue(cur .. "#targetEngineLoad", 95) or 95
    spec.combineMemory.upgradeLevel                    = xmlFile:getValue(cur .. "#upgradeLevel",    0)  or 0

    -- EN: Blend with store purchase — take the MAX so both purchase paths are honoured.
    -- UA: Поєднуємо з покупкою в магазині — беремо MAX щоб обидва шляхи враховувались.
    if RHMShopIntegration then
        local storeLevel = RHMShopIntegration.getUpgradeLevelFromConfig(self)
        if storeLevel then
            -- EN: nil guard: upgradeLevel is now guaranteed non-nil via "or 0" above,
            --     but the guard is defensive against any future code path that forgets.
            -- UA: Захист від nil: upgradeLevel вже гарантовано не nil, але для надійності.
            spec.combineMemory.upgradeLevel = math.max(spec.combineMemory.upgradeLevel or 0, storeLevel)
        end
    end

    -- EN: Load the correct 5th parameter key based on machine type.
    --     Grain combines use 'concave'; fall back to '#feeder' for old saves.
    --     Forage/root/cotton use 'feeder'.
    if spec.machineType == "grain" then
        local concaveVal     = xmlFile:getValue(cur .. "#concave", nil)
        local feederFallback = xmlFile:getValue(cur .. "#feeder",  50) or 50
        spec.combineMemory.currentSettings.concave = concaveVal or feederFallback
    else
        spec.combineMemory.currentSettings.feeder = xmlFile:getValue(cur .. "#feeder", 50) or 50
    end

    -- EN: DIAG — dump everything we read back so we can compare to what was saved.
    local s = spec.combineMemory.currentSettings
    print(string.format("RHM: [LOAD-DIAG]   READ BACK: rawCrop='%s' → currentCrop=%s | mode=%s | fan=%s rotor=%s upper=%s lower=%s target=%s",
        tostring(savedCrop),
        tostring(spec.combineMemory.currentCrop),
        tostring(spec.combineMemory.mode),
        tostring(s.fan), tostring(s.rotor),
        tostring(s.upperSieve), tostring(s.lowerSieve),
        tostring(s.targetEngineLoad)))
    print(string.format("RHM: [LOAD] onPostLoad complete for %s (crop=%s mode=%s)",
        self:getName() or "?",
        tostring(spec.combineMemory.currentCrop),
        tostring(spec.combineMemory.mode)))
end

-- ============================================================================
-- MULTIPLAYER SYNCHRONIZATION
-- ============================================================================

---Початкова синхронізація: Сервер пише дані коли клієнт підключається
function rhm_Combine:onWriteStream(streamId, connection)
    local spec = self.spec_rhm_Combine
    if not spec or not spec.data then
        -- Пишемо нулі якщо немає даних
        streamWriteFloat32(streamId, 0)
        streamWriteFloat32(streamId, 0)
        streamWriteFloat32(streamId, 0)
        streamWriteFloat32(streamId, 0)
        streamWriteFloat32(streamId, 0)
        streamWriteFloat32(streamId, 0) -- yield
        streamWriteUInt8(streamId, 0)   -- overloadLevel
        -- CombineMemory: write defaults
        streamWriteUInt8(streamId, 50)  -- fan
        streamWriteUInt8(streamId, 50)  -- rotor
        streamWriteUInt8(streamId, 50)  -- upperSieve
        streamWriteUInt8(streamId, 50)  -- lowerSieve
        streamWriteUInt8(streamId, 50)  -- slot5 (concave/feeder)
        streamWriteString(streamId, "AUTO")  -- mode
        streamWriteString(streamId, "")      -- currentCrop (empty = nil)
        streamWriteUInt8(streamId, 0)        -- upgradeLevel
        streamWriteUInt8(streamId, 95)       -- targetEngineLoad default
        return
    end
    
    -- HUD data
    streamWriteFloat32(streamId, spec.data.load or 0)
    streamWriteFloat32(streamId, spec.data.cropLoss or 0)
    streamWriteFloat32(streamId, spec.data.tonPerHour or 0)
    streamWriteFloat32(streamId, spec.data.litersPerHour or 0)
    streamWriteFloat32(streamId, spec.data.recommendedSpeed or 0)
    streamWriteFloat32(streamId, spec.data.yield or 0)
    streamWriteUInt8(streamId, spec.data.overloadLevel or 0)
    
    -- CombineMemory settings (sync on initial connect)
    local mem = spec.combineMemory
    if mem then
        streamWriteUInt8(streamId, mem.currentSettings.fan or 50)
        streamWriteUInt8(streamId, mem.currentSettings.rotor or 50)
        streamWriteUInt8(streamId, mem.currentSettings.upperSieve or 50)
        streamWriteUInt8(streamId, mem.currentSettings.lowerSieve or 50)
        -- EN: slot5 = concave (grain) or feeder (forage/root/cotton)
        streamWriteUInt8(streamId, mem.currentSettings.concave or mem.currentSettings.feeder or 50)
        streamWriteString(streamId, mem.mode or "AUTO")
        streamWriteString(streamId, mem.currentCrop or "")
        streamWriteUInt8(streamId, mem.upgradeLevel or 0)
        streamWriteUInt8(streamId, math.floor(mem.currentSettings.targetEngineLoad or 95))  -- targetEngineLoad
    else
        streamWriteUInt8(streamId, 50)
        streamWriteUInt8(streamId, 50)
        streamWriteUInt8(streamId, 50)
        streamWriteUInt8(streamId, 50)
        streamWriteUInt8(streamId, 50)  -- slot5
        streamWriteString(streamId, "AUTO")
        streamWriteString(streamId, "")
        streamWriteUInt8(streamId, 0)   -- upgradeLevel
        streamWriteUInt8(streamId, 95)  -- targetEngineLoad default
    end
end

---Початкова синхронізація: Клієнт читає дані при підключенні
function rhm_Combine:onReadStream(streamId, connection)
    local spec = self.spec_rhm_Combine
    if not spec then
        -- Пропускаємо дані якщо немає spec
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId)
        streamReadFloat32(streamId) -- yield
        streamReadUInt8(streamId)   -- overloadLevel
        -- CombineMemory defaults (skip)
        streamReadUInt8(streamId)
        streamReadUInt8(streamId)
        streamReadUInt8(streamId)
        streamReadUInt8(streamId)
        streamReadUInt8(streamId)  -- slot5
        streamReadString(streamId)
        streamReadString(streamId)
        streamReadUInt8(streamId)  -- upgradeLevel
        streamReadUInt8(streamId)  -- targetEngineLoad (skip)
        return
    end
    
    if not spec.data then
        spec.data = {}
    end
    
    -- HUD data
    spec.data.load = streamReadFloat32(streamId)
    spec.data.cropLoss = streamReadFloat32(streamId)
    spec.data.tonPerHour = streamReadFloat32(streamId)
    spec.data.litersPerHour = streamReadFloat32(streamId)
    spec.data.recommendedSpeed = streamReadFloat32(streamId)
    spec.data.yield = streamReadFloat32(streamId)
    spec.data.overloadLevel = streamReadUInt8(streamId)
    
    -- CombineMemory settings
    local fan = streamReadUInt8(streamId)
    local rotor = streamReadUInt8(streamId)
    local upperSieve = streamReadUInt8(streamId)
    local lowerSieve = streamReadUInt8(streamId)
    local slot5 = streamReadUInt8(streamId)   -- concave (grain) or feeder (forage/root/cotton)
    local mode = streamReadString(streamId)
    local currentCrop = streamReadString(streamId)
    local upgradeLevel = streamReadUInt8(streamId)
    local targetEngineLoad = streamReadUInt8(streamId)

    -- Apply to combineMemory if available
    if spec.combineMemory then
        spec.combineMemory.currentSettings.fan = fan
        spec.combineMemory.currentSettings.rotor = rotor
        spec.combineMemory.currentSettings.upperSieve = upperSieve
        spec.combineMemory.currentSettings.lowerSieve = lowerSieve
        -- EN: Apply slot5 to the key that exists in this machine's settings table.
        if spec.combineMemory.currentSettings.concave ~= nil then
            spec.combineMemory.currentSettings.concave = slot5
        elseif spec.combineMemory.currentSettings.feeder ~= nil then
            spec.combineMemory.currentSettings.feeder = slot5
        end
        spec.combineMemory.mode = mode or "AUTO"
        spec.combineMemory.currentCrop = (currentCrop ~= "" and currentCrop) or nil
        spec.combineMemory.upgradeLevel = upgradeLevel or 0
        -- EN: Sync the operator's target engine load to joining clients.
        --     Without this, clients always see the default 95% regardless of what the operator set.
        spec.combineMemory.currentSettings.targetEngineLoad = targetEngineLoad or 95
    end
end

---Постійна синхронізація: Клієнт читає оновлення від сервера
function rhm_Combine:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then  -- Клієнт читає від сервера
        local spec = self.spec_rhm_Combine
        if not spec then 
            return 
        end
        
        -- Читаємо прапорці оновлення
        local hasDataUpdate = streamReadBool(streamId)
        local hasSettingsUpdate = streamReadBool(streamId)
        
        if hasDataUpdate then
            if not spec.data then
                spec.data = {}
            end
            
            -- HUD data
            spec.data.load             = streamReadFloat32(streamId)
            spec.data.cropLoss         = streamReadFloat32(streamId)
            spec.data.thrLoss          = streamReadFloat32(streamId)
            spec.data.cleanLoss        = streamReadFloat32(streamId)
            spec.data.headerLoss       = streamReadFloat32(streamId)
            spec.data.tonPerHour       = streamReadFloat32(streamId)
            spec.data.litersPerHour    = streamReadFloat32(streamId)
            spec.data.recommendedSpeed = streamReadFloat32(streamId)
            spec.data.yield            = streamReadFloat32(streamId)
            spec.data.overloadLevel    = streamReadUInt8(streamId)
            spec.data.isPlugged        = streamReadBool(streamId)
            spec.data.plugTimerPct     = streamReadUInt8(streamId)
        end

        if hasSettingsUpdate then
            -- CombineMemory settings
            local fan = streamReadUInt8(streamId)
            local rotor = streamReadUInt8(streamId)
            local upperSieve = streamReadUInt8(streamId)
            local lowerSieve = streamReadUInt8(streamId)
            local slot5 = streamReadUInt8(streamId)  -- concave or feeder
            local mode = streamReadString(streamId)
            local currentCrop = streamReadString(streamId)
            local upgradeLevel = streamReadUInt8(streamId)

            if spec.combineMemory then
                spec.combineMemory.currentSettings.fan = fan
                spec.combineMemory.currentSettings.rotor = rotor
                spec.combineMemory.currentSettings.upperSieve = upperSieve
                spec.combineMemory.currentSettings.lowerSieve = lowerSieve
                if spec.combineMemory.currentSettings.concave ~= nil then
                    spec.combineMemory.currentSettings.concave = slot5
                elseif spec.combineMemory.currentSettings.feeder ~= nil then
                    spec.combineMemory.currentSettings.feeder = slot5
                end
                spec.combineMemory.mode = mode or "AUTO"
                spec.combineMemory.currentCrop = (currentCrop ~= "" and currentCrop) or nil
                spec.combineMemory.upgradeLevel = upgradeLevel or 0
            end
        end
    end
end

---Постійна синхронізація: Сервер пише оновлення до клієнта
function rhm_Combine:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then  -- Сервер пише до клієнта
        local spec = self.spec_rhm_Combine
        if not spec then
            streamWriteBool(streamId, false)
            return
        end
        
        -- Перевіряємо чи є зміни
        local hasDataUpdate = bitAND(dirtyMask, spec.dataDirtyFlag) ~= 0
        local hasSettingsUpdate = bitAND(dirtyMask, spec.settingsDirtyFlag) ~= 0
        
        streamWriteBool(streamId, hasDataUpdate)
        streamWriteBool(streamId, hasSettingsUpdate)
        
        if hasDataUpdate then
            -- HUD data
            local data = spec.data or {}
            streamWriteFloat32(streamId, data.load             or 0)
            streamWriteFloat32(streamId, data.cropLoss         or 0)
            streamWriteFloat32(streamId, data.thrLoss          or 0)
            streamWriteFloat32(streamId, data.cleanLoss        or 0)
            streamWriteFloat32(streamId, data.headerLoss       or 0)
            streamWriteFloat32(streamId, data.tonPerHour       or 0)
            streamWriteFloat32(streamId, data.litersPerHour    or 0)
            streamWriteFloat32(streamId, data.recommendedSpeed or 0)
            streamWriteFloat32(streamId, data.yield            or 0)
            streamWriteUInt8(streamId,   data.overloadLevel    or 0)
            streamWriteBool(streamId,    data.isPlugged        or false)
            streamWriteUInt8(streamId,   math.floor(math.min(100, data.plugTimerPct or 0)))
        end

        if hasSettingsUpdate then
            -- CombineMemory settings
            local mem = spec.combineMemory
            if mem then
                streamWriteUInt8(streamId, mem.currentSettings.fan or 50)
                streamWriteUInt8(streamId, mem.currentSettings.rotor or 50)
                streamWriteUInt8(streamId, mem.currentSettings.upperSieve or 50)
                streamWriteUInt8(streamId, mem.currentSettings.lowerSieve or 50)
                -- EN: slot5 = concave (grain) or feeder (forage/root/cotton)
                streamWriteUInt8(streamId, mem.currentSettings.concave or mem.currentSettings.feeder or 50)
                streamWriteString(streamId, mem.mode or "AUTO")
                streamWriteString(streamId, mem.currentCrop or "")
                streamWriteUInt8(streamId, mem.upgradeLevel or 0)
            else
                streamWriteUInt8(streamId, 50)
                streamWriteUInt8(streamId, 50)
                streamWriteUInt8(streamId, 50)
                streamWriteUInt8(streamId, 50)
                streamWriteUInt8(streamId, 50)  -- slot5
                streamWriteString(streamId, "AUTO")
                streamWriteString(streamId, "")
                streamWriteUInt8(streamId, 0)   -- upgradeLevel
            end
        end
    end
end

-- ============================================================================
-- INPUT MANAGEMENT
-- ============================================================================

-- Реєстрація UserActionEvents при вході в техніку
function rhm_Combine:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self.spec_rhm_Combine
        self:clearActionEventsTable(spec.actionEvents)
        
        if isActiveForInputIgnoreSelection then
            -- Реєструємо дію Перемикання Курсора (RMB за замовчуванням)
            local _, eventId = self:addActionEvent(spec.actionEvents, InputAction.RHM_TOGGLE_CURSOR, self, rhm_Combine.actionToggleCursor, false, true, false, true, nil)
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
            
            -- Реєструємо дію Відкриття Меню (RShift+K)
            if InputAction.RHM_OPEN_MENU then
                local _, menuEventId = self:addActionEvent(spec.actionEvents, InputAction.RHM_OPEN_MENU, self, rhm_Combine.actionOpenMenu, false, true, false, true, nil)
                g_inputBinding:setActionEventTextPriority(menuEventId, GS_PRIO_HIGH)
            end
        end
    end
end

-- Callback для дії
function rhm_Combine:actionToggleCursor(actionName, inputValue, callbackState, isAnalog)
    if g_realisticHarvestManager then
        g_realisticHarvestManager:toggleCursor()
    end
end

function rhm_Combine:actionOpenMenu(actionName, inputValue, callbackState, isAnalog)
    if g_realisticHarvestManager then
        g_realisticHarvestManager:toggleMenu(self)
    end
end




