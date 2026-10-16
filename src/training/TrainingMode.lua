-- EN: Training Mode — instructor-driven combine operator training.
--
--     PURPOSE
--     When active, the mod stops simulating grain loss and instead hands the loss displays
--     to an instructor, who drives them live from the keyboard while a student operates the
--     machine. The student reads the corner post and makes setting adjustments; the instructor
--     reacts by moving the bars. The instructor IS the physics model.
--
--     WHY NO SIMULATED LOSS
--     The mod's loss model scores settings by absolute distance from optimal, so deviating
--     high and low cost the same. Real combines are strongly directional (fan too high blows
--     grain over the back; fan too low loads the shoe and spikes tailings). Rather than model
--     that, training mode defers entirely to a human expert who already knows the mapping.
--
--     SANDBOX CONTRACT — what training mode suppresses:
--       * physical grain removal from the fill unit (no loss, header or otherwise)
--       * loss accumulation into session statistics (they would record fiction)
--       * the loss fields in spec.data (zeroed, so no stale values leak to other UI)
--     What it deliberately leaves ALONE, because it is real telemetry:
--       * engine load, ground speed, engine RPM, fuel, grain moisture, yield, tank level
--       * the speed limiter (driven by real engine load — a combine that doesn't slow in
--         heavy crop would teach a falsehood)
--
--     Single-player / instructor-station feature. Not synchronised over the network.
--
-- UA: Режим навчання — тренування оператора комбайна під керуванням інструктора.
--     Коли активний, мод припиняє симулювати втрати зерна і передає індикатори втрат
--     інструктору, який керує ними з клавіатури в реальному часі. Інструктор — це модель.
--     Пісочниця: фізичне видалення зерна, статистика втрат і поля втрат у spec.data вимкнені.
--     Реальна телеметрія (навантаження, швидкість, оберти, паливо, вологість) не змінюється.
TrainingMode = {}

-- EN: Runtime-only. Deliberately NOT persisted across sessions: a forgotten "on" would mean
--     playing normally with all loss silently disabled, which is a confusing failure mode.
--     Starting off every session makes the state always explicit.
-- UA: Тільки під час сесії. Свідомо НЕ зберігається: забутий "увімкнено" означав би гру
--     без втрат, що є заплутаним. Старт завжди вимкнений.
TrainingMode.isActive = false

-- EN: DRIVEN channel definitions — the single source of truth for what the instructor
--     actually controls. Order here is the cycle order of the arm key.
--
--     value semantics: every channel is 0..1 where HIGHER MEANS MORE OF THE THING NAMED.
--       shoeLoss 1.0 = maximum cleaning-shoe loss
--       sepLoss  1.0 = maximum separator loss
--       tailings 1.0 = maximum tailings volume
--
--     TOTAL LOSS IS NOT HERE, DELIBERATELY.
--     On the real S770 post the centre bar is shoe + separator combined, so it is a computed
--     quantity, not a sensor of its own. Exposing it as a fourth driven channel would let the
--     instructor set a total that contradicts its own components — a state the real machine
--     cannot enter. It is derived instead: see SignalConditioner.getTotalLoss().
--
--     initial: where a channel sits on entering training mode or on reset. Losses start at a
--     low-but-nonzero trickle because a real machine never sits at a hard zero, and tailings
--     sit slightly higher because a correctly set machine always returns some material.
-- UA: Канали, якими КЕРУЄ інструктор — єдине джерело істини. Значення 0..1.
--     ЗАГАЛЬНІ ВТРАТИ тут свідомо відсутні: на реальній стійці S770 центральна смуга — це
--     сума втрат решета і сепаратора, тобто обчислювана величина, а не окремий датчик.
--     Окремий канал дозволив би інструктору задати суму, що суперечить її складовим —
--     стан, у який реальна машина потрапити не може. Див. SignalConditioner.getTotalLoss().
TrainingMode.CHANNELS = {
    { key = "shoeLoss", label = "SHOE", initial = 0.12 },
    { key = "sepLoss",  label = "SEP",  initial = 0.12 },
    { key = "tailings", label = "TAIL", initial = 0.20 },
}

-- EN: Physical left-to-right order of the vertical columns on the post, for the renderer.
--     Deliberately distinct from CHANNELS: the post shows the derived total between the two
--     components it is made from, and tailings sits apart on the far right.
--     `derived = true` marks a column the instructor cannot arm.
-- UA: Фізичний порядок колонок на стійці (зліва направо) для рендерера. Свідомо відрізняється
--     від CHANNELS: похідна сума показана між своїми складовими, а тайлінги — окремо справа.
--     `short` is the on-panel caption. The columns sit close together, so the full labels
--     collide when drawn beneath them — the real post uses icons here, and these captions are
--     placeholders until those exist. `label` stays long for the text UI and warnings, where
--     there is room and clarity matters more than width.
-- UA: `short` — підпис на панелі (колонки стоять щільно, довгі підписи накладаються;
--     на реальній стійці тут іконки). `label` лишається довгим для текстового UI.
TrainingMode.BAR_LAYOUT = {
    { key = "shoeLoss",  label = "SHOE",  short = "SHOE", derived = false },
    { key = "totalLoss", label = "TOTAL", short = "TOT",  derived = true  },
    { key = "sepLoss",   label = "SEP",   short = "SEP",  derived = false },
    { key = "tailings",  label = "TAIL",  short = "TAIL", derived = false, separated = true },
}

