#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------
# Paths / project config
# -----------------------------
ROS_WS="$ROOT/ros2_ws"
ROS_INSTALL_SETUP="$ROS_WS/install/setup.bash"

PKG_VEH="$ROS_WS/src/vehicle_state_msg"
PKG_ETSI="$ROS_WS/src/etsi_its_lite_msgs"

STM32_DIR="$ROOT/firmware/stm32/platooning_control"
STM32_DOCKER_IMAGE="microros/micro_ros_static_library_builder:humble"

ESP32_MOTOR_DIR="$ROOT/firmware/esp32/motor_control"

EXTRA_DIRS=(
  "$STM32_DIR/micro_ros_stm32cubemx_utils/extra_packages"
  "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library/library_generation/extra_packages"
  "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library_ide/library_generation/extra_packages"
  "$ROOT/firmware/esp32/imu/components/micro_ros_espidf_component/extra_packages"
  "$ESP32_MOTOR_DIR/components/micro_ros_espidf_component/extra_packages"
)

# Python venv (project-local)
PY_DIR="$ROOT/tools/python"
REQ_TXT="$PY_DIR/requirements.txt"
VENV_DIR="$PY_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
VENV_ACT="$VENV_DIR/bin/activate"
VENV_STAMP="$VENV_DIR/.requirements.sha256"

AGENT_LOG_DIR="$ROOT/.run"
AGENT_PID_FILE="$AGENT_LOG_DIR/micro_ros_agents.pids"

die()  { echo "[run] ERROR: $*" >&2; exit 1; }
info() { echo "[run] $*"; }

