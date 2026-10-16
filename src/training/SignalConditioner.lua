-- EN: Signal Conditioner — turns instructor keyboard input into something that reads like a
--     real loss sensor on a corner post.
--
--     Three stages, applied per channel, every frame:
--
--       1. NOISE — a slow band-limited random walk (Ornstein-Uhlenbeck), NOT white noise.
--          White noise reads as broken hardware: it flickers at frame rate and the eye
--          immediately classifies it as a rendering artefact. A real loss sensor wanders,
--          because it is integrating a genuinely noisy physical process (grain striking a
--          plate) over a time constant. The OU process reproduces that wander: it is
--          correlated in time, mean-reverting, and has a tunable bandwidth.
--
--       2. LAG — first-order low-pass toward (target + noise).
--          This is the pedagogically important stage. A real monitor takes several seconds
--          to settle after a setting change, which is precisely why an operator must make
--          ONE adjustment and WAIT rather than chase the bar. Instant response would teach
--          a control loop far tighter than any real machine permits.
--
--       3. QUANTISE — snap to discrete bar segments at display time.
--          The physical post is a column of discrete LED segments, so this is fidelity, not
--          just decoration. It also has a useful side effect: it hides the staircase that
--          discrete keyboard input would otherwise produce, which is why keyboard-only
--          control is perfectly adequate here.
--
--     All constants are tunable at runtime via the rhmTrainingTune console command, because
--     the right feel is a judgement call best made while watching the bars move.
--
-- UA: Кондиціонер сигналу — перетворює введення інструктора на щось, що виглядає як
--     справжній датчик втрат.
--       1. ШУМ — повільне випадкове блукання (Орнштейна-Уленбека), НЕ білий шум.
--          Білий шум виглядає як несправність; справжній датчик повільно блукає.
--       2. ЗАТРИМКА — фільтр першого порядку. Педагогічно найважливіша стадія: справжній
--          монітор реагує кілька секунд, тому оператор має зробити ОДНЕ налаштування і
--          ЧЕКАТИ, а не гнатися за смугою.
--       3. КВАНТУВАННЯ — прив'язка до дискретних сегментів смуги (як реальні світлодіоди).
SignalConditioner = {}

-- ============================================================================
-- EN: Tunable constants
-- UA: Налаштовувані константи
-- ============================================================================

-- EN: Noise correlation time (seconds). Larger = slower, lazier wander.
--     0.8 s puts the wander in the band where the eye reads it as physical, not as flicker.
-- UA: Час кореляції шуму (с). Більше = повільніше блукання.
SignalConditioner.noiseTau = 0.8

-- EN: Noise amplitude as a fraction of full scale (1 sigma).
--     0.030 gives roughly +/-3% wander, about one bar segment on a 14-segment column —
--     visible as life, not as instability.
-- UA: Амплітуда шуму як частка повної шкали (1 сигма). ~+/-3% — один сегмент смуги.
SignalConditioner.noiseSigma = 0.030

-- EN: Sensor lag time constant (seconds). A first-order filter reaches ~63% of a step in
--     one tau and ~95% in three, so 2.5 s means a setting change takes ~7 s to fully read
--     out. That matches the "make a change, drive a bit, then look" rhythm of real setup.
-- UA: Стала часу затримки (с). 2.5 с означає, що зміна повністю проявляється за ~7 с.
SignalConditioner.lagTau = 2.5

-- EN: Segment count for the loss/tailings bar columns. Counted off the HD panel draft, where
--     each column reads as eleven cells. Confirm against the finished art — everything on the
--     panel quantises off this one number, so it is the single most load-bearing constant here.
-- UA: Кількість сегментів колонки — порахована з HD-чернетки (одинадцять комірок).
--     Уся панель квантується від цього числа — найважливіша константа тут.
SignalConditioner.segments = 11

-- EN: Below this, treat the bar as fully dark. Prevents a permanently-lit bottom segment
--     from noise alone when the instructor has a channel parked at zero.
-- UA: Нижче цього смуга повністю темна — щоб шум не тримав нижній сегмент увімкненим.
SignalConditioner.deadband = 0.02

-- ============================================================================
-- EN: Per-channel filter state
-- UA: Стан фільтра для кожного каналу
-- ============================================================================
SignalConditioner.state = {}