-- EN: Fast key→definition lookup, built once at load.
-- UA: Швидкий пошук за ключем, будується один раз.
TrainingMode.CHANNEL_BY_KEY = {}
for i, def in ipairs(TrainingMode.CHANNELS) do
    def.index = i
    TrainingMode.CHANNEL_BY_KEY[def.key] = def
end

TrainingMode.CHANNEL_COUNT = #TrainingMode.CHANNELS

-- EN: Instructor-set target per channel (the value BEFORE noise and lag are applied).
--     SignalConditioner reads these and produces the displayed value.
-- UA: Цільове значення каналу, задане інструктором (ДО шуму та затримки).
TrainingMode.targets = {}

-- EN: Timestamp (ms) of the last movement on each channel, keyed by channel key.
--     Every channel has its own dedicated key pair, so there is no armed selection to show.
--     Instead the panel highlights whichever columns are moving RIGHT NOW, which is better
--     feedback anyway: it confirms the key registered, and an observer can see what the
--     instructor is doing without being told.
-- UA: Час останнього руху кожного каналу. Кожен канал має власну пару клавіш, тому вибору
--     каналу немає — панель підсвічує ті колонки, що рухаються ЗАРАЗ.
TrainingMode.activity = {}

-- EN: How long after a movement a channel still counts as "active" for the highlight.
-- UA: Скільки часу після руху канал вважається активним для підсвічування.
TrainingMode.ACTIVITY_HOLD_MS = 350

TrainingMode.lastInputTime = 0

-- ============================================================================
-- EN: Lifecycle
-- UA: Життєвий цикл
-- ============================================================================

-- EN: Resets every channel to its documented starting value.
-- UA: Скидає всі канали до початкових значень.
function TrainingMode.resetChannels()
    for _, def in ipairs(TrainingMode.CHANNELS) do
        TrainingMode.targets[def.key] = def.initial
    end
end

-- EN: Enters or leaves training mode. Returns the new state.
--     On entry: channels reset to a sane starting picture and the conditioner is snapped to
--     those values so the bars do not visibly sweep up from zero on the first frame.
-- UA: Вмикає/вимикає режим. При вході канали скидаються і кондиціонер вирівнюється,
--     щоб смуги не "виїжджали" з нуля на першому кадрі.
function TrainingMode.setActive(active)
    active = active and true or false
    if active == TrainingMode.isActive then
        return TrainingMode.isActive
    end

    TrainingMode.isActive = active

    if active then
        TrainingMode.resetChannels()
        TrainingMode.activity = {}
        if SignalConditioner then
            SignalConditioner.snapToTargets()
        end
    end

    return TrainingMode.isActive
end

function TrainingMode.toggle()
    return TrainingMode.setActive(not TrainingMode.isActive)
end

-- ============================================================================
-- EN: Instructor control surface — called by TrainingInput.
-- UA: Поверхня керування інструктора — викликається з TrainingInput.
-- ============================================================================

-- EN: Adjusts one channel by delta, clamped to 0..1.
--     delta is already dt-scaled by the caller so held keys ramp smoothly rather than step.
--     Every channel has its own key pair and they are all live simultaneously — the
--     instructor can drive two columns at once with two fingers, which matters because real
--     loss channels move together (opening the chaffer drops shoe loss and lifts tailings).
-- UA: Змінює один канал на delta з обмеженням 0..1. Усі канали активні одночасно —
--     інструктор може рухати дві колонки двома пальцями, бо реальні втрати рухаються разом.
function TrainingMode.adjustChannel(key, delta)
    local def = TrainingMode.CHANNEL_BY_KEY[key]
    if not def then return nil end

    local cur = TrainingMode.targets[key] or def.initial
    local new = math.max(0.0, math.min(1.0, cur + delta))

    if new ~= cur then
        TrainingMode.targets[key] = new
        local now = g_currentMission and g_currentMission.time or 0
        TrainingMode.activity[key]  = now
        TrainingMode.lastInputTime  = now
    end

    return new
end

-- EN: True while a channel is moving or has just stopped, for the panel highlight.
-- UA: True поки канал рухається або щойно зупинився — для підсвічування панелі.
function TrainingMode.isChannelActive(key)
    local t = TrainingMode.activity[key]
    if not t then return false end
    local now = g_currentMission and g_currentMission.time or 0
    return (now - t) <= TrainingMode.ACTIVITY_HOLD_MS
end

-- EN: Direct setter, used by the console command and any future scenario playback.
-- UA: Пряме встановлення — для консольної команди та майбутнього відтворення сценаріїв.
function TrainingMode.setChannel(key, value)
    local def = TrainingMode.CHANNEL_BY_KEY[key]
    if not def then return nil end

    value = math.max(0.0, math.min(1.0, tonumber(value) or 0))
    TrainingMode.targets[key] = value
    TrainingMode.lastInputTime = g_currentMission and g_currentMission.time or 0
    return value
