#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROS_WS="$ROOT/ros2_ws"
ROS_INSTALL_SETUP="$ROS_WS/install/setup.bash"
TOOL_ENV="$ROOT/.tool_env.sh"

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

die() { echo "[tool] ERROR: $*" >&2; exit 1; }
info() { echo "[tool] $*"; }

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

  info "Copying ROS message packages..."
  for d in "${EXTRA_DIRS[@]}"; do
    copy_pkg "$PKG_VEH" "$d"
    copy_pkg "$PKG_ETSI" "$d"
  done

  info "Updating STM32 micro-ROS config..."

  DESTS=(
    "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library/library_generation/colcon.meta"
    "$STM32_DIR/micro_ros_stm32cubemx_utils/microros_static_library_ide/library_generation/colcon.meta"
  )

  for dst in "${DESTS[@]}"; do
    sed -i -E 's/(-DRMW_UXRCE_MAX_PUBLISHERS=)[0-9]+/\112/' "$dst"
    sed -i -E 's/(-DRMW_UXRCE_MAX_SUBSCRIPTIONS=)[0-9]+/\112/' "$dst"
  done

  info "Init complete."
}

build_ros2_ws() {
  info "Building ROS2 workspace..."
  (cd "$ROS_WS" && colcon build)

  source "$ROS_INSTALL_SETUP"

  cat >"$TOOL_ENV" <<EOF
source "$ROS_INSTALL_SETUP"
EOF

  info "Run: source $TOOL_ENV  (if you want ROS env in your shell)"
}

build_stm32() {
  info "Building STM32 micro-ROS static library..."

  (
    cd "$STM32_DIR"

    printf "y\n" | docker run -i --rm \
      -v "$(pwd):/project" \
      --env MICROROS_LIBRARY_FOLDER=micro_ros_stm32cubemx_utils/microros_static_library \
      "$STM32_DOCKER_IMAGE"

    make all
  )
}

build_esp32_motor() {
  info "Building ESP32 motor firmware..."

  source "$ESP_IDF_DIR/export.sh"
  (cd "$ESP32_MOTOR_DIR" && idf.py build)
}

cmd_build() {
  build_ros2_ws
  build_stm32
  build_esp32_motor
  info "Build finished."
}

cmd_help() {
  cat <<EOF
Usage:
  ./tool.sh init
  ./tool.sh build
EOF
}

case "${1:-help}" in
  init)  cmd_init ;;
  build) cmd_build ;;
  help|*) cmd_help ;;
esac

