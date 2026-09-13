#!/usr/bin/env bash
# Runs the Linux desktop build inside a virtual display and serves it over
# noVNC, so the app can be used from a browser (forward port 6080) and
# hot-reloaded from this machine. Usage: tool/devserver.sh [start|stop|shot]
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/development/flutter/bin:$PATH"
DISP=:98
GEOM=${GEOM:-1600x1000x24}
RUNDIR=${RUNDIR:-/tmp/codeapp-dev}
mkdir -p "$RUNDIR"

start_display() {
  if ! pgrep -f "Xvfb $DISP" >/dev/null; then
    Xvfb $DISP -screen 0 "$GEOM" -nolisten tcp >"$RUNDIR/xvfb.log" 2>&1 &
    sleep 1
  fi
  if ! pgrep -f "x11vnc.*$DISP" >/dev/null; then
    x11vnc -display $DISP -forever -shared -nopw -localhost -rfbport 5901 -quiet >"$RUNDIR/x11vnc.log" 2>&1 &
    sleep 1
  fi
  if ! pgrep -f "websockify.*6081" >/dev/null; then
    websockify --web /usr/share/novnc 127.0.0.1:6081 127.0.0.1:5901 >"$RUNDIR/novnc.log" 2>&1 &
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
    ( DISPLAY=$DISP flutter run -d linux --pid-file "$RUNDIR/flutter.pid" <"$RUNDIR/cmd" >"$RUNDIR/flutter.log" 2>&1 ) &
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
    FF=$(command -v ffmpeg || echo "$HOME/anaconda3/envs/cadui/bin/ffmpeg")
    "$FF" -loglevel error -y -f x11grab -video_size "${GEOM%x*}" -i "$DISP" -frames:v 1 "$out"
    echo "$out"
    ;;
  stop)
    pkill -f "flutter run -d linux" || true
    pkill -f "websockify.*6081" || true
    pkill -f "x11vnc.*$DISP" || true
    pkill -f "Xvfb $DISP" || true
    ;;
  *) echo "usage: $0 [start|bg|reload|restart|shot|stop]"; exit 1;;
esac
