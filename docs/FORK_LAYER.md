# Fork layer

This tree is upstream (`exekx/FS25_RealisticHarvesting`) plus a thin layer that carries the fork's
preferences. The layer is designed so that **upstream's Lua files are not edited**; the only upstream
files touched are `src/main.lua` (one `source()` line), `modDesc.xml` (training actions/bindings) and
`translations/l10n_*.xml` (eight input strings, appended).

Everything the fork adds lives in: `src/fork/`, `src/training/`, `src/hud/CornerPostHUD.lua`,
`cropThroughput.xml`, `tests/`, `tools/`, `textures/` (corner-post icons) and this file.

## What the layer does

| Piece | File | What it carries |
|---|---|---|
| Real throughput | `src/fork/RealThroughput*.lua`, `cropThroughput.xml` | Per-crop, per-horsepower capacity from real-world anchors (AEM class data), applied through upstream's own energy model |
| Training mode | `src/training/*`, `src/fork/TrainingBridge.lua` | Instructor-driven loss channels; loss physics is sandboxed while active |
| Corner Post HUD | `src/hud/CornerPostHUD.lua` | Training display; replaces the normal HUD while training is on |

## Upstream symbols the layer depends on

If upstream renames or removes one of these, the matching hook logs
`[RHM-fork] ... not found - hook skipped` at startup and that feature goes quiet. The base mod keeps working.

| Symbol (upstream v1.6.4.0) | Used by | Why |
|---|---|---|
| `RHM_LoadCalculator:getCropSpecificEnergy` | RealThroughput | The capacity seam: specific energy, HP per t/h |
| `RHM_LoadCalculator:calculateEngineLoad` | RealThroughput | Supplies the vehicle (the seam has no vehicle argument) and `self.headerHp` |
| `RHM_LoadCalculator:getEnginePowerHp` | RealThroughput | Advertised horsepower for the curve |
| `P_base` fractions in `calculateEngineLoad` (0.08 / 0.095 / 0.11, forage 0.09, root 0.10) | `RealThroughput.baseLossFraction` | **Mirrored by hand.** The derived energy is only exact if both sides use the same fractions - re-check after each upstream merge |
| `RHM_LoadCalculator:calculateTotalCropLoss` | TrainingBridge | The single seam for all loss physics |
| `RHM_RealisticHarvestManager` `new` / `update` / `draw` / `mouseEvent` / `delete` / `getControlledVehicle` / `lastActiveCombine` / `lastControlledVehicle` / `isCursorVisible` | TrainingBridge, RealThroughput | Lifecycle and Training's inputs |
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
compare it with `RealThroughput.baseLossFraction`.

## In-game switches

* `rhmRealThroughput on|off|status|reload` - compare the fork's anchors against upstream's native constants on the same machine and crop.
* `rhmThroughputTable [hp]` - rated throughput of every anchored crop at a horsepower.
* `rhmTraining`, `rhmTrainingTune`, `rhmTrainingDebug`, `rhmPostScale`, `rhmPost*` - Training mode and Corner Post (unchanged from the fork).

## What is deliberately not here

Fork features not carried onto this base yet are listed in the commit history of `snapshot/pre-port-2026-10-16`
(shop integration and electronics tiers, the fork's own speed controller and feederhouse ramp, live optimal
settings, hired-worker tiers, the fork's moisture calculator). Upstream has its own moisture model; the
`<moistureSettings>` block in `cropThroughput.xml` is read by nothing on this branch.
