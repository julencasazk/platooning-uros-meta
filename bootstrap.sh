#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[bootstrap] Updating submodules..."
git -C "$ROOT" submodule update --init --recursive

# Canonical ROS 2 package directories (submodules directly under ros2_ws/src)
PKG_VEH="$ROOT/ros2_ws/src/vehicle_state_msg"
PKG_ETSI="$ROOT/ros2_ws/src/etsi_its_lite_msgs"

for p in "$PKG_VEH" "$PKG_ETSI"; do
  if [[ ! -f "$p/package.xml" ]]; then
    echo "[bootstrap] ERROR: expected ROS package not found (missing package.xml): $p"
    exit 1
  fi
done

declare -a EXTRA_DIRS=(
  "$ROOT/firmware/stm32/platooning_control/micro_ros_stm32cubemx_utils/extra_packages"
  "$ROOT/firmware/stm32/platooning_control/micro_ros_stm32cubemx_utils/microros_static_library/library_generation/extra_packages"
  "$ROOT/firmware/stm32/platooning_control/micro_ros_stm32cubemx_utils/microros_static_library_ide/library_generation/extra_packages"
  "$ROOT/firmware/esp32/imu/micro_ros_espidf_component/extra_packages"
  "$ROOT/firmware/esp32/motor_control/components/micro_ros_espidf_component/extra_packages"
)

MODE="${1:-symlink}"  # ./bootstrap.sh [symlink|copy]

place_pkg() {
  local src="$1"
  local dst_dir="$2"
  local name
  name="$(basename "$src")"
  local dst="$dst_dir/$name"

  mkdir -p "$dst_dir"

  # Remove existing destination if present
  if [[ -e "$dst" || -L "$dst" ]]; then
    rm -rf "$dst"
  fi

  if [[ "$MODE" == "copy" ]]; then
    echo "[bootstrap] Copying $(basename "$src") -> $dst"
    cp -a "$src" "$dst"
  else
    echo "[bootstrap] Symlinking $(basename "$src") -> $dst"
    ln -s "$src" "$dst"
  fi
}

echo "[bootstrap] Mode: $MODE"
for d in "${EXTRA_DIRS[@]}"; do
  place_pkg "$PKG_VEH" "$d"
  place_pkg "$PKG_ETSI" "$d"
done



echo "[bootstrap] Overwriting default micro-ROS files in stm32 control firmware"

SRC="$ROOT/firmware/stm32/platooning_control/colcon.meta"

declare -a DESTS=(
"$ROOT/firmware/stm32/platooning_control/micro_ros_stm32cubemx_utils/microros_static_library/library_generation/colcon.meta"
"$ROOT/firmware/stm32/platooning_control/micro_ros_stm32cubemx_utils/microros_static_library_ide/library_generation/colcon.meta"
)

for dst in "${DESTS[@]}"; do
	echo "[bootstrap] Modifying Sub/Pub count: $dst"
	sed -i -E 's/(-DRMW_UXRCE_MAX_PUBLISHERS=)[0-9]+/\112/' $dst
	sed -i -E 's/(-DRMW_UXRCE_MAX_SUBSCRIPTIONS=)[0-9]+/\112/' $dst
done

echo "[bootstrap] Done."
