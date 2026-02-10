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

The micro-ROS Agents can be run and killed by the following commands:
```
./run.sh agents # Run the agents
./run.sh kill-agents # Kill the agents 
```

The Agents are by default run listening to `/dev/ttyUSB0` and `/dev/ttyUSB1` at a baudrate of `460800`, which is default for the project. For now, to change that, the `run.sh` script should be modified.

The user should check if the Agents are running and what parameters are they run with executing something like:
```
ps aux | grep -i "[m]icroros\|[m]icro_ros"
```

Finally, the required Python `venv` can be created and sourced automatically while also launching a Python script with the `run` command. The following is an example with the latest script:
```
./run.sh run tools/python/core/following_ros_cam.py --host $CARLA_IP --plen 4 --mcu-index 3 -f out.csv
```

Leave `--host` empty if CARLA is running locally (localhost). Also, the STM32 firmware has the vehicle index hardcoded as `veh_3` so to change `--mcu-index` sucessfully the firmware should be altered beforehand.

More information about how to run each script is displayed in a comment block at the start of the Python script.

### In case of failure

If any command fails to correctly execute in the last section, and recloning and trying again does not work, please revert to cloning each repo manually and compile and flash separatelly. Please refer to Appendix A.8 from the thesis document for a detailed guide.