-- EN: Gaussian sample via Box-Muller. The transform naturally produces two independent
--     normals per call, so the spare is cached and returned on the following call — half
--     the sqrt/log/cos work for the same result.
-- UA: Нормальний розподіл через Бокса-Мюллера. Перетворення дає дві незалежні величини,
--     тому друга кешується для наступного виклику — удвічі менше обчислень.
local spareGaussian = nil
local function gaussian()
    if spareGaussian ~= nil then
        local v = spareGaussian
        spareGaussian = nil
        return v
    end

    -- EN: u1 must be strictly > 0 for log(); math.random() can return 0 in some Lua builds.
    -- UA: u1 має бути строго > 0 для log().
    local u1 = math.random()
    if u1 < 1e-12 then u1 = 1e-12 end
    local u2 = math.random()

    local mag = math.sqrt(-2.0 * math.log(u1))
    spareGaussian = mag * math.sin(2.0 * math.pi * u2)
    return mag * math.cos(2.0 * math.pi * u2)
end

-- EN: Lazily creates and returns the filter state for a channel.
-- UA: Ліниво створює і повертає стан фільтра каналу.
local function getState(key)
    local s = SignalConditioner.state[key]
    if not s then
        s = { shown = 0.0, noise = 0.0 }
        SignalConditioner.state[key] = s
    end
    return s
end

-- ============================================================================
-- EN: Update — call once per frame with dt in milliseconds.
-- UA: Оновлення — раз на кадр, dt у мілісекундах.
-- ============================================================================
function SignalConditioner.update(dt)
    if not TrainingMode or not TrainingMode.isActive then
        return
    end

    -- EN: Work in seconds. Clamp dt so an alt-tab pause or loading hitch cannot deliver a
    --     multi-second frame that slams every filter straight to its target (which would
    --     look like the bars teleporting) or destabilise the noise integrator.
    -- UA: Працюємо в секундах. Обмежуємо dt, щоб пауза чи підвисання не "телепортували" смуги.
    local dtS = math.max(0.0, math.min((dt or 0) / 1000.0, 0.10))
    if dtS <= 0.0 then return end

    local noiseTau = math.max(0.05, SignalConditioner.noiseTau)
    local lagTau   = math.max(0.05, SignalConditioner.lagTau)
    local sigma    = SignalConditioner.noiseSigma

    -- EN: EXACT Ornstein-Uhlenbeck step, not the small-dt approximation.
    --       n <- n*exp(-dt/tau) + N(0,1)*sigma*sqrt(1 - exp(-2*dt/tau))
    --
    --     The approximate form (1 - dt/tau, with a sqrt(2*dt/tau) diffusion term) is only
    --     valid while dt << tau, and it goes unstable when it is not: noiseTau is settable
    --     down to 0.05 s from rhmTrainingTune while dt is clamped up to 0.10 s, so
    --     `rhmTrainingTune noisetau 0.05` below 20 fps gives a decay of -1.0 — the noise
    --     stops decaying and just flips sign every frame at full amplitude. Same story for
    --     the lag: dt/tau of 2.0 makes the filter overshoot by double the error and ring.
    --
    --     The exponential forms are unconditionally stable — decay is in (0,1) and lagAlpha
    --     in (0,1) for any positive dt and tau — and they make the stationary standard
    --     deviation exactly sigma at every frame rate rather than approximately sigma at
    --     high ones. Same cost, one exp each.
    -- UA: ТОЧНИЙ крок Орнштейна-Уленбека, а не наближення для малих dt. Наближена форма
    --     стає нестабільною, коли dt наближається до tau: noiseTau можна виставити 0.05 с
    --     через rhmTrainingTune, а dt обмежено 0.10 с — тоді decay = -1.0 і шум не згасає,
    --     а лише змінює знак щокадру. Експоненційні форми стабільні за будь-яких dt і tau
    --     і дають стандартне відхилення точно sigma на будь-якій частоті кадрів.
    local decay     = math.exp(-dtS / noiseTau)
    local diffusion = sigma * math.sqrt(1.0 - decay * decay)
    local lagAlpha  = 1.0 - math.exp(-dtS / lagTau)

    for _, def in ipairs(TrainingMode.CHANNELS) do
        local s = getState(def.key)
        local target = TrainingMode.targets[def.key] or def.initial or 0.0

        s.noise = s.noise * decay + gaussian() * diffusion

        -- EN: Chase (target + noise) with a first-order lag.
        -- UA: Наздоганяємо (ціль + шум) фільтром першого порядку.
        local desired = target + s.noise
        s.shown = s.shown + (desired - s.shown) * lagAlpha

        -- EN: Clamp after filtering, never before — clamping the input would bias the noise
        --     distribution asymmetrically at the rails.
        -- UA: Обмежуємо ПІСЛЯ фільтрації — інакше шум зміщується біля країв шкали.
        if s.shown < 0.0 then s.shown = 0.0 elseif s.shown > 1.0 then s.shown = 1.0 end
    end
