# Termux GPS Speedometer

A Bash script for Termux that shows the phone's speed from GPS, and a smoother speed that fuses GPS with the
accelerometer. It also lists the phone's sensors and prints their live readings. I wrote it to see how far a phone
can get as a speedometer with nothing but Termux:API, jq and awk.

## Features

- `speed` prints the GPS speed about once a second and waits for a fix that is accurate enough
- `speedo` fills the gaps between GPS fixes with the accelerometer, so the number moves smoothly
- `gps` prints the full location JSON every second
- `list`, `watch` and `all` list the sensors and stream their values
- km/h or m/s

## Requirements

- Termux and the Termux:API app, installed from the same source as Termux
- `pkg install termux-api jq` (and `gawk` if `awk` is missing)
- Location permission for Termux:API, and GPS turned on

## Usage

```
./sensors.sh list                list all sensors
./sensors.sh speed [kmh|ms]      GPS speed
./sensors.sh speedo [kmh|ms]     GPS fused with the accelerometer, press q to quit
./sensors.sh gps                 full location JSON
./sensors.sh watch "Name" ...    watch one or more sensors
./sensors.sh all                 watch all sensors
```

Settings are environment variables.

| Variable | Default | Used by | Meaning |
|---|---|---|---|
| `UNIT` | `kmh` | speed, speedo | `kmh` or `ms` |
| `ACC` | `30` | speed | largest accepted GPS error in metres |
| `MODE` | `poll` | speed | `stream` uses location updates instead of polling, which is broken in most Termux:API versions |
| `SDT_MS` | `60` | speedo | accelerometer sample interval in ms |
| `GREF` | `10` | speedo | GPS error in metres at which GPS gets half the weight |
| `MAXACC` | `150` | speedo | GPS fixes worse than this are ignored |
| `DELAY` | `300` | watch, all | sensor sample interval in ms |

In `speedo` mode a line looks like this.

```
~ fusion   42.3 | gps   41.8   a=+0.12  |a|=0.35
```

`~` means the forward axis has been learned and the accelerometer is adding to the estimate, `.` means it has not
been learned yet. `a` is the acceleration along the forward axis and `|a|` is the raw acceleration magnitude.
<!-- TODO: replace with a real line from a drive -->

## How it works

`speedo` runs two producers into one FIFO. One polls `termux-location` for GPS fixes and the other streams the
`linear_acceleration` sensor, which is acceleration with gravity removed, in the phone's own axes. An awk program
reads both.

The phone can sit at any angle, so the script first has to learn which direction is forward. Between two GPS fixes
it integrates the acceleration vector. When GPS shows a speed change of at least 0.4 m/s, that integrated vector
points along the direction of travel, and it is blended into the forward axis estimate. Once the axis is known, each
accelerometer sample adds its forward component to the speed.

Every GPS fix pulls the estimate back towards the GPS speed with the weight `GREF / (GREF + accuracy)`, so an
accurate fix counts more than a poor one. Between fixes the accelerometer carries the speed, and at each fix GPS
corrects the drift.

## Limitations

- The phone has to stay fixed relative to the vehicle. If it moves, the learned forward axis is wrong until it is
  learned again.
- The forward axis is only learned while the speed changes. At a constant speed the estimate follows GPS.
- Polling `termux-location` gives roughly one fix per second, and the first fix can take a while.
