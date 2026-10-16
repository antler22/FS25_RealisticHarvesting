-- EN: Training Bridge — attaches Training mode and the Corner Post HUD to upstream's classes
--     from the OUTSIDE, so none of upstream's Lua files carry fork edits. Every hook below is a
--     wrapper installed on a class table after upstream has defined it; when upstream changes
--     one of those methods, the wrapper keeps working as long as the method name survives, and
--     a missing method is logged and skipped rather than breaking the base mod.
--
--     Hook points (all verified against upstream v1.6.4.0):
--       RHM_RealisticHarvestManager.new / update / draw / mouseEvent / delete
--       RHMDraggableHUD.draw                     — suppressed while training (corner post replaces it)
--       RHM_LoadCalculator.calculateTotalCropLoss — the single seam for ALL loss physics
--       rhm_Combine.onRegisterActionEvents        — engine dispatches by name at raise time
--                                                   (SpecializationUtil.lua:24-25), so wrapping
--                                                   after load is honoured.
--
--     SANDBOX CONTRACT (unchanged from the fork): while training is active, loss physics is
--     skipped. Upstream derives grain removal, statistics, tracker loss reasons and
--     spec.data.cropLoss from calculateTotalCropLoss's return value, so returning 0 there
--     silences all of them together. Engine load, speed limiter, yield and throughput stay real.
--
-- UA: Міст режиму навчання — підключає режим навчання та кутову стійку до класів оригіналу ЗЗОВНІ,
--     тож файли оригіналу не мають правок форку. Кожен хук — обгортка методу класу; якщо метод
--     зникне, хук пропускається з записом у лог, а базовий мод не ламається.
TrainingBridge = {}

local warned = {}

-- EN: Log a runtime problem once per key. The hooks run every frame, so an unguarded error
--     would flood the log.
-- UA: Пишемо проблему в лог один раз на ключ — хуки працюють щокадру.
local function reportOnce(key, err)
    if warned[key] then return end
    warned[key] = true
    Logging.warning("[RHM-fork] TrainingBridge %s failed: %s", tostring(key), tostring(err))
end

-- EN: Replace class[name] with wrapper(orig, ...). Returns false (and logs) if the target is
--     missing, which is how an upstream rename shows up.
-- UA: Замінює class[name] на wrapper(orig, ...). Якщо цілі немає — false і запис у лог.
local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] TrainingBridge: %s.%s not found — hook skipped", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end

-- ============================================================================
-- EN: Manager lifecycle
-- UA: Життєвий цикл менеджера
-- ============================================================================

-- EN: Runs after upstream's constructor. Wrapped in pcall: a Training failure must never stop
--     the base mod from starting.
-- UA: Виконується після конструктора оригіналу. У pcall — збій навчання не має зупиняти мод.
function TrainingBridge.attach(self, mission, modDirectory)
    if TrainingMode and TrainingMode.registerConsoleCommand then
        TrainingMode.registerConsoleCommand()
    end
    if SignalConditioner and SignalConditioner.registerConsoleCommand then
        SignalConditioner.registerConsoleCommand()
    end

    addConsoleCommand("rhmPostScale", "Set corner post size (0.20-1.30)", "consoleSetPostScale", self)
    addConsoleCommand("rhmTrainingDebug", "Toggle the training text scaffolding overlay",
        "consoleToggleTrainingDebug", self)

    -- EN: Corner post is created for every client but only drawn while training is active.
    -- UA: Кутова стійка створюється на кожному клієнті, але малюється лише в режимі навчання.
    if mission:getIsClient() and CornerPostHUD then
        self.cornerPost = CornerPostHUD.new(modDirectory, self.settings)

        -- EN: Live layout editor. Registered here because the commands need the instance.
        -- UA: Редактор розмітки наживо — потребує екземпляра, тому реєструється тут.
        local cp = self.cornerPost
        addConsoleCommand("rhmPostList",  "List corner post layout elements",        "consoleList",  cp)
        addConsoleCommand("rhmPostSet",   "rhmPostSet <element> <x> <y> [w] [h]",    "consoleSet",   cp)
        addConsoleCommand("rhmPostNudge", "rhmPostNudge <element> <dx> <dy>",        "consoleNudge", cp)
        addConsoleCommand("rhmPostSize",  "rhmPostSize <element> <dw> <dh>",         "consoleSize",  cp)
        addConsoleCommand("rhmPostDump",  "Print the layout as a paste-ready table", "consoleDump",  cp)
        addConsoleCommand("rhmPostSide",  "rhmPostSide left|right|free",             "consoleSide",  cp)
    end
