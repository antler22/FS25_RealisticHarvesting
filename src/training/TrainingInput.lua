-- EN: Training Input — the instructor's control surface.
--
--     DIRECT NUMPAD CONTROL
--     Every channel has its own dedicated up/down key pair and all of them are live at once.
--     There is no mode to select and nothing to cycle through. The numpad's 3x3 grid maps
--     spatially onto the panel: the top row raises, the bottom row lowers, and each column
--     of keys owns one column of the display.
--
--         NUM 7      NUM 8      NUM 9       <- raise
--         NUM 1      NUM 2      NUM 3       <- lower
--         SIEVE      ROTOR      TAILINGS
--        (shoe)     (separator)
--
--     Simultaneity is the point, not a convenience. Real loss channels move together —
--     opening the chaffer drops shoe loss while lifting tailings — so an instructor needs to
--     drive two columns at once with two fingers to portray a plausible machine. An
--     armed-channel scheme made that impossible.
--
--     HELD-KEY RAMPING
--     Adjust actions register with triggerAlways so their callback fires every frame,
--     including while held. The callback only records the current input value; the movement
--     is integrated in update() against dt. Applying a fixed step per callback would tie the
--     ramp rate to frame rate — smooth at 30 fps, uncontrollable at 144 — which is the class
--     of bug that makes a control feel wrong on someone else's machine.
--
--     NUM LOCK MUST BE ON. With it off, the numpad sends End/Down/PageDown rather than the
--     KP digit codes, and none of these bindings will fire. Do NOT reach for a Shift modifier
--     to free up keys either: on Windows, holding Shift with the numpad temporarily inverts
--     Num Lock, so Shift+NumPad7 arrives as Home and the binding can never match.
--
--     CLAIMING THE BOTTOM ROW
--     NumPad 1/2/3 are the turn signals on a stock keyboard layout, and those action events
--     are live in every vehicle. Registration of a colliding binding does not merely lose the
--     keypress — it fails outright: InputBinding:checkEventCollision disables the newly
--     registered action's binding, finds the action now has zero active bindings, re-enables
--     them and reports a collision, so registerActionEvent returns false and NO EVENT IS
--     CREATED. That is why the top row worked and the bottom row never did: NumPad 7/8/9 are
--     bound to shift-group and pivot actions that have no active event inside a combine, so
--     there was nothing to collide with.
--
--     So training mode takes those keys, and gives them back. While it is on, the colliding
--     action events are removed just before ours are registered; when it is off we simply do
--     not evict, and the vehicle's normal registration pass restores them. The eviction is
--     computed from the bindings actually in force, not from a hard-coded list of action
--     names, so it still works for someone who has moved their turn signals elsewhere — and
--     it takes nothing that is not genuinely sitting on a key we need.
--
-- UA: Введення інструктора — ПРЯМЕ КЕРУВАННЯ З ЦИФРОВОЇ КЛАВІАТУРИ.
--     Кожен канал має власну пару клавіш, усі активні одночасно; нічого перемикати не треба.
--     Сітка 3x3 відповідає колонкам панелі: верхній ряд — вгору, нижній — вниз.
--     Одночасність принципова: реальні втрати рухаються разом (відкриття решета знижує
--     втрати решета і піднімає тайлінги), тому інструктору потрібні два пальці.
--     ПЛАВНЕ УТРИМАННЯ: колбек лише записує значення, рух інтегрується в update() по dt.
--     NUM LOCK МАЄ БУТИ УВІМКНЕНИЙ — інакше цифрова клавіатура шле інші коди.
TrainingInput = {}

-- EN: Full-scale travel per second while a key is held. 0.55 crosses the whole range in just
--     under two seconds: fast enough to stage a sudden loss event, slow enough to place a
--     value precisely without tapping.
-- UA: Повний хід шкали за секунду при утриманні (~1.8 с на весь діапазон).
TrainingInput.RAMP_PER_SEC = 0.55

