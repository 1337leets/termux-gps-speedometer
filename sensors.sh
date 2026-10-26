#!/data/data/com.termux/files/usr/bin/bash
# sensors.sh - Termux sensor and location monitor
#
# Usage:
#   ./sensors.sh list                List all sensors
#   ./sensors.sh speed [kmh|ms]      GPS speed (GPS only, about 1 Hz)
#   ./sensors.sh speedo [kmh|ms]     Smooth speed, GPS fused with the accelerometer
#   ./sensors.sh gps                 Full location JSON, refreshed every second
#   ./sensors.sh watch "Name" ...    Watch one or more sensors live
#   ./sensors.sh all                 Watch all sensors live
#
# Settings (environment variables):
#   UNIT=ms    ./sensors.sh speedo   Main unit: kmh (default) or ms
#   ACC=20     ./sensors.sh speed    Largest accepted GPS error (m), default 30
#   MODE=stream ./sensors.sh speed   Use location updates instead of polling (broken in most Termux:API versions)
#   SDT_MS=60  ./sensors.sh speedo   Accelerometer sample interval (ms), default 60
#   GREF=10 MAXACC=150 ./sensors.sh speedo   GPS trust reference and upper error limit (m)
#   DELAY=100  ./sensors.sh all      Sensor sample interval (ms), default 300
#
# Needs: pkg install termux-api jq  (+ awk, if missing: pkg install gawk)
#        and the Termux:API app (from the same source as Termux)

set -u
DELAY="${DELAY:-300}"
ACC="${ACC:-30}"
UNIT="${UNIT:-kmh}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1  (pkg install termux-api jq gawk)"; exit 1; }; }
need jq

cmd="${1:-help}"; shift 2>/dev/null || true

