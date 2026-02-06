#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

die() { echo "[run] ERROR: $*" >&2; exit 1; }
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

# COMPILING FUNCTIONS
# ====================================================================  

build_ros2_ws() {
  info "Building ROS2 workspace..."
  [[ -d "$ROS_WS/src" ]] || die "ROS workspace src not found: $ROS_WS/src"

  # Source system ROS only inside this function/subshell
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

    # Then compile the firmware (expects the generated lib to be present)
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
    # ESP-IDF uses env vars; keep it scoped to the subshell
    source_setup_safe "$idf_dir/export.sh"
    cd "$ESP32_MOTOR_DIR"
    idf.py build
  )

  info "ESP32 Build finished."
}

cmd_build() {
  build_ros2_ws

  # If you want ROS available for any subsequent steps
  source_setup_safe /opt/ros/humble/setup.bash
  source_setup_safe "$ROS_INSTALL_SETUP"

  build_stm32
  build_esp32_motor

  info "All builds finished."
}

# END COMPILING FUNCTIONS ======================================================================================

# FLASHING FUNCTIONS
# ===============================================================================

flash_esp32() {
    info "Flashing ESP32 Firmware..."

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
    # ESP-IDF uses env vars; keep it scoped to the subshell
    source_setup_safe "$idf_dir/export.sh"
    cd "$ESP32_MOTOR_DIR"
    idf.py flash
  )

  info "ESP32 Flash finished."

}


flash_stm32() {
    info "Flashing STM32 Firmware with OpenOCD"

  [[ -d "$STM32_DIR" ]] || die "STM32 dir not found: $STM32_DIR"
  command -v openocd >/dev/null 2>&1 || die "openocd not found in PATH"

  (
    cd "$STM32_DIR"

    # Flash with openocd config found in meta/tools/openocd

    openocd -f $ROOT/tools/openocd/stm32h7x_swd.cfg \
    -c "program build/platooning_uros_stm32h7.elf verify reset exit"

  )

  info "STM32 Flash finished."
}


cmd_flash() {

  flash_esp32
  flash_stm32

  info "All Flash finished."

}
# END FLASH FUNCTIONS ============================================================


# RUN FUNCTIONS
# ================================================================================

# END RUN FUNCTIONS ==============================================================



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

Notes:
- For ESP-IDF, set ESP_IDF_DIR=/path/to/esp-idf   (or IDF_PATH).
EOF
}

case "${1:-help}" in
  init)  cmd_init ;;
  build) cmd_build ;;
  build-esp) build_esp32_motor;;
  build-stm) build_stm32;;
  flash) cmd_flash;;
  flash-esp) flash_esp32;;
  flash-stm) flash_stm32;;
  help|*) cmd_help ;;
esac