-- EN: Which channel each key pair drives, and the operator-facing name for it.
--     The instructor thinks in machine parts — sieve, rotor — while the model thinks in loss
--     locations. This table is where those two vocabularies meet, and it is the only place
--     that mapping is stated.
-- UA: Який канал керується якою парою клавіш, і назва зрозуміла оператору.
--     Інструктор думає деталями машини (решето, ротор), модель — місцями втрат.
TrainingInput.KEY_CHANNELS = {
    { channel = "shoeLoss", name = "SIEVE",    upAction = "RHM_TRAIN_SHOE_UP", downAction = "RHM_TRAIN_SHOE_DOWN" },
    { channel = "sepLoss",  name = "ROTOR",    upAction = "RHM_TRAIN_SEP_UP",  downAction = "RHM_TRAIN_SEP_DOWN"  },
    { channel = "tailings", name = "TAILINGS", upAction = "RHM_TRAIN_TAIL_UP", downAction = "RHM_TRAIN_TAIL_DOWN" },
}

-- EN: Live input value per channel, written by the callbacks each frame and consumed by
--     update(). Pre-populated so the table is never resized during play.
-- UA: Поточне значення введення для кожного каналу. Таблиця створюється наперед.
TrainingInput._up   = {}
TrainingInput._down = {}
for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
    TrainingInput._up[m.channel]   = 0
    TrainingInput._down[m.channel] = 0
end

-- ============================================================================
-- EN: Action callbacks
-- UA: Колбеки дій
-- ============================================================================

-- EN: Last seen training state, used to detect the edge in update(). Deliberately NOT set by
--     the toggle callback: training mode is also switched by the rhmTraining console command,
--     and a rebind hook that only the key knows about would leave the console path with dead
--     adjust keys. Watching the state itself covers every way it can change.
--
--     Deferring to update() also keeps the re-registration out of the input dispatch loop —
--     requesting an action-event update from inside a callback tears down the very event
--     collections that loop is walking.
-- UA: Останній відомий стан режиму навчання для виявлення зміни в update(). Навмисно не
--     встановлюється в колбеку перемикача: режим також вмикається консольною командою.
--     Відкладення до update() тримає перереєстрацію поза циклом обробки введення.
TrainingInput._lastActive = false

function TrainingInput.actionToggle()
    TrainingMode.toggle()

    if g_currentMission then
        g_currentMission:showBlinkingWarning(
            TrainingMode.isActive
                and "RHM Training Mode: ON  —  NUM 7/1 sieve, 8/2 rotor, 9/3 tailings"
                or  "RHM Training Mode: OFF  —  normal simulation resumed",
            3000)
    end
end

function TrainingInput.actionZero()
    if not TrainingMode.isActive then return end

    TrainingMode.zeroAll()
    if g_currentMission then
        g_currentMission:showBlinkingWarning("Training channels reset", 2000)
    end
end

-- EN: Shared adjust callbacks. The channel is carried in callbackState, set at registration,
--     so three key pairs need two functions rather than six near-identical ones.
--     Signature: (target, actionName, inputValue, callbackState, isAnalog)
-- UA: Спільні колбеки. Канал передається через callbackState, заданий при реєстрації —
--     тому три пари клавіш потребують двох функцій, а не шести майже однакових.
function TrainingInput.actionUp(_, _, inputValue, callbackState)
    if callbackState then
        TrainingInput._up[callbackState] = inputValue or 0
    end
end

function TrainingInput.actionDown(_, _, inputValue, callbackState)
    if callbackState then
        TrainingInput._down[callbackState] = inputValue or 0
    end
end