end

function TrainingMode.getChannel(key)
    local def = TrainingMode.CHANNEL_BY_KEY[key]
    if not def then return 0 end
    return TrainingMode.targets[key] or def.initial
end

-- EN: Panic reset — every channel back to its starting value.
-- UA: Аварійне скидання — усі канали до початкових значень.
function TrainingMode.zeroAll()
    TrainingMode.resetChannels()
    TrainingMode.lastInputTime = g_currentMission and g_currentMission.time or 0
end

-- ============================================================================
-- EN: Sandbox guards — queried by rhm_Combine to suppress real loss physics.
--     Kept as named functions rather than raw isActive checks so the intent is legible at
--     the call site and so the policy can change in one place.
-- UA: Захисні перевірки пісочниці — викликаються з rhm_Combine.
-- ============================================================================

-- EN: True when physical grain removal and loss statistics must be skipped.
-- UA: True коли фізичне видалення зерна та статистику втрат треба пропустити.
function TrainingMode.suppressLossPhysics()
    return TrainingMode.isActive
end

-- EN: True when the normal draggable HUD should give way to the corner post.
-- UA: True коли звичайний HUD має поступитися місцем кутовій стійці.
function TrainingMode.suppressNormalHUD()
    return TrainingMode.isActive
end

-- EN: Upgrade tiers gate the loss displays in normal play. In training mode every display
--     must be visible regardless of what the student's machine has been bought with, so the
--     effective tier is forced to maximum. Non-destructive: reads only, never writes the
--     stored upgradeLevel, so leaving training mode restores the real tier automatically.
-- UA: Рівні апгрейду приховують індикатори у звичайній грі. У режимі навчання всі
--     індикатори мають бути видимі, тому ефективний рівень примусово максимальний.
--     Тільки читання — збережений upgradeLevel не змінюється.
TrainingMode.FORCED_UPGRADE_LEVEL = 3

function TrainingMode.getEffectiveUpgradeLevel(realLevel)
    if TrainingMode.isActive then
        return TrainingMode.FORCED_UPGRADE_LEVEL
    end
    return realLevel or 0
end

-- ============================================================================
-- EN: Console command — lets the instructor script or spot-set values without keybinds,
--     and is the quickest way to sanity-check the pipeline before the renderer exists.
--       rhmTraining              → toggle
--       rhmTraining on|off       → explicit
--       rhmTraining sepLoss 0.7  → set a channel directly
-- UA: Консольна команда для перемикання та прямого встановлення значень.
-- ============================================================================
function TrainingMode.consoleCommand(_, arg1, arg2)
    if arg1 == nil or arg1 == "" then
        TrainingMode.toggle()
        return string.format("RHM Training Mode: %s", TrainingMode.isActive and "ON" or "OFF")
    end

    local a1 = tostring(arg1):lower()

    if a1 == "on" or a1 == "1" or a1 == "true" then
        TrainingMode.setActive(true)
        return "RHM Training Mode: ON"
    elseif a1 == "off" or a1 == "0" or a1 == "false" then
        TrainingMode.setActive(false)
        return "RHM Training Mode: OFF"
    elseif a1 == "status" then
        local parts = {}
        for _, def in ipairs(TrainingMode.CHANNELS) do
            local shown = SignalConditioner and SignalConditioner.getValue(def.key) or 0
            table.insert(parts, string.format("%s target=%.2f shown=%.2f",
                def.label, TrainingMode.getChannel(def.key), shown))
        end
        return string.format("RHM Training Mode: %s | %s",
            TrainingMode.isActive and "ON" or "OFF",
            table.concat(parts, " | "))
    end

    -- EN: Treat as "<channelKey> <value>". Match case-insensitively for convenience.
    -- UA: Обробляємо як "<ключ каналу> <значення>".
    for _, def in ipairs(TrainingMode.CHANNELS) do
        if def.key:lower() == a1 or def.label:lower() == a1 then
            local v = tonumber(arg2)
            if v == nil then
                return string.format("Usage: rhmTraining %s <0.0-1.0>", def.key)
            end
            TrainingMode.setChannel(def.key, v)
            return string.format("RHM Training: %s = %.2f", def.key, TrainingMode.getChannel(def.key))
        end
    end

    local names = {}
    for _, def in ipairs(TrainingMode.CHANNELS) do table.insert(names, def.key) end
    return string.format("Usage: rhmTraining [on|off|status|<channel> <0.0-1.0>]  channels: %s",
        table.concat(names, ", "))
end

function TrainingMode.registerConsoleCommand()
    if TrainingMode._consoleRegistered then return end
    TrainingMode._consoleRegistered = true
    addConsoleCommand("rhmTraining", "Toggle or drive RHM training mode channels",
        "consoleCommand", TrainingMode)
end

-- EN: Initialise targets at load so any early reader gets sane values rather than nil.
-- UA: Ініціалізуємо цілі одразу, щоб ранні читачі не отримали nil.
TrainingMode.resetChannels()