# Source a setup.bash safely under "set -u" (ROS scripts may reference unset vars)
source_setup_safe() {
  local f="$1"
  [[ -f "$f" ]] || die "setup file not found: $f"
  set +u
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

copy_pkg() {
  local src="$1"
  local dst_dir="$2"
  local name dst

  name="$(basename "$src")"
  dst="$dst_dir/$name"

  mkdir -p "$dst_dir"
  rm -rf "$dst"

  info "Copying $name -> $dst"
  cp -a "$src" "$dst"

  # Prevent nested Git repos inside firmware trees
  rm -rf "$dst/.git" "$dst/.gitmodules" 2>/dev/null || true
}

sha256_file() {
  local f="$1"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
  sha256sum "$f" | awk '{print $1}'
}

# -----------------------------
# Python venv helpers
# -----------------------------
ensure_venv() {
  [[ -d "$PY_DIR" ]] || die "Python dir not found: $PY_DIR"
  [[ -f "$REQ_TXT" ]] || die "requirements.txt not found: $REQ_TXT"
  command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

  local want_recreate="${1:-0}"    # 1 -> force recreate
  local want_upgrade_pip="${2:-0}" # 1 -> pip upgrade before install

  if [[ "$want_recreate" == "1" && -d "$VENV_DIR" ]]; then
    info "Recreating venv: $VENV_DIR"
    rm -rf "$VENV_DIR"
  fi

  if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating venv: $VENV_DIR"
    python3 -m venv --system-site-packages "$VENV_DIR"
  fi

  [[ -x "$VENV_PY" ]] || die "venv python not found/executable: $VENV_PY"
  [[ -x "$VENV_PIP" ]] || die "venv pip not found/executable: $VENV_PIP"

  local req_hash
  req_hash="$(sha256_file "$REQ_TXT")"

  local have_hash=""
  if [[ -f "$VENV_STAMP" ]]; then
    have_hash="$(cat "$VENV_STAMP" 2>/dev/null || true)"
  fi

  if [[ "$want_upgrade_pip" == "1" ]]; then
    info "Upgrading pip/setuptools/wheel in venv..."
    "$VENV_PY" -m pip install --upgrade pip setuptools wheel >/dev/null
  fi

  if [[ "$have_hash" != "$req_hash" ]]; then
    info "Installing python requirements..."
    "$VENV_PY" -m pip install --upgrade pip setuptools wheel >/dev/null
    "$VENV_PY" -m pip install -r "$REQ_TXT"
    echo "$req_hash" >"$VENV_STAMP"
  else
    info "Python requirements already up to date."
  fi
}

activate_venv() {
  [[ -f "$VENV_ACT" ]] || die "venv activate script not found: $VENV_ACT"
  # shellcheck disable=SC1090
  source "$VENV_ACT"
}

resolve_microros_setup() {
  if [[ -n "${MICROROS_WS:-}" ]]; then
    local ws="${MICROROS_WS%/}"
    local setup="$ws/install/local_setup.bash"
    [[ -f "$setup" ]] || die "MICROROS_WS is set but setup file was not found: $setup"
    echo "$setup"
    return 0
  fi

  # Backward compatibility: if MICROROS_SETUP is set, treat it as workspace dir.
  if [[ -n "${MICROROS_SETUP:-}" ]]; then
    local ws_legacy="${MICROROS_SETUP%/}"
    local setup_legacy="$ws_legacy/install/local_setup.bash"
    [[ -f "$setup_legacy" ]] || die "MICROROS_SETUP is set but setup file was not found: $setup_legacy"
    echo "$setup_legacy"
    return 0
  fi

  local candidate
  for candidate in \
    "$HOME/micro_ros_ws/install/local_setup.bash" \
    "$HOME/microros_ws/install/local_setup.bash"
  do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

source_agent_env() {
  source_setup_safe /opt/ros/humble/setup.bash
  source_setup_safe "$ROS_INSTALL_SETUP"

  local microros_setup=""
  if microros_setup="$(resolve_microros_setup)"; then
    source_setup_safe "$microros_setup"
  else
    info "No micro-ROS workspace setup found in default locations; trying existing PATH."
  fi

  command -v ros2 >/dev/null 2>&1 || die "ros2 command not found after sourcing environment."
  ros2 pkg prefix micro_ros_agent >/dev/null 2>&1 || die "ROS package 'micro_ros_agent' not found. Install/source micro-ROS first, or set MICROROS_WS to a workspace that provides it."
}

start_agent_bg() {
  local dev="$1"
  local label="$2"
  local log_file="$AGENT_LOG_DIR/micro_ros_agent_${label}.log"

  (
    source_agent_env
    exec ros2 run micro_ros_agent micro_ros_agent serial --dev "$dev" -b 460800
  ) >"$log_file" 2>&1 &

  local pid="$!"
  echo "$pid:$dev:$log_file" >>"$AGENT_PID_FILE"
  info "Started micro-ROS agent for $dev (PID $pid, log: $log_file)"
}

cmd_agents() {
  mkdir -p "$AGENT_LOG_DIR"
  : >"$AGENT_PID_FILE"

  start_agent_bg "/dev/ttyUSB1" "ttyUSB1"
  start_agent_bg "/dev/ttyUSB0" "ttyUSB0"

  info "Agents started in background."
  info "Use ./run.sh kill-agents to stop them."
}

cmd_kill_agents() {
  local killed=0

  if [[ -f "$AGENT_PID_FILE" ]]; then
    while IFS=: read -r pid _; do
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        killed=1
      fi
    done <"$AGENT_PID_FILE"
    rm -f "$AGENT_PID_FILE"
  fi

  pkill -f "micro_ros_agent.*serial.*ttyUSB0" 2>/dev/null || true
  pkill -f "micro_ros_agent.*serial.*ttyUSB1" 2>/dev/null || true
  pkill -f "micro[_-]ros.*agent" 2>/dev/null || true

  local fallback_pids
  fallback_pids="$(ps aux | grep -iE '[m]icroros|[m]icro-ros|[m]icro_ros.*agent' | awk '{print $2}' | tr '\n' ' ' || true)"
  if [[ -n "${fallback_pids// }" ]]; then
    kill $fallback_pids 2>/dev/null || true
    killed=1
  fi

  if [[ "$killed" -eq 1 ]]; then
    info "Requested shutdown of micro-ROS agent processes."
  else
    info "No matching micro-ROS agent processes found."
  fi
}


# -----------------------------
# INIT
# -----------------------------
cmd_init() {
  info "Updating submodules..."
  git -C "$ROOT" submodule update --init --recursive

  for p in "$PKG_VEH" "$PKG_ETSI"; do
    [[ -f "$p/package.xml" ]] || die "Missing ROS package: $p"
  done

  info "Copying ROS message packages into micro-ROS extra_packages..."
  for d in "${EXTRA_DIRS[@]}"; do
    copy_pkg "$PKG_VEH" "$d"
    copy_pkg "$PKG_ETSI" "$d"
  done

  info "Updating STM32 micro-ROS colcon.meta (pub/sub counts)..."
  local dst
  for dst in \
    "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library/library_generation/colcon.meta" \
    "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library_ide/library_generation/colcon.meta"
  do
    [[ -f "$dst" ]] || die "Missing file: $dst"
    sed -i -E 's/(-DRMW_UXRCE_MAX_PUBLISHERS=)[0-9]+/\112/' "$dst"
    sed -i -E 's/(-DRMW_UXRCE_MAX_SUBSCRIPTIONS=)[0-9]+/\112/' "$dst"
  done

  info "Init complete."
}

# -----------------------------
# BUILD
# -----------------------------
build_ros2_ws() {
  info "Building ROS2 workspace..."
  [[ -d "$ROS_WS/src" ]] || die "ROS workspace src not found: $ROS_WS/src"

  (
    source_setup_safe /opt/ros/humble/setup.bash
    cd "$ROS_WS"
    colcon build
  )

  [[ -f "$ROS_INSTALL_SETUP" ]] || die "ROS install setup not found: $ROS_INSTALL_SETUP"
}

build_stm32() {
  info "Building STM32 micro-ROS static library + firmware..."

  [[ -d "$STM32_DIR" ]] || die "STM32 dir not found: $STM32_DIR"
  command -v docker >/dev/null 2>&1 || die "docker not found in PATH"

  (
    cd "$STM32_DIR"

    # micro-ROS static library builder (needs 'y' confirmation)
    printf "y\n" | sudo docker run -i --rm \
      -v "$(pwd):/project" \
      --env MICROROS_LIBRARY_FOLDER=micro_ros_stm32cubemx_utils/microros_static_library \
      "$STM32_DOCKER_IMAGE"

    make all
  )

  info "STM32 build finished."
}

build_esp32_motor() {
  info "Building ESP32 motor firmware..."

  [[ -d "$ESP32_MOTOR_DIR" ]] || die "ESP32 motor dir not found: $ESP32_MOTOR_DIR"
  [[ -n "${IDF_PATH:-}" || -n "${ESP_IDF_DIR:-}" ]] || die "Set IDF_PATH or ESP_IDF_DIR to your ESP-IDF install directory"

  local idf_dir=""
  if [[ -n "${ESP_IDF_DIR:-}" ]]; then
    idf_dir="$ESP_IDF_DIR"
  else
    idf_dir="$IDF_PATH"
  fi

  [[ -f "$idf_dir/export.sh" ]] || die "ESP-IDF export.sh not found: $idf_dir/export.sh"

  (
    source_setup_safe "$idf_dir/export.sh"
    cd "$ESP32_MOTOR_DIR"
    idf.py build
  )

  info "ESP32 build finished."
}

cmd_build() {
  build_ros2_ws

  # Source overlays for any subsequent steps in this script invocation
  source_setup_safe /opt/ros/humble/setup.bash
  source_setup_safe "$ROS_INSTALL_SETUP"

  build_stm32
  build_esp32_motor

  info "All builds finished."
}

# -----------------------------
# FLASH
# -----------------------------
flash_esp32() {
  info "Flashing ESP32 firmware..."

  [[ -d "$ESP32_MOTOR_DIR" ]] || die "ESP32 motor dir not found: $ESP32_MOTOR_DIR"
  [[ -n "${IDF_PATH:-}" || -n "${ESP_IDF_DIR:-}" ]] || die "Set IDF_PATH or ESP_IDF_DIR to your ESP-IDF install directory"

  local idf_dir=""
  if [[ -n "${ESP_IDF_DIR:-}" ]]; then
    idf_dir="$ESP_IDF_DIR"
  else
    idf_dir="$IDF_PATH"
  fi

  [[ -f "$idf_dir/export.sh" ]] || die "ESP-IDF export.sh not found: $idf_dir/export.sh"

  (
    source_setup_safe "$idf_dir/export.sh"
    cd "$ESP32_MOTOR_DIR"
    idf.py flash
  )

  info "ESP32 flash finished."
}

flash_stm32() {
  info "Flashing STM32 firmware with OpenOCD..."

  [[ -d "$STM32_DIR" ]] || die "STM32 dir not found: $STM32_DIR"
  command -v openocd >/dev/null 2>&1 || die "openocd not found in PATH"
  [[ -f "$STM32_DIR/build/platooning_uros_stm32h7.elf" ]] || die "ELF not found (build first): $STM32_DIR/build/platooning_uros_stm32h7.elf"

  local cfg
  local flashed=0
  local cfgs=(
    "$ROOT/tools/openocd/stm32h7x_swd.cfg"
    "$ROOT/tools/openocd/stm32h7x_hla_swd.cfg"
  )

  for cfg in "${cfgs[@]}"; do
    if [[ ! -f "$cfg" ]]; then
      info "Skipping missing OpenOCD cfg: $cfg"
      continue
    fi

    info "Trying STM32 flash with OpenOCD cfg: $(basename "$cfg")"
    if (
      cd "$STM32_DIR"
      openocd -f "$cfg" \
        -c "program build/platooning_uros_stm32h7.elf verify reset exit"
    ); then
      flashed=1
      break
    fi

    info "Flash attempt failed with cfg: $(basename "$cfg")"
  done

  [[ "$flashed" -eq 1 ]] || die "STM32 flash failed with all OpenOCD configs."

  info "STM32 flash finished."
}

cmd_flash() {
  flash_esp32
  flash_stm32
  info "All flashing finished."
}

# -----------------------------
# PYTHON: venv / run
# -----------------------------
cmd_venv() {
  # Usage:
  #   ./run.sh venv                 -> ensure venv, then open a subshell with it activated
  #   ./run.sh venv --recreate      -> rebuild venv
  #   ./run.sh venv --upgrade-pip   -> upgrade pip tooling
  #   ./run.sh venv <command...>    -> run a command inside the venv environment
  local recreate=0
  local upgrade_pip=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recreate|--recreate-venv) recreate=1; shift ;;
      --upgrade-pip) upgrade_pip=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  ensure_venv "$recreate" "$upgrade_pip"

  if [[ $# -eq 0 ]]; then
    info "Launching subshell with venv activated..."
    (
      # Activation only affects this subshell (by design)
      activate_venv
      exec "${SHELL:-/bin/bash}" -i
    )
  else
    info "Running in venv: $*"
    (
      activate_venv
      "$@"
    )
  fi
}

cmd_runpy() {
  # Usage:
  #   ./run.sh run <script.py> [args...]
  # Options:
  #   --recreate-venv
  #   --upgrade-pip
  local recreate=0
  local upgrade_pip=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recreate|--recreate-venv) recreate=1; shift ;;
      --upgrade-pip) upgrade_pip=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  [[ $# -ge 1 ]] || die "Usage: ./run.sh run <script.py> [args...]"

  local script_rel="$1"; shift
  local script="$ROOT/$script_rel"

  [[ -f "$script" ]] || die "Python script not found: $script (pass a path relative to $ROOT)"

  ensure_venv "$recreate" "$upgrade_pip"

  info "Running python: $script_rel $*"
  (
    source_setup_safe /opt/ros/humble/setup.bash
    source_setup_safe "$ROS_INSTALL_SETUP"
    activate_venv
    export PYTHONPATH="$PY_DIR:${PYTHONPATH:-}"
    pushd "$PY_DIR" >/dev/null
    "$VENV_PY" "$script" "$@"
    popd >/dev/null
  )
}

# -----------------------------
# HELP
# -----------------------------
cmd_help() {
  cat <<EOF
Usage:
  ./run.sh init
  ./run.sh build
  ./run.sh build-esp
  ./run.sh build-stm
  ./run.sh flash
  ./run.sh flash-esp
  ./run.sh flash-stm
  ./run.sh agents
  ./run.sh kill-agents

Python:
  ./run.sh venv [--recreate-venv] [--upgrade-pip] [-- <command...>]
    - With no command: opens an interactive subshell with venv activated.
    - With a command: runs the command inside the venv environment.

  ./run.sh run [--recreate-venv] [--upgrade-pip] <script.py> [args...]
    - Runs a python script (path relative to repo root) using tools/python/.venv.

Notes:
- For ESP-IDF, set ESP_IDF_DIR=/path/to/esp-idf   (or IDF_PATH).
- venv location: $VENV_DIR
- requirements:  $REQ_TXT
EOF
}

case "${1:-help}" in
  init)       shift; cmd_init "$@" ;;
  build)      shift; cmd_build "$@" ;;
  build-esp)  shift; build_esp32_motor "$@" ;;
  build-stm)  shift; build_stm32 "$@" ;;
  flash)      shift; cmd_flash "$@" ;;
  flash-esp)  shift; flash_esp32 "$@" ;;
  flash-stm)  shift; flash_stm32 "$@" ;;
  agents)     shift; cmd_agents "$@" ;;
  kill-agents) shift; cmd_kill_agents "$@" ;;

  venv)       shift; cmd_venv "$@" ;;
  run)        shift; cmd_runpy "$@" ;;

  help|*)     cmd_help ;;
esac