-- ============================================================================
-- EN: Per-frame integration
-- UA: Покадрова інтеграція
-- ============================================================================
function TrainingInput.update(dt)
    -- EN: Training mode just changed hands — re-run the vehicle's action registration so the
    --     adjust keys are claimed on the way in and released on the way out. Done first so
    --     the keys have changed owner before anything reads them this frame.
    -- UA: Режим навчання щойно змінився — перезапускаємо реєстрацію дій машини.
    local active = (TrainingMode ~= nil and TrainingMode.isActive) and true or false
    if active ~= TrainingInput._lastActive then
        TrainingInput._lastActive = active
        local v = g_realisticHarvestManager ~= nil
            and g_realisticHarvestManager:getControlledVehicle() or nil
        if v ~= nil and v.requestActionEventUpdate ~= nil then
            v:requestActionEventUpdate()
        end
    end

    if not TrainingMode or not TrainingMode.isActive then
        for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
            TrainingInput._up[m.channel]   = 0
            TrainingInput._down[m.channel] = 0
        end
        return
    end

    -- EN: Same dt clamp as the conditioner — a loading hitch must not fling a channel to the
    --     rail while the instructor's finger happens to be down.
    -- UA: Те саме обмеження dt, що й у кондиціонера.
    local dtS = math.max(0.0, math.min((dt or 0) / 1000.0, 0.10))
    if dtS <= 0.0 then return end

    local step = TrainingInput.RAMP_PER_SEC * dtS

    -- EN: Every channel is integrated independently every frame, which is what makes
    --     simultaneous two-finger control work.
    -- UA: Кожен канал інтегрується незалежно щокадру — саме це дає одночасне керування.
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        local net = (TrainingInput._up[m.channel] or 0) - (TrainingInput._down[m.channel] or 0)
        if net ~= 0 then
            TrainingMode.adjustChannel(m.channel, net * step)
        end
    end
end

-- ============================================================================
-- EN: Key claiming
-- UA: Захоплення клавіш
-- ============================================================================

-- EN: The keystrokes one action currently answers to, as a set of engine input strings
--     ("KEY_KP_1"). Reads the live bindings rather than the modDesc defaults, because once
--     FS25 has written inputBinding.xml the user's file is what is in force and the modDesc
--     is only a first-run seed.
-- UA: Набір комбінацій, на які реагує дія, у вигляді рядків рушія. Читаються ЧИННІ прив'язки,
--     бо після першого запуску діє inputBinding.xml користувача, а не modDesc.
function TrainingInput.getBindingSignatures(actionName, out)
    local action = g_inputBinding ~= nil and g_inputBinding.nameActions ~= nil
        and g_inputBinding.nameActions[actionName] or nil
    if action == nil or action.getBindings == nil then return out end

    for _, b in pairs(action:getBindings()) do
        if b.isActive and b.inputString ~= nil and b.inputString ~= "" then
            out[b.inputString] = true
        end
    end
    return out
end

