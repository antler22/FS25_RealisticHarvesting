-- Headless harness: loads the real training-mode sources with FS25 globals stubbed,
-- then verifies the claims made in the code comments.
local MOD = "C:/Users/ntjac/Documents/My Games/FarmingSimulator2025/mods/FS25_RealisticHarvesting/"

-- ---- FS25 global stubs ----
g_currentMission = { time = 0 }
Logging = { warning = function() end, error = function() end, info = function() end }
function addConsoleCommand() end

dofile(MOD .. "src/training/TrainingMode.lua")
dofile(MOD .. "src/training/SignalConditioner.lua")
dofile(MOD .. "src/training/TrainingInput.lua")

math.randomseed(20260730)

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-52s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-52s %s", name, detail or "")) end
end

-- EN: Every channel now has its own key pair, so "driving" a channel just means writing
--     its up/down input slots directly. No arming step exists any more.
local function drive(key, up, down)
    TrainingInput._up[key]   = up or 0
    TrainingInput._down[key] = down or 0
end
local function releaseAll()
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do drive(m.channel, 0, 0) end
end

local function mean(t) local s=0 for _,v in ipairs(t) do s=s+v end return s/#t end
local function stdev(t)
    local m=mean(t); local s=0
    for _,v in ipairs(t) do s=s+(v-m)^2 end
    return math.sqrt(s/(#t-1))
end

print("\n=== 1. Noise amplitude must be frame-rate independent ===")
print("(the sqrt(1 - exp(-2*dt/tau)) diffusion term is what guarantees this)")
for _, hz in ipairs({30, 60, 144}) do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.lagTau = 0.05   -- near-zero lag so we observe the noise directly
    SignalConditioner.noiseSigma = 0.03
    SignalConditioner.noiseTau = 0.8
    TrainingMode.setChannel("sepLoss", 0.5)
    SignalConditioner.snapToTargets()

    local dt = 1000/hz
    local samples = {}
    for i = 1, 40000 do
        SignalConditioner.update(dt)
        if i > 2000 then table.insert(samples, SignalConditioner.getValue("sepLoss")) end
    end
    local sd = stdev(samples)
    -- lag tau 0.05 still filters a little, so allow a generous band; the point is that the
    -- three frame rates agree with each other and land near sigma.
    check(string.format("%3d Hz stationary sigma ~= 0.03", hz),
          sd > 0.015 and sd < 0.045, string.format("measured sigma=%.4f mean=%.3f", sd, mean(samples)))
end

print("\n=== 2. Noise is band-limited, not white ===")
print("(consecutive samples must be strongly correlated; white noise would be ~0)")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.lagTau = 0.05
    SignalConditioner.noiseSigma = 0.03
    SignalConditioner.noiseTau = 0.8
    TrainingMode.setChannel("sepLoss", 0.5)
    SignalConditioner.snapToTargets()

    local prev, s = nil, {}
    for i = 1, 20000 do
        SignalConditioner.update(16.667)
        local v = SignalConditioner.getValue("sepLoss")
        if prev and i > 2000 then table.insert(s, {prev, v}) end
        prev = v
    end
    local a, b = {}, {}
    for _, p in ipairs(s) do table.insert(a, p[1]); table.insert(b, p[2]) end
    local ma, mb, sa, sb = mean(a), mean(b), stdev(a), stdev(b)
    local cov = 0
    for _, p in ipairs(s) do cov = cov + (p[1]-ma)*(p[2]-mb) end
    cov = cov / (#s - 1)
    local r = cov / (sa*sb)
    check("lag-1 autocorrelation > 0.9 (temporally correlated)", r > 0.9,
          string.format("r=%.4f", r))
end

print("\n=== 3. Lag time constant behaves as first-order ===")
print("(step response: ~63% at 1 tau, ~95% at 3 tau)")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.noiseSigma = 0.0    -- isolate the lag
    SignalConditioner.lagTau = 2.5
    TrainingMode.setChannel("sepLoss", 0.0)
    SignalConditioner.snapToTargets()
    TrainingMode.setChannel("sepLoss", 1.0)   -- unit step

    local dt, elapsed = 16.667, 0
    local at1, at3 = nil, nil
    while elapsed < 3*2.5*1000 + dt do
        SignalConditioner.update(dt); elapsed = elapsed + dt
        if at1 == nil and elapsed >= 2.5*1000 then at1 = SignalConditioner.getValue("sepLoss") end
        if at3 == nil and elapsed >= 3*2.5*1000 then at3 = SignalConditioner.getValue("sepLoss") end
    end
    check("response at 1*tau is ~0.63", at1 > 0.60 and at1 < 0.66, string.format("%.4f", at1))
    check("response at 3*tau is ~0.95", at3 > 0.93 and at3 < 0.97, string.format("%.4f", at3))
end

print("\n=== 4. Lag is frame-rate independent ===")
do
    local results = {}
    for _, hz in ipairs({30, 60, 144}) do
        TrainingMode.setActive(false); TrainingMode.setActive(true)
        SignalConditioner.noiseSigma = 0.0
        SignalConditioner.lagTau = 2.5
        TrainingMode.setChannel("sepLoss", 0.0)
        SignalConditioner.snapToTargets()
        TrainingMode.setChannel("sepLoss", 1.0)
        local dt, elapsed = 1000/hz, 0
        while elapsed < 2500 do SignalConditioner.update(dt); elapsed = elapsed + dt end
        results[hz] = SignalConditioner.getValue("sepLoss")
    end
    local spread = math.max(results[30], results[60], results[144])
                 - math.min(results[30], results[60], results[144])
    check("step response after 2.5s agrees across 30/60/144 Hz", spread < 0.01,
          string.format("30Hz=%.4f 60Hz=%.4f 144Hz=%.4f spread=%.4f",
              results[30], results[60], results[144], spread))
end

print("\n=== 5. Input ramp is frame-rate independent ===")
do
    local results = {}
    for _, hz in ipairs({30, 60, 144}) do
        TrainingMode.setActive(false); TrainingMode.setActive(true)
        TrainingMode.setChannel("sepLoss", 0.0)
        local dt, elapsed = 1000/hz, 0
        while elapsed < 1000 do
            drive("sepLoss", 1, 0)
            TrainingInput.update(dt); elapsed = elapsed + dt
        end
        results[hz] = TrainingMode.getChannel("sepLoss")
    end
    local spread = math.max(results[30], results[60], results[144])
                 - math.min(results[30], results[60], results[144])
    check("1s of held key gives same travel at all frame rates", spread < 0.02,
          string.format("30Hz=%.4f 60Hz=%.4f 144Hz=%.4f (expect ~%.2f)",
              results[30], results[60], results[144], TrainingInput.RAMP_PER_SEC))
end

print("\n=== 6. Clamping, cycling, quantisation ===")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    TrainingMode.setChannel("sepLoss", 0.9)
    for _ = 1, 500 do drive("sepLoss", 1, 0); TrainingInput.update(16.667) end
    check("channel clamps at 1.0", TrainingMode.getChannel("sepLoss") == 1.0,
          string.format("%.4f", TrainingMode.getChannel("sepLoss")))

    for _ = 1, 900 do drive("sepLoss", 0, 1); TrainingInput.update(16.667) end
    check("channel clamps at 0.0", TrainingMode.getChannel("sepLoss") == 0.0,
          string.format("%.4f", TrainingMode.getChannel("sepLoss")))

    drive("sepLoss", 1, 1)
    local before = TrainingMode.getChannel("sepLoss")
    TrainingInput.update(16.667)
    check("holding up+down cancels out", TrainingMode.getChannel("sepLoss") == before)

    -- EN: adjustArmed must touch ONLY the armed channel. This is what the stale-index
    -- failure above accidentally proved; assert it deliberately.
    releaseAll()
    TrainingMode.setChannel("shoeLoss", 0.4)
    TrainingMode.setChannel("sepLoss",  0.4)
    TrainingMode.setChannel("tailings", 0.4)
    drive("shoeLoss", 1, 0)
    for _ = 1, 60 do TrainingInput.update(16.667) end
    check("driving one channel leaves the others untouched",
          TrainingMode.getChannel("shoeLoss") > 0.4
          and TrainingMode.getChannel("sepLoss")  == 0.4
          and TrainingMode.getChannel("tailings") == 0.4,
          string.format("shoe=%.3f sep=%.3f tail=%.3f",
              TrainingMode.getChannel("shoeLoss"), TrainingMode.getChannel("sepLoss"),
              TrainingMode.getChannel("tailings")))


    SignalConditioner.noiseSigma = 0.0
    SignalConditioner.segments = 14
    TrainingMode.setChannel("shoeLoss", 1.0); SignalConditioner.snapToTargets()
    check("full scale lights every segment", SignalConditioner.getSegments("shoeLoss") == 14,
          tostring(SignalConditioner.getSegments("shoeLoss")))
    TrainingMode.setChannel("shoeLoss", 0.0); SignalConditioner.snapToTargets()
    check("zero lights no segments (deadband)", SignalConditioner.getSegments("shoeLoss") == 0,
          tostring(SignalConditioner.getSegments("shoeLoss")))
    TrainingMode.setChannel("shoeLoss", 0.5); SignalConditioner.snapToTargets()
    check("half scale lights ~half the segments", SignalConditioner.getSegments("shoeLoss") == 7,
          tostring(SignalConditioner.getSegments("shoeLoss")))
end

print("\n=== 7. dt clamp survives a loading hitch ===")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.noiseSigma = 0.03
    SignalConditioner.lagTau = 2.5
    TrainingMode.setChannel("sepLoss", 0.0); SignalConditioner.snapToTargets()
    TrainingMode.setChannel("sepLoss", 1.0)
    SignalConditioner.update(5000)   -- 5-second frame, as after an alt-tab
    local v = SignalConditioner.getValue("sepLoss")
    check("5s frame does not teleport the bar to target", v < 0.10,
          string.format("value after hitch=%.4f (dt clamped to 0.10s)", v))
    check("value stays finite and in range", v == v and v >= 0 and v <= 1, string.format("%.4f", v))
end

print("\n=== 8. Inactive mode does nothing ===")
do
    TrainingMode.setActive(false)
    TrainingMode.targets.sepLoss = 0.5
    local before = SignalConditioner.getValue("sepLoss")
    for _ = 1, 100 do SignalConditioner.update(16.667) end
    check("conditioner is inert while mode is off",
          SignalConditioner.getValue("sepLoss") == before)
    drive("sepLoss", 1, 0)
    local t = TrainingMode.getChannel("sepLoss")
    TrainingInput.update(16.667)
    check("input is inert while mode is off", TrainingMode.getChannel("sepLoss") == t)
end


print("\n=== 9. Derived TOTAL column ===")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.noiseSigma = 0.0
    SignalConditioner.totalMode = "sum"

    -- EN: The total is a SCALED sum, not a 1:1 one. A straight addition climbs too fast to
    --     be believable — both components at half scale would peg it, which no real machine
    --     does. Deere's area-based algorithm folds in header width and speed and rises more
    --     slowly than the raw addition of its parts; totalScale reproduces that compression.
    local SC = SignalConditioner.totalScale
    check("totalScale is applied, not a 1:1 sum", SC ~= nil and SC < 1.0,
          string.format("totalScale=%s", tostring(SC)))

    TrainingMode.setChannel("shoeLoss", 0.30)
    TrainingMode.setChannel("sepLoss",  0.20)
    SignalConditioner.snapToTargets()
    check("total = (shoe + separator) * totalScale",
          math.abs(SignalConditioner.getTotalLoss() - 0.50 * SC) < 1e-9,
          string.format("shoe=0.30 sep=0.20 -> total=%.4f (expect %.4f)",
              SignalConditioner.getTotalLoss(), 0.50 * SC))

    -- EN: The compression must be visible where it matters: both halves at 0.5 used to peg
    --     the total at full scale, which was the complaint. It must not any more.
    TrainingMode.setChannel("shoeLoss", 0.5)
    TrainingMode.setChannel("sepLoss",  0.5)
    SignalConditioner.snapToTargets()
    check("both components at half scale no longer peg the total",
          SignalConditioner.getTotalLoss() < 0.95,
          string.format("%.4f", SignalConditioner.getTotalLoss()))

    TrainingMode.setChannel("shoeLoss", 0.80)
    TrainingMode.setChannel("sepLoss",  0.70)
    SignalConditioner.snapToTargets()
    check("total clamps at 1.0 when both are high", SignalConditioner.getTotalLoss() == 1.0,
          string.format("%.4f", SignalConditioner.getTotalLoss()))

    TrainingMode.setChannel("shoeLoss", 0.0)
    TrainingMode.setChannel("sepLoss",  0.0)
    SignalConditioner.snapToTargets()
    check("total is zero when both components are zero",
          SignalConditioner.getTotalLoss() == 0.0)

    check("getValue routes 'totalLoss' to the derived path",
          SignalConditioner.getValue("totalLoss") == SignalConditioner.getTotalLoss())

    SignalConditioner.segments = 14
    TrainingMode.setChannel("shoeLoss", 1.0)
    TrainingMode.setChannel("sepLoss",  1.0)
    SignalConditioner.snapToTargets()
    check("derived column still saturates when both parts are maxed",
          SignalConditioner.getSegments("totalLoss") == 14,
          tostring(SignalConditioner.getSegments("totalLoss")))

    -- mean mode. Sets its own inputs rather than inheriting whatever the previous check
    -- left behind — that coupling is exactly what made this fail when the test above it
    -- changed its values.
    SignalConditioner.totalMode = "mean"
    TrainingMode.setChannel("shoeLoss", 0.4)
    TrainingMode.setChannel("sepLoss",  0.6)
    SignalConditioner.snapToTargets()
    check("mean mode averages instead of summing, and ignores totalScale",
          math.abs(SignalConditioner.getTotalLoss() - 0.5) < 1e-9,
          string.format("%.4f", SignalConditioner.getTotalLoss()))
    SignalConditioner.totalMode = "sum"
end

print("\n=== 10. Total inherits component noise (not independently noisy) ===")
print("(summing CONDITIONED values means total must track shoe+sep exactly, every frame)")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    SignalConditioner.noiseSigma = 0.03
    SignalConditioner.lagTau = 2.5
    SignalConditioner.totalMode = "sum"
    TrainingMode.setChannel("shoeLoss", 0.25)
    TrainingMode.setChannel("sepLoss",  0.25)
    SignalConditioner.snapToTargets()

    local worst = 0
    for _ = 1, 5000 do
        SignalConditioner.update(16.667)
        local expect = (SignalConditioner.getValue("shoeLoss")
                      + SignalConditioner.getValue("sepLoss")) * SignalConditioner.totalScale
        if expect > 1 then expect = 1 end
        worst = math.max(worst, math.abs(SignalConditioner.getTotalLoss() - expect))
    end
    check("total tracks the scaled conditioned sum every frame", worst < 1e-12,
          string.format("max deviation=%.3e", worst))
end


print("\n=== 11. Simultaneous multi-channel control ===")
print("(the whole point of dedicated key pairs: two fingers, two columns, at once)")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        TrainingInput._up[m.channel], TrainingInput._down[m.channel] = 0, 0
    end
    TrainingMode.setChannel("shoeLoss", 0.5)
    TrainingMode.setChannel("sepLoss",  0.5)
    TrainingMode.setChannel("tailings", 0.5)

    -- shoe up and tailings down at the same time, separator untouched
    TrainingInput._up["shoeLoss"]   = 1
    TrainingInput._down["tailings"] = 1
    for _ = 1, 30 do TrainingInput.update(16.667) end

    check("shoe rose while tailings fell, in the same frames",
          TrainingMode.getChannel("shoeLoss") > 0.5 and TrainingMode.getChannel("tailings") < 0.5,
          string.format("shoe=%.3f tail=%.3f", TrainingMode.getChannel("shoeLoss"),
              TrainingMode.getChannel("tailings")))
    check("untouched channel stayed exactly put",
          TrainingMode.getChannel("sepLoss") == 0.5,
          string.format("sep=%.3f", TrainingMode.getChannel("sepLoss")))

    -- all three at once
    TrainingInput._up["shoeLoss"]  = 1
    TrainingInput._up["sepLoss"]   = 1
    TrainingInput._up["tailings"]  = 1
    TrainingInput._down["tailings"] = 0
    local a, b, c = TrainingMode.getChannel("shoeLoss"), TrainingMode.getChannel("sepLoss"),
                    TrainingMode.getChannel("tailings")
    for _ = 1, 30 do TrainingInput.update(16.667) end
    check("all three channels move together",
          TrainingMode.getChannel("shoeLoss") > a and TrainingMode.getChannel("sepLoss") > b
          and TrainingMode.getChannel("tailings") > c)

    -- equal travel: three keys held the same time must move the same distance
    TrainingMode.setChannel("shoeLoss", 0.2)
    TrainingMode.setChannel("sepLoss",  0.2)
    TrainingMode.setChannel("tailings", 0.2)
    for _ = 1, 30 do TrainingInput.update(16.667) end
    local d1 = TrainingMode.getChannel("shoeLoss")
    local d2 = TrainingMode.getChannel("sepLoss")
    local d3 = TrainingMode.getChannel("tailings")
    check("simultaneous channels travel at identical rates",
          math.abs(d1-d2) < 1e-9 and math.abs(d2-d3) < 1e-9,
          string.format("%.5f / %.5f / %.5f", d1, d2, d3))
end

print("\n=== 12. Activity highlight ===")
do
    TrainingMode.setActive(false); TrainingMode.setActive(true)
    g_currentMission.time = 100000
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        TrainingInput._up[m.channel], TrainingInput._down[m.channel] = 0, 0
    end
    TrainingMode.activity = {}
    check("nothing is active before any input",
          not TrainingMode.isChannelActive("shoeLoss"))

    TrainingInput._up["shoeLoss"] = 1
    TrainingInput.update(16.667)
    check("moved channel reports active", TrainingMode.isChannelActive("shoeLoss"))
    check("untouched channel does not", not TrainingMode.isChannelActive("sepLoss"))

    TrainingInput._up["shoeLoss"] = 0
    g_currentMission.time = 100000 + TrainingMode.ACTIVITY_HOLD_MS + 50
    check("highlight expires after the hold window",
          not TrainingMode.isChannelActive("shoeLoss"))
end

-- The filters have to stay stable when the time constants approach the frame time, not just
-- when they are comfortably larger than it. This is reachable in normal use: rhmTrainingTune
-- accepts a tau down to 0.05s while dt is clamped up to 0.10s, so a slow frame with a short
-- tau puts dt/tau at 2.0. The old small-dt forms gave a decay of -1.0 there — noise that
-- never settles and just flips sign every frame — and a lag alpha of 2.0, which overshoots
-- by double the error and rings. The exponential forms cannot do either.
print("\n=== 13. Filters stay stable when tau approaches dt ===")
do
    local savedNoiseTau, savedLagTau = SignalConditioner.noiseTau, SignalConditioner.lagTau
    local savedSigma = SignalConditioner.noiseSigma

    TrainingMode.setActive(true)
    SignalConditioner.noiseTau   = 0.05      -- the minimum rhmTrainingTune allows
    SignalConditioner.lagTau     = 0.05
    SignalConditioner.noiseSigma = 0.03
    SignalConditioner.snapToTargets()

    TrainingMode.targets["shoeLoss"] = 0.5

    -- 100ms frames: dt/tau = 2.0, well past where the approximation breaks.
    local worst, diverged = 0, false
    for _ = 1, 600 do
        SignalConditioner.update(100)
        local v = SignalConditioner.getValue("shoeLoss")
        if v ~= v then diverged = true end                 -- NaN
        local n = SignalConditioner.state.shoeLoss.noise
        if math.abs(n) > worst then worst = math.abs(n) end
        if math.abs(n) > 1.0 then diverged = true end
    end

    check("noise never blows up at dt/tau = 2", not diverged,
        string.format("worst |noise| = %.4f", worst))

    -- With tau far below the frame time the filter should be essentially settled on target,
    -- never past it. Overshoot here is the ringing signature of an alpha above 1.
    local shown = SignalConditioner.state.shoeLoss.shown
    check("lag settles on target instead of ringing past it",
        shown >= 0.0 and shown <= 1.0 and math.abs(shown - 0.5) < 0.25,
        string.format("shown = %.4f, target 0.5", shown))

    -- And the stationary spread must still be sigma, which is the property the exact form
    -- buys us: the approximation only got this right while dt was much smaller than tau.
    SignalConditioner.noiseTau = 0.8
    SignalConditioner.snapToTargets()
    local sum, sumsq, n = 0, 0, 0
    for _ = 1, 20000 do
        SignalConditioner.update(100)
        local x = SignalConditioner.state.shoeLoss.noise
        sum, sumsq, n = sum + x, sumsq + x * x, n + 1
    end
    local sd = math.sqrt(sumsq / n - (sum / n) ^ 2)
    check("stationary sigma holds at a coarse 100ms step",
        math.abs(sd - 0.03) < 0.006, string.format("sd = %.4f, want 0.030", sd))

    SignalConditioner.noiseTau   = savedNoiseTau
    SignalConditioner.lagTau     = savedLagTau
    SignalConditioner.noiseSigma = savedSigma
    SignalConditioner.snapToTargets()
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
