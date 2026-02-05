## Platooning simualtion in HIL using CARLA and micro-ROS

This repo contains code from the master's thesis project of Julen Casal, developed 2025-2026.

### Requirements

### For flashing

```
openocd -f /usr/share/openocd/scripts/board/stm32h7x3i_eval.cfg -c "program build/platooning_uros_stm32h7.elf verify reset exit"
```
### How to prepare

1. `source /opt/ros/humble/install/setup.sh`
2. `cd ros2_ws && colcon build && source install/setup.sh`
3. `cd ../firmware/stm32/platooning-control` 
4. `sudo docker run -it --rm -v $(pwd):/project --env MICROROS_LIBRARY_FOLDER=micro_ros_stm32cubemx_utils/microros_static_library microros/micro_ros_static_library_builder:humble`
5. Accept with `Y/y`
6. `make all`
Now with the stm32 board connected through the STLink USB port.
7. `openocd -f /usr/share/openocd/scripts/board/stm32h7x3i_eval.cfg -c "program build/platooning_uros_stm32h7.elf verify reset exit"`