case "$cmd" in
  list)
    need termux-sensor
    termux-sensor -l | jq -r '.sensors[]' | sort
    ;;

  speed)
    need termux-location
    [ "${1:-}" = "ms" ]  && UNIT=ms
    [ "${1:-}" = "kmh" ] && UNIT=kmh
    echo "GPS stream (Ctrl-C to quit). Unit: $UNIT, limit: ±${ACC}m, mode: ${MODE:-poll}"
    {
      if [ "${MODE:-poll}" = "poll" ]; then
        while true; do
          printf '%s' "$(termux-location -p gps -r once 2>/dev/null)" \
            | jq -rc '"\(.provider // "?") \(.accuracy // 9999) \(.speed // 0)"'
        done
      else
        termux-location -p gps -r updates 2>/dev/null \
          | jq --unbuffered -rc '"\(.provider // "?") \(.accuracy // 9999) \(.speed // 0)"'
      fi
    } | while read -r prov acc ms; do
        if [ "$prov" = "gps" ] && awk "BEGIN{exit !($acc < $ACC)}"; then
          kmh="$(awk -v v="$ms" 'BEGIN{printf "%.1f", v*3.6}')"
          mps="$(awk -v v="$ms" 'BEGIN{printf "%.1f", v}')"
          if [ "$UNIT" = "ms" ]; then
            printf '\r\033[K%6s m/s   (%s km/h)   ±%.0fm   %s' "$mps" "$kmh" "$acc" "$(date +%H:%M:%S)"
          else
            printf '\r\033[K%6s km/h   (%s m/s)   ±%.0fm   %s' "$kmh" "$mps" "$acc" "$(date +%H:%M:%S)"
          fi
        else
          printf '\r\033[KWaiting for a fix... (±%.0fm, %s)   %s' "$acc" "$prov" "$(date +%H:%M:%S)"
        fi
      done
    ;;

  speedo)
    need termux-sensor; need termux-location; need awk
    [ "${1:-}" = "ms" ]  && UNIT=ms
    [ "${1:-}" = "kmh" ] && UNIT=kmh
    SDT_MS="${SDT_MS:-60}"
    GREF="${GREF:-10}"        # GPS reference error (m), at this error GPS gets about 50 % weight
    MAXACC="${MAXACC:-150}"   # fixes worse than this are ignored completely
    dt="$(awk -v m="$SDT_MS" 'BEGIN{printf "%.3f", m/1000}')"
    echo "Fused speed ('q' to quit). Unit: $UNIT, GPS trust ~${GREF}m, limit ±${MAXACC}m, accel dt=${SDT_MS}ms"
    echo "Keep the phone fixed relative to the vehicle. '~' = accelerometer estimate between GPS fixes."

    fifo="$(mktemp -u)"; mkfifo "$fifo"
    PIDS=""
    cleanup(){
      trap - EXIT INT TERM
      termux-sensor -c >/dev/null 2>&1             # first, tell the service to stop while the stream is still registered
      kill $PIDS 2>/dev/null                       # stop the background producers, GPS loop included
      if command -v pkill >/dev/null 2>&1; then    # also sweep by name, just in case
        pkill -f 'termux-location -p gps' 2>/dev/null
        pkill -f 'termux-sensor -s linear_acceleration' 2>/dev/null
      fi
      termux-sensor -c >/dev/null 2>&1             # then stop anything that is still left
      rm -f "$fifo"
    }
    trap cleanup EXIT INT TERM

    # Producer 1: accelerometer stream (linear acceleration without gravity, phone axes)
    ( termux-sensor -s "linear_acceleration" -d "$SDT_MS" \
        | jq --unbuffered -rc 'if .["linear_acceleration"] then
              "S \(.["linear_acceleration"].values[0]) \(.["linear_acceleration"].values[1]) \(.["linear_acceleration"].values[2])"
            else empty end' ) > "$fifo" 2>/dev/null &
    PIDS="$PIDS $!"

    # Producer 2: GPS polling (about 1 Hz anchor)
    ( while true; do
        termux-location -p gps -r once 2>/dev/null \
          | jq -rc '"G \(.speed // 0) \(.accuracy // 9999) \(.provider // "?")"'
      done ) > "$fifo" 2>/dev/null &
    PIDS="$PIDS $!"

    # Consumer: complementary filter, with the forward axis calibrated from GPS
    awk -v dt="$dt" -v UNIT="$UNIT" -v GREF="$GREF" -v MAXACC="$MAXACC" '
      BEGIN{
        v=0; fx=0; fy=0; fz=0; fmag=0; have=0; prevg=0;
        sx=0; sy=0; sz=0; glast=0;
        B=0.3;       # smoothing of the learned forward axis
        MINCAL=0.4;  # smallest speed change needed for calibration (m/s)
      }
      $1=="S"{
        ax=$2; ay=$3; az=$4;
        # integrate acceleration between GPS fixes (= velocity change vector in phone axes)
        sx+=ax*dt; sy+=ay*dt; sz+=az*dt;
        afwd=0;
        if(fmag>0){ afwd=ax*fx+ay*fy+az*fz; v+=afwd*dt; if(v<0)v=0; }
        amag=sqrt(ax*ax+ay*ay+az*az);     # raw acceleration magnitude, moves even without GPS or calibration (liveness check)
        tag=(fmag>0)?"~":".";
        if(UNIT=="ms"){ df=v; dg=glast }
        else          { df=v*3.6; dg=glast*3.6 }
        printf "\r\033[K%s fusion %6.1f | gps %6.1f   a=%+.2f  |a|=%.2f", tag, df, dg, afwd, amag;
        fflush();
      }
      $1=="G"{
        g=$2+0; acc=$3+0; prov=$4;
        if(prov=="gps" && acc<MAXACC){
          if(have){
            dvg=g-prevg;
            smag=sqrt(sx*sx+sy*sy+sz*sz);
            if(smag>MINCAL){                 # enough acceleration, learn the forward direction
              sgn=(dvg>=0)?1:-1;
              nx=sgn*sx/smag; ny=sgn*sy/smag; nz=sgn*sz/smag;
              fx=(1-B)*fx+B*nx; fy=(1-B)*fy+B*ny; fz=(1-B)*fz+B*nz;
              fmag=sqrt(fx*fx+fy*fy+fz*fz);
              if(fmag>0){ fx/=fmag; fy/=fmag; fz/=fmag; fmag=1; }
            }
          }
          A=GREF/(GREF+acc);                 # Kalman-like gain, a large GPS error gives GPS less weight
          v=A*g+(1-A)*v;                     # GPS anchor, weighted by its error
          glast=g;                           # keep the raw GPS value for the display
          prevg=g; have=1;
          sx=0; sy=0; sz=0;                  # reset the integrator
        }
      }
    ' < "$fifo" &
    PIDS="$PIDS $!"

    # Foreground: wait for 'q'. The loop ends and the EXIT trap runs cleanup.
    # (awk prints in the background while the keyboard is read here, Ctrl-C also works.)
    while IFS= read -rsn1 key; do
      case "$key" in q|Q) break;; esac
    done
    printf '\nExiting...\n'
    ;;

  gps)
    need termux-location
    while true; do
      clear
      termux-location -p gps -r once 2>/dev/null | jq .
      sleep 1
    done
    ;;

  watch)
    need termux-sensor
    [ "$#" -gt 0 ] || { echo "Give a sensor name. First run:  ./sensors.sh list"; exit 1; }
    trap 'termux-sensor -c >/dev/null 2>&1; echo' EXIT
    sel="$(IFS=,; echo "$*")"
    termux-sensor -s "$sel" -d "$DELAY" | jq --unbuffered -c '.'
    ;;

  all)
    need termux-sensor
    trap 'termux-sensor -c >/dev/null 2>&1; echo' EXIT
    termux-sensor -a -d "$DELAY" | jq --unbuffered -c '.'
    ;;

  *)
    grep '^#' "$0" | tail -n +2 | sed 's/^# \{0,1\}//'
    ;;
esac
