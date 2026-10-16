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
| Electronics tiers | `src/fork/ElectronicsTiers.lua` | The fork's five-tier "Harvest Technology" shop ladder with daily upkeep, feeding upstream's gates |
| Defaults | `src/fork/Defaults.lua` | Target engine load 95 % (upstream: 80 %) |
| Training mode | `src/training/*`, `src/fork/TrainingBridge.lua` | Instructor-driven loss channels; loss physics is sandboxed while active |
| Corner Post HUD | `src/hud/CornerPostHUD.lua` | Training display; replaces the normal HUD while training is on |

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

### Anchors added for the rest of upstream's crop list

`cropThroughput.xml` now defines unanchored crops relative to anchored ones, for example
`<crop name="rye" like="wheat" factor="0.90" />`. These are judgment calls tied to relationships already in
the table, not measurements; the reasoning is next to each entry. `tests/throughputtest.lua` reads upstream's
own crop registry, so a crop upstream adds later fails that test until it is given an anchor.

## Upstream symbols the layer depends on

If upstream renames or removes one of these, the matching hook logs
`[RHM-fork] ... not found - hook skipped` at startup and that feature goes quiet. The base mod keeps working.

| Symbol (upstream v1.6.4.0) | Used by | Why |
|---|---|---|
| `RHM_LoadCalculator:getCropSpecificEnergy` | RealThroughput | The capacity seam: specific energy, HP per t/h |
| `RHM_LoadCalculator:calculateEngineLoad` | RealThroughput | Supplies the vehicle (the seam has no vehicle argument) and `self.headerHp` |
| `RHM_LoadCalculator:getEnginePowerHp` | RealThroughput | Advertised horsepower for the curve |
| `P_base` fractions in `calculateEngineLoad` (0.08 / 0.095 / 0.11, forage 0.09, root 0.10) | `RealThroughput.baseLossFraction` | **Mirrored by hand.** The derived energy is only exact if both sides use the same fractions - re-check after each upstream merge |
| `RHM_CombineSettingsDatabase.crops` registry | `tests/throughputtest.lua` | Coverage test: every crop upstream registers must have an anchor |
| `RHM_CombineMemory.new` | Defaults | Sets the 95 % target load on a new machine |
| `ConfigurationUtil.getConfigurationsFromXML` and upstream's `rhmPackage` injection in `RHM_Configuration.lua` | ElectronicsTiers | Shop ladder; the presence of `rhmPackage` is the "this is a combine" signal |
| `rhm_Combine:onLoad` reading `self.configurations["rhmPackage"]` into `spec.packageLevel` | ElectronicsTiers | Feeds upstream's gates the mapped level |
| `rhm_Combine:getSpeedLimit` and `onUpdateTick`, and the global `settings.enableSpeedLimit` switch they check | ElectronicsTiers | Tier-3 speed gate |
| `RHMCombineCalibrationGUI:drawParameterRow(..., packageLevel, ...)` | ElectronicsTiers | Tier-1 hint hold-back |
| `RHM_LoadCalculator:calculateTotalCropLoss` | TrainingBridge | The single seam for all loss physics |
| `RHM_RealisticHarvestManager` `new` / `update` / `draw` / `mouseEvent` / `delete` / `getControlledVehicle` / `lastActiveCombine` / `lastControlledVehicle` / `isCursorVisible` | TrainingBridge, RealThroughput, ElectronicsTiers | Lifecycle and Training's inputs |
| `RHMDraggableHUD:draw` | TrainingBridge | Suppressed while training |
| `rhm_Combine:onRegisterActionEvents`, `spec.isRhmCombine`, `spec.actionEvents` | TrainingBridge | Instructor keys |
| `spec.data.load / yield / tonPerHour / moisture`, `spec.combineMemory.currentSettings / currentCrop / machineType` | TelemetryProvider | Corner-post readouts |
| `RHM_UnitConverter.getPhysicalRange` | CornerPostHUD | Decimal places for setting readouts (optional) |

## Taking a new upstream release

```
git fetch upstream
git merge upstream/main          # conflicts, if any, should be limited to main.lua, modDesc.xml, translations/
powershell -File tools/run_tests.ps1
```

Then start the game once and search the log for `RHM-fork`. Any `not found - hook skipped` line names the
symbol that moved. Finally, re-read the `P_base` block in `RHM_LoadCalculator:calculateEngineLoad` and
compare it with `RealThroughput.baseLossFraction`, and run the tests: a crop upstream added shows up as a
failure in `throughputtest.lua` section 13.

## In-game switches

* `rhmRealThroughput on|off|status|reload` - compare the fork's anchors against upstream's native constants on the same machine and crop.
* `rhmThroughputTable [hp]` - rated throughput of every anchored crop at a horsepower.
* `rhmTier` - electronics tier of the machine you are in, the package level upstream sees, and whether speed automation is available.
* `rhmTraining`, `rhmTrainingTune`, `rhmTrainingDebug`, `rhmPostScale`, `rhmPost*` - Training mode and Corner Post (unchanged from the fork).

## What is deliberately not here

* The fork's in-game "purchase an upgrade" function (`CombineMemory:purchaseUpgrade`): it had no caller in the fork; the shop was the only way to buy a tier.
* The fork's own speed controller and feederhouse ramp, live optimal settings, hired-worker tiers and Tier-4 auto-trim: upstream v1.6.x has equivalents, all keyed to the package level that the tiers above feed.
* The fork's moisture calculator: upstream has its own moisture model. The `<moistureSettings>` block in `cropThroughput.xml` is read by nothing on this branch.
* Rotor-plugging and the other fork-only loss behaviours. See the commit history of `snapshot/pre-port-2026-10-16`.
