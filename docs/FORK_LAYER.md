# Fork layer

This tree is upstream (`exekx/FS25_RealisticHarvesting`) plus a thin layer that carries the fork's
preferences. The layer is designed so that **upstream's Lua files are not edited**. The only upstream
files touched are `src/main.lua` (one `source()` block), `modDesc.xml` (training actions and bindings)
and `translations/l10n_*.xml` (strings appended at the end).

Everything the fork adds lives in: `src/fork/`, `src/training/`, `src/hud/CornerPostHUD.lua`,
`cropThroughput.xml`, `tests/`, `tools/`, `textures/` (corner-post icons) and this file.

## What the layer does

| Piece | Files | What it carries |
|---|---|---|
| Real throughput | `src/fork/RealThroughput*.lua`, `cropThroughput.xml` | Per-crop, per-horsepower capacity from real-world anchors (AEM class data), applied through upstream's own energy model. Every crop upstream knows has an anchor |
| Moisture model | `src/fork/MoistureModel.lua`, `<moistureSettings>` in `cropThroughput.xml` | The fork's per-crop target/max moisture and its load, loss and speed effects, replacing upstream's |
| Work width | `src/fork/WorkWidth.lua` | Manual working width for forage / pickup headers: yield and work rate from distance x width. Saved with the game and synced in multiplayer |
| Electronics tiers | `src/fork/ElectronicsTiers.lua` | The fork's five-tier "Harvest Technology" shop ladder with daily upkeep, feeding upstream's gates |
| Defaults | `src/fork/Defaults.lua` | Target engine load 95 % (upstream: 80 %) |
| Training mode | `src/training/*`, `src/fork/TrainingBridge.lua` | Instructor-driven loss channels; loss physics is sandboxed while active |
| Corner Post HUD | `src/hud/CornerPostHUD.lua` | Training display; replaces the normal HUD while training is on |
| Hook installer | `src/fork/SpecHooks.lua` | Puts the hooks on `rhm_Combine` where they survive (see below) |

### The rule for hooks on `rhm_Combine`

