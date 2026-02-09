## Platooning simualtion in HIL using CARLA and micro-ROS

This repo contains code from the master's thesis project of Julen Casal, developed 2025-2026.

### Requirements

This project has been tested, and therefore is ready to work with the following requirememnts:

- Ubuntu 22.04
- ROS 2 Humble (with developer packages)
- Python 3.10.2
- ARM GNU Cross Toolchain (gcc-arm-none-eabi- >=11.0)
- Docker version 29.2.0
- [Micro-ROS Agent (humble branch) installed from `micro_ros_setup`](https://github.com/micro-ROS/micro_ros_setup)
- ESP-IDF 5.2

### Usage

First, ensure both ESP-IDF and the micro-ROS Agents' paths are correctly set up:
```
# Change this so it points to the correct workspaces
export MICROROS_SETUP=~/microros_ws
export IDF_PATH=~/esp/esp-idf 
```

Then, clone the whole meta repository with its submodules:
```
git clone --recurse-submodules git@gitlab.ikerlan.es:STS/archived/old-tfm/tfm-jcasal/meta.git
cd meta/
```
Now, make the `run.sh` helper script runnable with:
```
chmod +x run.sh
```
Now that everything is set up correctly, start the building and flashing process with the helper `run.sh` file. First run the `init` command to correctly set up the custom ROS 2 messages in the firmware directories.
```
./run.sh init
```

Then build the firmware projects with the `build` command:
```
./run.sh build # If failed, individual builds can be run with build-esp and build-stm
```

Finally, make sure the ESP32 and STM32 boards are connected. Both the micro-B Debugging and the UART Bridge can be connected at any port without issue. Also make sure the I2C pins from the ESP32 are correctly connected to the Jetbot expansion board. Run the flashing command to flash both boards:
```
./run.sh flash # Again, if failed, run individually with flash-esp and flash-stm
```