end

-- EN: Snaps every filter directly to its target with zero noise. Used when entering training
--     mode so the bars appear already settled instead of sweeping up from zero.
-- UA: Миттєво вирівнює фільтри по цілях без шуму — при вході в режим навчання.
function SignalConditioner.snapToTargets()
    if not TrainingMode then return end
    for _, def in ipairs(TrainingMode.CHANNELS) do
        local s = getState(def.key)
        s.shown = TrainingMode.targets[def.key] or def.initial or 0.0
        s.noise = 0.0
    end
end

-- ============================================================================
-- EN: Readers
-- UA: Читачі
-- ============================================================================

-- EN: How the derived TOTAL column combines its two components.
--     "sum" is faithful to the machine: the centre bar is labelled shoe + separator, and on a
--     real post total genuinely reads higher than either component, pinning to the top when
--     both are bad. "mean" is the gentler alternative if a clamped sum turns out to saturate
--     too readily in practice — switchable here rather than hunted for in the renderer.
-- UA: Як обчислюється похідна колонка TOTAL. "sum" відповідає машині (центральна смуга —
--     сума втрат решета і сепаратора, і читається вище за обидві складові). "mean" — м'якший
--     варіант, якщо сума насичуватиметься надто швидко.
SignalConditioner.totalMode = "sum"

-- EN: Scaling applied to the summed total.
--
--     A straight 1:1 sum climbs too fast to be believable: both components at half scale
--     would peg the total, which no real machine does. Deere's own documentation explains
--     why — from the Ready to Harvest handbook, on the area-based algorithm that has been
--     the X/S Series default since MY2022:
--
--       "Area-based loss display algorithm is similar in units of kernels per area. The
--        algorithm considers machine header width, speed, and loss levels."
--
--     So the displayed total is not the arithmetic sum of two sensors; it is a derived
--     per-area figure that folds in width and speed, and it rises more slowly than the raw
--     addition of its parts. 0.70 reproduces that compression without pretending to model
--     an algorithm Deere has not published.
--
--     Consequences worth knowing: both components at 0.5 now read 0.70 rather than pegging,
--     and the total still saturates, but only when both parts are genuinely high.
-- UA: Масштаб суми. Пряма сума 1:1 зростає надто швидко: обидві складові на половині шкали
--     вже виводили б суму на максимум, чого реальна машина не робить. За документацією Deere
--     (Ready to Harvest), площинний алгоритм враховує ширину жатки, швидкість і рівні втрат,
--     тобто показ — не арифметична сума, а похідна величина на одиницю площі, яка зростає
--     повільніше. 0.70 відтворює це стиснення.
SignalConditioner.totalScale = 0.70

-- EN: Continuous conditioned value, 0..1. This is the honest analogue reading.
--     Handles the derived "totalLoss" column transparently, so callers never need to know
--     which columns are sensors and which are computed.
-- UA: Неперервне значення після кондиціонування, 0..1. Похідна колонка "totalLoss"
--     обробляється прозоро — виклику не треба знати, що є датчиком, а що обчисленням.
function SignalConditioner.getValue(key)
    if key == "totalLoss" then
        return SignalConditioner.getTotalLoss()
    end
    local s = SignalConditioner.state[key]
    return s and s.shown or 0.0
end

