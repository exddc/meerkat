# Meerkat Metrics

`scripts/generate-metrics.sh` records CPU, memory, disk, wakeup, and thermal data with Apple's Activity Monitor Instruments template. It profiles a Release build or an existing Meerkat process.

## Run a Capture

Quit Meerkat, then run:

```sh
scripts/generate-metrics.sh --duration 5m --label background-one-camera
```

The first 30 seconds are warmup and do not affect `summary.json`. For a shorter run:

```sh
scripts/generate-metrics.sh --duration 30s --warmup 5s --label idle
```

To profile a running app, attach by name or process ID:

```sh
scripts/generate-metrics.sh --duration 5m --label visible-playback --attach Meerkat
```

Confirm the running app is the build under test. The summary records its process ID and command.

Run `scripts/generate-metrics.sh --help` for all options.

## Outputs

Each run creates `metrics/<timestamp>/`:

- `summary.json`: aggregate metrics and environment details.
- `samples.csv`: all process samples, including warmup.
- `activity.trace`: raw Instruments recording.
- `process.xml` and `thermal.xml`: exported source data.
- `build.log` and `xctrace.log`: command output when available.

## Compare Scenarios

Record each scenario separately:

1. `idle`: no cameras; panel closed.
2. `background-one-camera`: one camera; panel closed.
3. `background-grid`: normal camera set; panel closed.
4. `visible-playback`: normal camera set; panel open.

Keep the Mac, power source, camera streams, duration, and warmup consistent between runs. Use a longer run to evaluate memory growth:

```sh
scripts/generate-metrics.sh --duration 8h --warmup 5m --label background-soak
```

The script records results without enforcing thresholds.
