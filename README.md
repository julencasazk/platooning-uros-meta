## Platooning simualtion in HIL using CARLA and micro-ROS

This repo contains code from the master's thesis project of Julen Casal, developed 2025-2026.

### Requirements

### For flashing

```
openocd -f /usr/share/openocd/scripts/board/stm32h7x3i_eval.cfg -c "program build/platooning_uros_stm32h7.elf verify reset exit"
```