Upstream's `main.lua` sources `src/rhm_Combine.lua`, whose first line is an unconditional `rhm_Combine = {}`.
The file is **also** listed in `modDesc.xml`'s `<specializations>`, and the engine sources it again when it
registers the specialization (`mods.lua:998-1005` -> `SpecializationManager.lua:97`), then resolves the class
from that second load. Anything installed only on the first table is discarded. (`rhm_Cutter` behaves the same;
upstream's other classes are sourced once.)

So fork code **never wraps `rhm_Combine` directly at load time**. It registers a hook with
`ForkSpecHooks.add(...)`; the installer applies them when the fork layer loads and again right after the engine
registers the `rhm_Combine` specialization - after the second load and before the engine reads the class's
functions (`TypeManager:finalizeTypes`). `tests/bridgetest.lua` section 11 simulates the replacement.

### Electronics tiers

| Tier | Name | Price | Upkeep | Upstream package level | Effect |
|---|---|---|---|---|---|
| 0 | No upgrades | $0 | $0/day | 1 | nothing |
| 1 | Loss Catch Pan | $2,500 | $8/day | 2 | loss readout (not the optimal-setting hints - held back) |
| 2 | Settings Monitoring | $7,500 | $21/day | 2 | + optimal band, status pills, preset buttons |
| 3 | Speed Automation | $17,500 | $167/day | 3 | + automatic speed control (below this, upstream's speed enforcement is held off) + stats panel |
| 4 | Full Automation | $37,500 | $417/day | 4 | + AUTO mode, live trim, Opti-Harvest |

Forage harvesters call tier 1 "Chop Quality Monitoring". Config ids are `"0"`..`"4"` under the type
`rhm_upgradeTier`, the same as the fork, so saves made on the fork keep their tiers. Upstream's own
`rhmPackage` list is removed from combines in the shop. Known cosmetic mismatch: the calibration terminal
header and upstream's tutorial text still use upstream's wording ("TIER 2 - SENSORS"), which follows the
package level above, not the fork's tier names.

### Moisture model

Per crop a `target` and a `max` moisture (`<moistureSettings>` in `cropThroughput.xml`; wheat 13.5 / 22,
corn 15.5 / 35, ...). Nothing happens within 1.5 points above target; then three effects ramp to `max`:
load x1.30, loss x2.00 (on a ^1.5 curve), speed cap -35 %. A crop drier than target gets a small (<= 5 %)
bonus. The factors are absolute multipliers. Grain machines only; the player's "Moisture simulation"
setting is the master switch.

Upstream's own moisture handling (a flat 14 % default, a per-percent penalty, a halved penalty at package
level 4, a rain surcharge) is switched off for the duration of the two calculations that contain it, using
its own `settings.enableMoisture`, and the fork's factors are applied at the matching points. Crops with no
entry fall back to wheat's thresholds. **Not carried over:** moisture colouring on the cab HUD, which
upstream draws inline with fixed bands (blue to 14 %, amber to 20 %, red above).

### Work width

`rhmWorkWidth <metres | 48ft | auto>`, or the "Working Width" row under the calibration terminal (Shift+K):
`-` / `+` in 0.5 m or 1 ft steps, `-` at the first step returns to Auto, cap 50 m. While a width is set, the
area credited each frame is *distance travelled x width* instead of the engine's pixel count, which fixes
yield, hectares per hour and the trip odometer on pickup headers whose reported work area is much narrower
than the swath. Kept in `combineMemory.swathWidth` like the fork. Unlike the fork it is saved with the game
and synchronised in multiplayer.

### Ground-speed header loss

`loss % = (speed - 9.65 km/h) ^ 1.35 x 0.28 x cropFactor`, capped at 8 %, grain machines only (canola 2.0,
soybean 1.8, pea 1.7 ... wheat 1.0, corn 0.25; factors for crops added by the port are judgment calls). It is
added to upstream's total (still capped at 50 %) and to its "speed" bucket, so the breakdown, tracker and
analytics report it as speed loss, and since upstream removes grain by the total, it is physical. Same gating
as upstream's loss (off with crop loss disabled or Arcade loss difficulty) and off in Training mode.

### Rotor plugging

Engine load of 110 % or more held for 10 s plugs the rotor: the machine is held to 1 km/h for 12 s at any
electronics tier (through the vehicle's `getSpeedLimit`, so a driver, cruise control and a hired worker are all
held). "Plug risk" warns at 5 s; dropping below 110 % resets the timer. The server runs the clock and tells
clients by a small event; players joining mid-plug get the state appended to upstream's initial stream. Off in
Training mode.

### Anchors added for the rest of upstream's crop list

`cropThroughput.xml` defines unanchored crops relative to anchored ones, for example
`<crop name="rye" like="wheat" factor="0.90" />`. These are judgment calls tied to relationships already in
the table, not measurements; the reasoning is next to each entry. `tests/throughputtest.lua` reads upstream's
own crop registry, so a crop upstream adds later fails that test until it is given an anchor, and
`tests/moisturetest.lua` fails if an anchored crop has no moisture thresholds.

## Upstream symbols the layer depends on

If upstream renames or removes one of these, the matching hook logs
`[RHM-fork] ... not found` at startup and that feature goes quiet. The base mod keeps working.

| Symbol (upstream v1.6.4.0) | Used by | Why |
|---|---|---|
| `RHM_LoadCalculator:getCropSpecificEnergy` | RealThroughput, MoistureModel | The capacity seam (specific energy, HP per t/h); moisture load factor multiplies it |
| `RHM_LoadCalculator:calculateEngineLoad` | RealThroughput, MoistureModel | Supplies the vehicle (the seam has no vehicle argument) and `self.headerHp`; scope for holding upstream's moisture off |
| `RHM_LoadCalculator:getEnginePowerHp` | RealThroughput | Advertised horsepower for the curve |
| `P_base` fractions in `calculateEngineLoad` (0.08 / 0.095 / 0.11, forage 0.09, root 0.10) | `RealThroughput.baseLossFraction` | **Mirrored by hand.** The derived energy is only exact if both sides use the same fractions - re-check after each upstream merge |
| `RHM_LoadCalculator:calculateTotalCropLoss` | TrainingBridge, MoistureModel | The single seam for all loss physics; reads `self.settingsAddedLoss` |
| `RHM_LoadCalculator:calculateSpeedLimit` (sets `self.speedLimit`, `maxWorkingSpeed`, `genuineSpeedLimit`) | MoistureModel | Speed-cap effect |
| `settings.enableMoisture` (read only inside the two calculations above) | MoistureModel | Switched off around them |
| `RHM_CombineSettingsDatabase:applyEnvironmentalOffsets` (reads `baseTemplate.moistureLimit`) | MoistureModel | Optimum shift measured from the crop's target |
| `RHM_Api.getMoistureLimit` | MoistureModel | Reports the target |
| `RHM_CombineSettingsDatabase.crops` registry | `tests/throughputtest.lua` | Coverage test: every crop upstream registers must have an anchor |
| `RHM_CombineMemory.new` | Defaults | Sets the 95 % target load on a new machine |
| `ConfigurationUtil.getConfigurationsFromXML` and upstream's `rhmPackage` injection in `RHM_Configuration.lua` | ElectronicsTiers | Shop ladder; the presence of `rhmPackage` is the "this is a combine" signal |
| `rhm_Combine:onLoad` reading `self.configurations["rhmPackage"]` into `spec.packageLevel` | ElectronicsTiers | Feeds upstream's gates the mapped level |
| `rhm_Combine:getSpeedLimit` and `onUpdateTick`, and the global `settings.enableSpeedLimit` switch they check | ElectronicsTiers | Tier-3 speed gate |
| `rhm_Combine:onUpdateTick` reading `spec.lastRawArea`; `spec.lastLiters`, `_fallbackLiters`, `lastMultiplier`; `vehicle.lastMovedDistance` | WorkWidth | Area rule |
| `rhm_Combine.registerXMLPaths`, `saveToXMLFile`, `loadFromSavegame`, `onWriteStream`, `onReadStream` | WorkWidth | Persistence and initial sync |
| `RHMCombineCalibrationGUI:draw`, `drawButton`, `drawRect`, `drawBorder`, `self.buttons`, `self.activeVehicle`, `self.ui` | WorkWidth | The row under the terminal |
| `RHMCombineCalibrationGUI:drawParameterRow(..., packageLevel, ...)` | ElectronicsTiers | Tier-1 hint hold-back |
| `RHM_RealisticHarvestManager` `new` / `update` / `draw` / `mouseEvent` / `delete` / `getControlledVehicle` / `lastActiveCombine` / `lastControlledVehicle` / `isCursorVisible` | TrainingBridge, RealThroughput, ElectronicsTiers, WorkWidth | Lifecycle and Training's inputs |
| `RHMDraggableHUD:draw` | TrainingBridge | Suppressed while training |
| `rhm_Combine:onRegisterActionEvents`, `spec.isRhmCombine`, `spec.actionEvents` | TrainingBridge | Instructor keys |
| `spec.data.load / yield / tonPerHour / moisture`, `spec.combineMemory.currentSettings / currentCrop / machineType` | TelemetryProvider, MoistureModel | Corner-post readouts; moisture reading |
| `RHM_UnitConverter.getActiveSystem`, `getPhysicalRange` | WorkWidth, CornerPostHUD | Units; decimal places (optional) |
| `RHM_LoadCalculator:calculateTotalCropLoss` (also `baseLoss` = the "speed" bucket, `overloadLoss`, `totalLoss`, `totalCropLoss`, `cropLoss`) | HeaderLoss | Adds ground-speed loss to the total and to the speed bucket |
| `loadCalculator.engineLoad` (ratio, 1.0 = 100 %) and `rhm_Combine:getSpeedLimit` / `onUpdateTick` / `onWriteStream` / `onReadStream` | RotorPlug | Overload clock, the 1 km/h stop, join sync |
| `SpecializationManager.addSpecialization` (engine) | SpecHooks | The trigger for re-hooking `rhm_Combine` |

## Taking a new upstream release

```
git fetch upstream
git merge upstream/main          # conflicts, if any, should be limited to main.lua, modDesc.xml, translations/
powershell -File tools/run_tests.ps1
```

Then start the game once and search the log for `RHM-fork`. Any `not found` line names the symbol that
moved. Re-read the `P_base` block in `RHM_LoadCalculator:calculateEngineLoad` and compare it with
`RealThroughput.baseLossFraction`, and check that upstream's `rhm_Combine.lua` still starts with
`rhm_Combine = {}` (the installer copes either way). A crop upstream added shows up as a failure in
`throughputtest.lua` section 13.

## In-game switches

* `rhmRealThroughput on|off|status|reload` - compare the fork's anchors against upstream's native constants on the same machine and crop. `reload` also re-reads the moisture block.
* `rhmThroughputTable [hp]` - rated throughput of every anchored crop at a horsepower.
* `rhmTier` - electronics tier of the machine you are in, the package level upstream sees, and whether speed automation is available.
* `rhmWorkWidth <metres | 48ft | auto>` - manual working width of the machine you are in.
* `rhmHeaderLoss [on|off|status]` - ground-speed header loss; status shows the active machine's current loss.
* `rhmPlugging [on|off|status]` - rotor plugging; status shows the active machine's state and overload timer.
* `rhmTraining`, `rhmTrainingTune`, `rhmTrainingDebug`, `rhmPostScale`, `rhmPost*` - Training mode and Corner Post (unchanged from the fork).

## What is deliberately not here

* The fork's in-game "purchase an upgrade" function (`CombineMemory:purchaseUpgrade`): it had no caller in the fork; the shop was the only way to buy a tier.
* The fork's own speed controller and feederhouse ramp, live optimal settings, hired-worker tiers and Tier-4 auto-trim: upstream v1.6.x has equivalents, all keyed to the package level that the tiers above feed.
* Upstream's threshing behaviour is kept as is: a combine starts threshing with no header attached, and a full tank does not lift, fold or stop the header. (Vanilla differs on both; this is intentional.)
* The plugged-rotor icon on the fork's HUD and the plug count in its session report: upstream's HUD and tracker have no place for them; the on-screen warnings carry the information.