-- EN: The derived total: cleaning-shoe loss combined with separator loss.
--
--     Summed from the CONDITIONED values, not from the raw targets. That ordering matters —
--     it means the total inherits the noise and lag of both contributing sensors, exactly as
--     a real computed total does, instead of being an unnaturally clean line sitting between
--     two wandering ones. Summing the targets first and conditioning afterwards would give
--     the total its own independent noise, which would let it visibly disagree with its own
--     components moment to moment.
-- UA: Похідна сума: втрати решета + втрати сепаратора.
--     Сумуються КОНДИЦІОНОВАНІ значення, а не сирі цілі — так сума успадковує шум і затримку
--     обох датчиків, як і справжня обчислена сума, замість того щоб бути неприродно чистою
--     лінією між двома блукаючими.
function SignalConditioner.getTotalLoss()
    local shoe = SignalConditioner.state.shoeLoss
    local sep  = SignalConditioner.state.sepLoss
    local a = shoe and shoe.shown or 0.0
    local b = sep  and sep.shown  or 0.0

    local v
    if SignalConditioner.totalMode == "mean" then
        v = (a + b) * 0.5
    else
        v = (a + b) * (SignalConditioner.totalScale or 1.0)
    end

    if v < 0.0 then v = 0.0 elseif v > 1.0 then v = 1.0 end
    return v
end

-- EN: Number of lit segments for a bar column, 0..segments.
--     Values inside the deadband return 0 so a parked-at-zero channel reads as truly dark.
-- UA: Кількість засвічених сегментів, 0..segments. Значення в мертвій зоні дають 0.
function SignalConditioner.getSegments(key)
    local v = SignalConditioner.getValue(key)
    if v < SignalConditioner.deadband then
        return 0
    end

    local n = SignalConditioner.segments
    local lit = math.floor(v * n + 0.5)
    if lit < 1 then lit = 1 end
    if lit > n then lit = n end
    return lit
end

-- EN: Quantised value as a 0..1 fraction — the segment count expressed proportionally.
--     Useful for anything that wants the stepped value without knowing the segment count.
-- UA: Квантоване значення як частка 0..1.
function SignalConditioner.getQuantised(key)
    return SignalConditioner.getSegments(key) / SignalConditioner.segments
end

-- ============================================================================
-- EN: Live tuning console command. Getting noise and lag to feel right is a judgement made
--     while watching the bars, not from a spec sheet, so it must be adjustable in-game.
--       rhmTrainingTune                 → show current values
--       rhmTrainingTune lag 3.5         → set a constant
-- UA: Консольна команда живого налаштування — відчуття шуму та затримки підбирається
--     під час спостереження за смугами, а не за специфікацією.
-- ============================================================================
local TUNABLES = {
    noise    = { field = "noiseSigma", min = 0.0,  max = 0.25, desc = "noise amplitude (fraction of full scale)" },
    noisetau = { field = "noiseTau",   min = 0.05, max = 10.0, desc = "noise correlation time (s)" },
    lag      = { field = "lagTau",     min = 0.05, max = 15.0, desc = "sensor lag time constant (s)" },
    segments = { field = "segments",   min = 4,    max = 40,   desc = "bar segment count", integer = true },
    deadband = { field = "deadband",   min = 0.0,  max = 0.20, desc = "below this the bar reads dark" },
}

function SignalConditioner.consoleCommand(_, arg1, arg2)
    if arg1 == nil or arg1 == "" then
        local out = { "RHM Training signal tuning:" }
        for name, t in pairs(TUNABLES) do
            table.insert(out, string.format("  %-9s = %-6s  (%s)",
                name, tostring(SignalConditioner[t.field]), t.desc))
        end
        table.insert(out, "  usage: rhmTrainingTune <name> <value>")
        return table.concat(out, "\n")
    end

    local t = TUNABLES[tostring(arg1):lower()]
    if not t then
        local names = {}
        for name in pairs(TUNABLES) do table.insert(names, name) end
        table.sort(names)
        return "Unknown setting. Available: " .. table.concat(names, ", ")
    end

    local v = tonumber(arg2)
    if v == nil then
        return string.format("Usage: rhmTrainingTune %s <%.2f-%.2f>", tostring(arg1), t.min, t.max)
    end

    v = math.max(t.min, math.min(t.max, v))
    if t.integer then v = math.floor(v + 0.5) end
    SignalConditioner[t.field] = v

    return string.format("RHM Training: %s = %s", tostring(arg1), tostring(v))
end

function SignalConditioner.registerConsoleCommand()
    if SignalConditioner._consoleRegistered then return end
    SignalConditioner._consoleRegistered = true
    addConsoleCommand("rhmTrainingTune", "Tune RHM training-mode signal noise and lag",
        "consoleCommand", SignalConditioner)
end
