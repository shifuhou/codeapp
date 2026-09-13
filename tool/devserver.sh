#!/usr/bin/env bash
# Runs the Linux desktop build inside a virtual display and serves it over
# noVNC, so the app can be used from a browser (forward port 6080) and
# hot-reloaded from this machine. Usage: tool/devserver.sh [start|stop|shot]
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/development/flutter/bin:$PATH"
# This box has a half-installed gcc-12 that clang would pick; steer it to gcc-11.
if [ -d "$HOME/development/gcc11-prefix" ]; then
  export CXXFLAGS="--gcc-toolchain=$HOME/development/gcc11-prefix ${CXXFLAGS:-}"
  export CFLAGS="--gcc-toolchain=$HOME/development/gcc11-prefix ${CFLAGS:-}"
  export LDFLAGS="--gcc-toolchain=$HOME/development/gcc11-prefix ${LDFLAGS:-}"
fi
DISP=:98
GEOM=${GEOM:-1600x1000x24}
RUNDIR=${RUNDIR:-/tmp/codeapp-dev}
mkdir -p "$RUNDIR"

port_open() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }

start_display() {
  # Checks use the X socket / listening ports, not pgrep -f (which would
  # match any shell whose command line mentions these strings).
  if [ ! -S "/tmp/.X11-unix/X${DISP#:}" ]; then
    setsid Xvfb $DISP -screen 0 "$GEOM" -nolisten tcp >"$RUNDIR/xvfb.log" 2>&1 < /dev/null &
    sleep 1
  fi
  if ! port_open 5901; then
    setsid x11vnc -display $DISP -forever -shared -nopw -localhost -rfbport 5901 -quiet >"$RUNDIR/x11vnc.log" 2>&1 < /dev/null &
    sleep 1
  fi
  if ! port_open 6081; then
    setsid websockify --web /usr/share/novnc 127.0.0.1:6081 127.0.0.1:5901 >"$RUNDIR/novnc.log" 2>&1 < /dev/null &
  fi
  echo "noVNC: http://127.0.0.1:6081/vnc.html?autoconnect=1&resize=remote"
}

case "${1:-start}" in
  start)
    start_display
    # Interactive flutter run: press r to hot reload, R to restart, q to quit.
    DISPLAY=$DISP exec flutter run -d linux "${@:2}"
    ;;
  bg)
    # Non-interactive: keep flutter run alive with a FIFO for commands.
    start_display
    rm -f "$RUNDIR/cmd"; mkfifo "$RUNDIR/cmd"
    ( DISPLAY=$DISP setsid flutter run -d linux --pid-file "$RUNDIR/flutter.pid" <"$RUNDIR/cmd" >"$RUNDIR/flutter.log" 2>&1 ) &
    exec 3>"$RUNDIR/cmd"   # keep the FIFO open so stdin doesn't hit EOF
    echo "flutter run started; log: $RUNDIR/flutter.log"
    wait
    ;;
  reload)
    # SIGUSR1 = hot reload, SIGUSR2 = hot restart (flutter --pid-file)
    kill -USR1 "$(cat "$RUNDIR/flutter.pid")"
    ;;
  restart)
    kill -USR2 "$(cat "$RUNDIR/flutter.pid")"
    ;;
  shot)
    out=${2:-$RUNDIR/shot.png}
    DISPLAY=$DISP xwd -root -silent > "$RUNDIR/shot.xwd"
    python3 "$(dirname "$0")/xwd2png.py" "$RUNDIR/shot.xwd" "$out" >/dev/null
    echo "$out"
    ;;
  stop)
    [ -f "$RUNDIR/flutter.pid" ] && kill "$(cat "$RUNDIR/flutter.pid")" 2>/dev/null || true
    pkill -x codeapp || true
    fuser -k 6081/tcp 5901/tcp 2>/dev/null || true
    pkill -f "^Xvfb $DISP " || true
    ;;
  *) echo "usage: $0 [start|bg|reload|restart|shot|stop]"; exit 1;;
esac