end

-- EN: Training pipeline in strict dependency order: input -> conditioner -> telemetry.
--     Runs from update(), not draw(), so the draw path stays purely presentational. It runs
--     whether or not a combine is present — the instructor may set channels up before
--     climbing in, and the conditioner must keep ticking so values are settled on arrival.
-- UA: Конвеєр навчання у порядку залежностей: введення -> кондиціонер -> телеметрія.
function TrainingBridge.tick(self, dt)
    if TrainingInput then TrainingInput.update(dt) end
    if SignalConditioner then SignalConditioner.update(dt) end
    if TelemetryProvider then TelemetryProvider.update(self.lastActiveCombine) end
end

-- EN: Mirrors the guards upstream applies before drawing its own HUD (client, no menu open,
--     game HUD visible, player in a vehicle).
-- UA: Повторює умови, за яких оригінал малює власний HUD.
function TrainingBridge.canDrawPost(self)
    if not (self.mission and self.mission:getIsClient()) then return false end
    if g_gui and g_gui.getIsGuiVisible and g_gui:getIsGuiVisible() then return false end
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.getIsVisible
        and not g_currentMission.hud:getIsVisible() then
        return false
    end
    return (self.lastControlledVehicle or self:getControlledVehicle()) ~= nil
end

-- ============================================================================
-- EN: Console + debug overlay (methods added to upstream's manager class; names do not clash)
-- UA: Консоль і налагоджувальне накладення (нові методи класу менеджера)
-- ============================================================================

-- EN: Resize the corner post and report the on-screen footprint, since "how big is 0.62" only
--     means something once you see what fraction of the screen it takes.
-- UA: Змінює розмір стійки та показує підсумкові розміри на екрані.
function RHM_RealisticHarvestManager:consoleSetPostScale(arg)
    if not self.cornerPost then
        return "Corner post is not available on this client."
    end

    local v = tonumber(arg)
    if v == nil then
        return string.format("Corner post scale is %.2f. Usage: rhmPostScale <0.20-1.30>",
            self.cornerPost.scale)
    end

    local s = self.cornerPost:setScale(v)
    return string.format("Corner post scale %.2f  (%.0f%% of screen height, %.0f%% of width)",
        s, s * 100, self.cornerPost:panelWidthNorm() * 100)
end

function RHM_RealisticHarvestManager:consoleToggleTrainingDebug()
    self.showTrainingDebug = not self.showTrainingDebug
    return string.format("Training scaffolding overlay: %s", self.showTrainingDebug and "ON" or "OFF")
end

-- EN: Text scaffolding shown beside the post: target vs shown for every column, the quickest
--     way to judge the noise and lag constants. Toggle: rhmTrainingDebug.
-- UA: Текстові риштування поруч зі стійкою: ціль і показане для кожної колонки.
function RHM_RealisticHarvestManager:drawTrainingDebug()
    if not TelemetryProvider then return end

    local d = TelemetryProvider.get()
    local x, y = 0.30, 0.90
    local lineH = 0.020

    setTextBold(true)
    setTextColor(1, 0.85, 0.1, 1)
    renderText(x, y, 0.017, "RHM TRAINING MODE  (scaffolding view)")
    setTextBold(false)
    y = y - lineH * 1.3

    setTextColor(0.7, 0.9, 1, 1)
    renderText(x, y, 0.014, "COLUMN        TARGET   SHOWN    SEGMENTS")
    y = y - lineH

    local shownVals = { shoeLoss = d.shoeLoss, totalLoss = d.totalLoss,
                        sepLoss  = d.sepLoss,  tailings  = d.tailings }
    local segCounts = { shoeLoss = d.shoeSeg,  totalLoss = d.totalSeg,
                        sepLoss  = d.sepSeg,   tailings  = d.tailSeg }

    for _, col in ipairs(TrainingMode.BAR_LAYOUT) do
        local isActive = (not col.derived) and TrainingMode.isChannelActive
                         and TrainingMode.isChannelActive(col.key)
        if isActive then
            setTextColor(1, 1, 0.3, 1)
        elseif col.derived then
            setTextColor(0.55, 0.75, 0.95, 1)
        else
            setTextColor(0.85, 0.85, 0.85, 1)
        end

        local segs  = segCounts[col.key] or 0
        local total = SignalConditioner and SignalConditioner.segments or 14
        local bar = string.rep("#", segs) .. string.rep(".", math.max(0, total - segs))

        -- EN: Derived columns have no target of their own to show.
        local targetStr = col.derived and "  --  "
            or string.format("%5.2f ", TrainingMode.getChannel(col.key))

        renderText(x, y, 0.014, string.format("%s%-12s %s  %5.2f    %s",
            isActive and ">" or " ",
            col.label .. (col.derived and " (=)" or ""),
            targetStr, shownVals[col.key] or 0, bar))
        y = y - lineH
    end

    y = y - lineH * 0.5
    setTextColor(0.6, 1, 0.6, 1)
    renderText(x, y, 0.014, string.format(
        "REAL  rpm %.0f   speed %.1f km/h   fuel %.0f%%   tank %.0f%%   moisture %.1f%%",
        d.engineRpm, d.speedKmh, d.fuelPct, d.tankPct, d.grainMoisture))
    y = y - lineH
    renderText(x, y, 0.014, string.format(
        "      load %.0f%%   yield %.2f t/ha   %.1f t/h   crop %s",
        d.engineLoad, d.yieldTha, d.tonPerHour, d.cropName ~= "" and d.cropName or "-"))
    y = y - lineH
    setTextColor(0.75, 0.75, 0.9, 1)
    renderText(x, y, 0.014, string.format(
        "SET   fan %d  rotor %d  concave %d  upper %d  lower %d",
        d.fan, d.rotor, d.concave, d.upperSieve, d.lowerSieve))
    y = y - lineH * 1.3

    setTextColor(0.55, 0.55, 0.55, 1)
    renderText(x, y, 0.013,
        "RShift+T exit    NUM 7/1 sieve    NUM 8/2 rotor    NUM 9/3 tailings    RShift+0 reset")

    -- EN: Always restore text state — renderText settings are global and a leaked colour or
    --     bold flag would corrupt every other text drawn this frame, including the game's own.
    -- UA: Обов'язково відновлюємо стан тексту — налаштування глобальні.
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- ============================================================================
-- EN: Install hooks
-- UA: Встановлення хуків
-- ============================================================================

local M = "RHM_RealisticHarvestManager"

wrapMethod(RHM_RealisticHarvestManager, M, "new", function(orig, mission, modDirectory, modName)
    local self = orig(mission, modDirectory, modName)
    local ok, err = pcall(TrainingBridge.attach, self, mission, modDirectory)
    if not ok then reportOnce("attach", err) end
    return self
end)

wrapMethod(RHM_RealisticHarvestManager, M, "update", function(orig, self, dt)
    orig(self, dt)
    if TrainingMode and TrainingMode.isActive and self.mission and self.mission:getIsClient() then
        local ok, err = pcall(TrainingBridge.tick, self, dt)
        if not ok then reportOnce("update", err) end
    end
end)

-- EN: Upstream draws first (calibration GUI, notifications); the corner post goes on top. The
--     normal HUD is silenced separately by the RHMDraggableHUD.draw wrapper below, so the two
--     never appear together.
-- UA: Оригінал малює першим; кутова стійка — зверху. Звичайний HUD вимикає обгортка нижче.
wrapMethod(RHM_RealisticHarvestManager, M, "draw", function(orig, self)
    orig(self)
    if not (TrainingMode and TrainingMode.suppressNormalHUD()) then return end
    if not TrainingBridge.canDrawPost(self) then return end

    local ok, err = pcall(function()
        if self.cornerPost then self.cornerPost:draw() end
        if self.showTrainingDebug then self:drawTrainingDebug() end
    end)
    if not ok then reportOnce("draw", err) end
end)

-- EN: The corner post only claims the mouse while training is drawing it — otherwise a hidden
--     panel would silently swallow clicks in its former screen region.
-- UA: Стійка перехоплює мишу лише коли її малюють — інакше поглинала б кліки у своїй області.
wrapMethod(RHM_RealisticHarvestManager, M, "mouseEvent", function(orig, self, posX, posY, isDown, isUp, button)
    if self.cornerPost and TrainingMode and TrainingMode.isActive
        and self.mission and self.mission:getIsClient() then
        local ok, used = pcall(self.cornerPost.mouseEvent, self.cornerPost, posX, posY, isDown, isUp, button)
        if ok and used then return true end
        if not ok then reportOnce("mouseEvent", used) end
    end
    return orig(self, posX, posY, isDown, isUp, button)
end)

wrapMethod(RHM_RealisticHarvestManager, M, "delete", function(orig, self)
    if self.cornerPost then
        self.cornerPost:delete()
        self.cornerPost = nil
    end
    return orig(self)
end)

-- EN: In training the corner post replaces the normal HUD entirely.
-- UA: У навчанні кутова стійка повністю замінює звичайний HUD.
wrapMethod(RHMDraggableHUD, "RHMDraggableHUD", "draw", function(orig, self, ...)
    if TrainingMode and TrainingMode.suppressNormalHUD() then return end
    return orig(self, ...)
end)

-- EN: THE loss seam. Zeroing every field the calculator exposes keeps GUI/HUD readers that
--     look at the fields directly (not just the return value) from showing stale numbers.
-- UA: Єдиний шов для втрат. Обнуляємо всі поля, щоб читачі полів не показували застарілі числа.
wrapMethod(RHM_LoadCalculator, "RHM_LoadCalculator", "calculateTotalCropLoss", function(orig, self, vehicle)
    if TrainingMode and TrainingMode.suppressLossPhysics() then
        self.cropLoss, self.totalLoss, self.totalCropLoss = 0, 0, 0
        self.baseLoss, self.overloadLoss, self.settingsAddedLoss = 0, 0, 0
        self.wearLoss, self.cutterWearLoss, self.combineWearLoss, self.totalWearLoss = 0, 0, 0, 0
        self.slopeLoss, self.moistureLoss = 0, 0
        return 0
    end
    return orig(self, vehicle)
end)

-- EN: Instructor key bindings. Registered into the SAME actionEvents table upstream just
--     filled, so they are cleared together when the player leaves the machine. The guard
--     mirrors upstream's own canRegister condition (rhm_Combine.lua onRegisterActionEvents).
-- UA: Клавіші інструктора реєструються в ту саму таблицю, що щойно заповнив оригінал.
if rhm_Combine and type(rhm_Combine.onRegisterActionEvents) == "function" then
    rhm_Combine.onRegisterActionEvents = Utils.appendedFunction(rhm_Combine.onRegisterActionEvents,
        function(self, isActiveForInput, isActiveForInputIgnoreSelection)
            if not self.isClient then return end
            local spec = self.spec_rhm_Combine
            if not spec or spec.isRhmCombine ~= true then return end

            local canRegister = isActiveForInputIgnoreSelection
                or self.isActiveForInputIgnoreSelectionIgnoreAI
                or (self.getIsEntered and self:getIsEntered())

            if canRegister and TrainingInput and TrainingInput.registerActionEvents then
                TrainingInput.registerActionEvents(self, spec.actionEvents)
            end
        end)
else
    Logging.warning("[RHM-fork] TrainingBridge: rhm_Combine.onRegisterActionEvents not found — training keys unavailable")
end