-- EN: Removes the action events of anything already sitting on a key we need, and records
--     what was taken. Collision in this engine is an EXACT match of the whole key list, so
--     this only ever displaces something bound to precisely our combination — a hypothetical
--     Ctrl+NumPad1 elsewhere is left alone, as the engine would not have collided with it.
--
--     Only actions that currently hold a registered event are candidates. An action that is
--     merely bound but dormant cannot block us, so taking it would be pure vandalism.
-- UA: Прибирає події дій, що вже займають потрібну клавішу, і запам'ятовує їх. Колізія в
--     рушії — це ТОЧНИЙ збіг усього списку клавіш, тож ми витісняємо лише точні збіги.
--     Кандидати — лише дії, що мають зареєстровану подію; сплячі не заважають.
function TrainingInput.claimKeys(actionNames)
    TrainingInput._claimed = {}

    if g_inputBinding == nil or g_inputBinding.actionEvents == nil then return end

    local ours, wanted = {}, {}
    for _, name in ipairs(actionNames) do
        ours[name] = true
        TrainingInput.getBindingSignatures(name, wanted)
    end
    if next(wanted) == nil then return end

    -- EN: Collect first, remove after. removeActionEventsByActionName rebuilds the event
    --     collections, so mutating while iterating them would be undefined.
    -- UA: Спочатку зібрати, потім видалити — видалення перебудовує колекції подій.
    local evict = {}
    for action, events in pairs(g_inputBinding.actionEvents) do
        local name = action ~= nil and action.name or nil
        if name ~= nil and not ours[name] and events ~= nil and #events > 0
                and action.getBindings ~= nil then
            for _, b in pairs(action:getBindings()) do
                if b.isActive and b.inputString ~= nil and wanted[b.inputString] then
                    evict[#evict + 1] = name
                    break
                end
            end
        end
    end

    for _, name in ipairs(evict) do
        g_inputBinding:removeActionEventsByActionName(name)
        TrainingInput._claimed[#TrainingInput._claimed + 1] = name
    end

    if #TrainingInput._claimed > 0 then
        Logging.info("[RHM] Training mode has taken %d key binding(s) for the loss controls: %s. "
            .. "They are restored when training mode is switched off.",
            #TrainingInput._claimed, table.concat(TrainingInput._claimed, ", "))
    end
end

TrainingInput._claimed = {}

-- ============================================================================
-- EN: Registration — called from rhm_Combine:onRegisterActionEvents.
--     Bindings live only while the player is in a machine, so they cannot collide with
--     on-foot or menu contexts.
-- UA: Реєстрація — з rhm_Combine:onRegisterActionEvents.
-- ============================================================================
function TrainingInput.registerActionEvents(vehicle, actionEventsTable)
    if not vehicle.isClient then return end

    -- EN: Discrete commands: fire once on press.
    -- UA: Дискретні команди: спрацьовують один раз при натисканні.
    local discrete = {
        { action = InputAction.RHM_TRAIN_TOGGLE, cb = TrainingInput.actionToggle, visible = true  },
        { action = InputAction.RHM_TRAIN_ZERO,   cb = TrainingInput.actionZero,   visible = false },
    }

    for _, entry in ipairs(discrete) do
        if entry.action then
            local _, eventId = vehicle:addActionEvent(
                actionEventsTable, entry.action, vehicle, entry.cb,
                false, true, false, true, nil)
            if eventId then
                g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
                -- EN: Only the toggle advertises itself in the help box. The adjust keys are
                --     meaningless until training mode is on and would be six lines of clutter.
                -- UA: Лише перемикач показується у підказках — решта були б шістьма рядками шуму.
                g_inputBinding:setActionEventTextVisibility(eventId, entry.visible)
            end
        end
    end

    -- EN: Take the adjust keys off whatever holds them, but ONLY while training mode is on.
    --     Order matters and is the whole trick: this must happen before the addActionEvent
    --     calls below, because a collision is decided at registration time and a refused
    --     registration produces no event at all. With training off we skip the claim, our
    --     adjust events fail to register exactly as they used to, and the keys stay with
    --     their normal owners — which is the correct outcome, since the keys do nothing
    --     outside training mode anyway.
    -- UA: Забираємо клавіші регулювання, але ЛИШЕ у режимі навчання. Порядок критичний:
    --     це має статись ДО addActionEvent, бо колізія вирішується під час реєстрації, а
    --     відхилена реєстрація не створює події взагалі.
    local adjustNames = {}
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        adjustNames[#adjustNames + 1] = m.upAction
        adjustNames[#adjustNames + 1] = m.downAction
    end

    if TrainingMode ~= nil and TrainingMode.isActive then
        TrainingInput.claimKeys(adjustNames)
    else
        TrainingInput._claimed = {}
    end

    -- EN: Continuous adjust pairs. triggerAlways so a held key keeps delivering a value to
    --     integrate; the channel key rides along in callbackState.
    -- UA: Неперервні пари регулювання. triggerAlways, канал передається в callbackState.
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        local pairs_ = {
            { action = InputAction[m.upAction],   cb = TrainingInput.actionUp   },
            { action = InputAction[m.downAction], cb = TrainingInput.actionDown },
        }
        for _, entry in ipairs(pairs_) do
            if entry.action then
                local ok, eventId = vehicle:addActionEvent(
                    actionEventsTable, entry.action, vehicle, entry.cb,
                    false, false, true, true, m.channel)
                if eventId then
                    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_LOW)
                    g_inputBinding:setActionEventTextVisibility(eventId, false)
                -- EN: Say so when a key could not be taken. A refused registration is
                --     completely silent otherwise — the key simply does nothing, which is
                --     indistinguishable from a broken feature and cost two rounds of
                --     guessing before the cause was found in the engine source.
                -- UA: Повідомляємо, якщо клавішу не вдалося зайняти. Інакше відмова тиха —
                --     клавіша просто не працює, що не відрізнити від зламаної функції.
                elseif not ok and TrainingMode ~= nil and TrainingMode.isActive then
                    Logging.warning("[RHM] Could not bind %s — its key is held by another "
                        .. "action that would not release it. Rebind it in Options > Controls.",
                        entry.action)
                end
            end
        end
    end
end
