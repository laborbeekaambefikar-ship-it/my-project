#!/usr/bin/env bash
# =============================================================================
# ORION WAREHOUSE AGV SIMULATION - MASTER INSTALLER
# =============================================================================
# Single-command installer for the ORION warehouse Autonomous Guided Vehicle
# simulation. Targets Ubuntu 22.04 + ROS 2 Humble + Gazebo Classic 11.
#
# Usage:    bash setup_orion.sh
#
# This script is fully reproducible: deleting ~/orion_ws and re-running it
# recreates the entire project identically. Every source file is generated
# in-place via heredocs. There are no external file dependencies.
#
# Workspace : ~/orion_ws
# Packages  : orion_msgs, orion_world, orion_robot, orion_core, orion_launch
# Namespace : /orion
# =============================================================================

set -e
set -u
set -o pipefail

# ------------------------------ CONFIGURATION --------------------------------
WS_ROOT="${HOME}/orion_ws"
SRC_DIR="${WS_ROOT}/src"
ROS_DISTRO="${ROS_DISTRO:-humble}"
LAUNCH_AFTER_BUILD="${LAUNCH_AFTER_BUILD:-1}"

# ------------------------------ COLOURED OUTPUT ------------------------------
C_RESET="\033[0m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"

step()    { echo -e "${C_BLUE}[STEP]${C_RESET} $*"; }
ok()      { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
fail()    { echo -e "${C_RED}[FAIL]${C_RESET} $*"; exit 1; }
section() { echo -e "\n${C_CYAN}========== $* ==========${C_RESET}\n"; }

# ============================================================================
# PHASE 1 : SYSTEM DEPENDENCIES
# ============================================================================
section "PHASE 1 - System dependencies"

if [ ! -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
  fail "ROS 2 ${ROS_DISTRO} not found at /opt/ros/${ROS_DISTRO}. Install it first."
fi
ok "ROS 2 ${ROS_DISTRO} detected."

step "Installing apt dependencies (sudo password may be requested)"
sudo apt-get update -y >/dev/null
sudo apt-get install -y \
  python3-pip python3-colcon-common-extensions python3-rosdep \
  ros-${ROS_DISTRO}-gazebo-ros-pkgs \
  ros-${ROS_DISTRO}-gazebo-ros2-control \
  ros-${ROS_DISTRO}-xacro \
  ros-${ROS_DISTRO}-robot-state-publisher \
  ros-${ROS_DISTRO}-joint-state-publisher \
  ros-${ROS_DISTRO}-rviz2 \
  ros-${ROS_DISTRO}-tf-transformations \
  ros-${ROS_DISTRO}-rosidl-default-generators \
  python3-pyqt5 \
  >/dev/null
ok "apt dependencies installed."

step "Installing python dependencies"
python3 -m pip install --user --quiet --upgrade transforms3d numpy >/dev/null
ok "Python dependencies installed."

# ============================================================================
# PHASE 2 : WORKSPACE LAYOUT
# ============================================================================
section "PHASE 2 - Workspace layout"

step "Creating workspace at ${WS_ROOT}"
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"
ok "Workspace ready."

# ============================================================================
# PHASE 3 : PACKAGE orion_msgs (custom message definitions)
# ============================================================================
section "PHASE 3 - orion_msgs"

mkdir -p orion_msgs/msg

cat > orion_msgs/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_msgs</name>
  <version>1.0.0</version>
  <description>Custom message definitions for the ORION warehouse AGV simulation.</description>
  <maintainer email="orion@example.com">orion</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_cmake</buildtool_depend>
  <buildtool_depend>rosidl_default_generators</buildtool_depend>

  <depend>std_msgs</depend>

  <exec_depend>rosidl_default_runtime</exec_depend>
  <member_of_group>rosidl_interface_packages</member_of_group>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
EOF

cat > orion_msgs/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(orion_msgs)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(std_msgs REQUIRED)
find_package(rosidl_default_generators REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/Mission.msg"
  "msg/RFIDEvent.msg"
  "msg/RobotStatus.msg"
  DEPENDENCIES std_msgs
)

ament_export_dependencies(rosidl_default_runtime)
ament_package()
EOF

cat > orion_msgs/msg/Mission.msg <<'EOF'
# Mission request submitted to the ORION mission manager.
string mission_id      # unique identifier (UUID/short hash)
string target_shelf    # e.g. "S07"
string sku             # stock keeping unit, e.g. "SKU-1042"
uint8  priority        # 0=low, 1=normal, 2=high
EOF

cat > orion_msgs/msg/RFIDEvent.msg <<'EOF'
# Emitted by the simulated RFID reader when a tag enters the detection radius.
string  tag_id         # e.g. "RFID-S07" or "RFID-HOME"
string  shelf_id       # mirrored shelf identifier (empty for HOME)
float32 distance       # planar distance from reader to tag at trigger time [m]
bool    is_home        # true if this is the HOME station tag
builtin_interfaces/Time stamp
EOF

cat > orion_msgs/msg/RobotStatus.msg <<'EOF'
# Broadcast by the mission manager at 10 Hz with the live robot status.
string  state                # FSM state name, see mission_manager.py
string  mission_id           # active mission id, empty if none
string  target_shelf         # currently targeted shelf, empty if none
string  current_sku          # SKU being handled, empty if none
string  last_rfid            # last RFID tag detected
bool    carrying_load        # true after pickup, false after dock
float32 battery_percent      # simulated battery level (0..100)
EOF
ok "orion_msgs files written."


# ============================================================================
# PHASE 4 : PACKAGE orion_world (warehouse generator + launch)
# ============================================================================
section "PHASE 4 - orion_world"

mkdir -p orion_world/{worlds,launch,scripts}

cat > orion_world/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_world</name>
  <version>1.0.0</version>
  <description>ORION warehouse Gazebo world (auto generated by Python).</description>
  <maintainer email="orion@example.com">orion</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_cmake</buildtool_depend>

  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>python3</exec_depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
EOF

cat > orion_world/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(orion_world)

find_package(ament_cmake REQUIRED)

# Generate the warehouse world at configure time so install/share contains it.
set(GENERATOR ${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_world.py)
set(WORLD_OUT ${CMAKE_CURRENT_SOURCE_DIR}/worlds/warehouse.world)

execute_process(
  COMMAND python3 ${GENERATOR} ${WORLD_OUT}
  RESULT_VARIABLE _gen_rc
  OUTPUT_VARIABLE _gen_out
  ERROR_VARIABLE  _gen_err
)
if(NOT _gen_rc EQUAL 0)
  message(FATAL_ERROR "World generator failed: ${_gen_err}")
endif()
message(STATUS "orion_world generated ${WORLD_OUT}")

install(DIRECTORY worlds  DESTINATION share/${PROJECT_NAME})
install(DIRECTORY launch  DESTINATION share/${PROJECT_NAME})
install(DIRECTORY scripts DESTINATION share/${PROJECT_NAME})

ament_package()
EOF

cat > orion_world/scripts/generate_world.py <<'PYEOF'
#!/usr/bin/env python3
"""
ORION Warehouse World Generator
================================
Procedurally builds a Gazebo Classic SDF world describing the ORION
warehouse facility:

  * HOME station (green pad) at (0.0, -1.0)
  * Main spine guide line running from HOME to the far wall
  * Five perpendicular aisles branching to +X
  * Four shelves per aisle (20 shelves total, S01..S20)
  * Visible black guide-line strips on the floor
  * Coloured floor tags at every RFID location
  * Perimeter walls, ground plane, sun and ambient lighting

Coordinates are documented in track_geometry.py (orion_core package).

Usage:
    python3 generate_world.py <output_path>
"""

import sys
import os

# -------------------- LAYOUT CONSTANTS --------------------
HOME_X, HOME_Y = 0.0, -1.0
SPINE_Y_START  = -1.0
SPINE_Y_END    = 11.0
AISLE_Y_LIST   = [1.0, 3.0, 5.0, 7.0, 9.0]    # 5 aisles
AISLE_X_END    = 4.0                          # aisles run from x=0 to x=4
SHELF_X_OFFSETS = [1.0, 1.8, 2.6, 3.4]        # 4 shelves per aisle
LINE_WIDTH     = 0.06                          # 6 cm guide tape
LINE_HEIGHT    = 0.002                         # 2 mm thickness (visual)
ROOM_HALF_X    = 6.0
ROOM_MIN_Y     = -3.0
ROOM_MAX_Y     = 13.0
WALL_HEIGHT    = 1.5
WALL_THICK     = 0.10


def vis_box(name, x, y, z, sx, sy, sz, rgba):
    """Static visual + collision box helper."""
    r, g, b, a = rgba
    return f"""
    <model name='{name}'>
      <static>true</static>
      <pose>{x} {y} {z} 0 0 0</pose>
      <link name='link'>
        <collision name='c'>
          <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
        </collision>
        <visual name='v'>
          <geometry><box><size>{sx} {sy} {sz}</size></box></geometry>
          <material>
            <ambient>{r} {g} {b} {a}</ambient>
            <diffuse>{r} {g} {b} {a}</diffuse>
          </material>
        </visual>
      </link>
    </model>"""


def vis_line(name, x1, y1, x2, y2, rgba=(0.05, 0.05, 0.05, 1)):
    """Thin black strip representing a guide tape segment."""
    cx = 0.5 * (x1 + x2)
    cy = 0.5 * (y1 + y2)
    if abs(x2 - x1) < 1e-6:
        sx, sy = LINE_WIDTH, abs(y2 - y1)
    else:
        sx, sy = abs(x2 - x1), LINE_WIDTH
    return vis_box(name, cx, cy, LINE_HEIGHT / 2.0,
                   sx, sy, LINE_HEIGHT, rgba)


def shelf_model(name, x, y, yaw):
    """Multi-tier wooden rack."""
    return f"""
    <model name='{name}'>
      <static>true</static>
      <pose>{x} {y} 0 0 0 {yaw}</pose>
      <link name='link'>
        <collision name='base'>
          <pose>0 0 0.05 0 0 0</pose>
          <geometry><box><size>0.50 0.40 0.10</size></box></geometry>
        </collision>
        <visual name='base_v'>
          <pose>0 0 0.05 0 0 0</pose>
          <geometry><box><size>0.50 0.40 0.10</size></box></geometry>
          <material>
            <ambient>0.55 0.40 0.20 1</ambient>
            <diffuse>0.55 0.40 0.20 1</diffuse>
          </material>
        </visual>
        <visual name='post_fl'>
          <pose>0.22 0.18 0.50 0 0 0</pose>
          <geometry><box><size>0.04 0.04 0.90</size></box></geometry>
          <material><ambient>0.35 0.25 0.10 1</ambient></material>
        </visual>
        <visual name='post_fr'>
          <pose>0.22 -0.18 0.50 0 0 0</pose>
          <geometry><box><size>0.04 0.04 0.90</size></box></geometry>
          <material><ambient>0.35 0.25 0.10 1</ambient></material>
        </visual>
        <visual name='post_bl'>
          <pose>-0.22 0.18 0.50 0 0 0</pose>
          <geometry><box><size>0.04 0.04 0.90</size></box></geometry>
          <material><ambient>0.35 0.25 0.10 1</ambient></material>
        </visual>
        <visual name='post_br'>
          <pose>-0.22 -0.18 0.50 0 0 0</pose>
          <geometry><box><size>0.04 0.04 0.90</size></box></geometry>
          <material><ambient>0.35 0.25 0.10 1</ambient></material>
        </visual>
        <visual name='shelf1'>
          <pose>0 0 0.45 0 0 0</pose>
          <geometry><box><size>0.50 0.40 0.02</size></box></geometry>
          <material><ambient>0.65 0.50 0.30 1</ambient></material>
        </visual>
        <visual name='shelf2'>
          <pose>0 0 0.85 0 0 0</pose>
          <geometry><box><size>0.50 0.40 0.02</size></box></geometry>
          <material><ambient>0.65 0.50 0.30 1</ambient></material>
        </visual>
      </link>
    </model>"""


def rfid_pad(name, x, y, rgba=(0.10, 0.40, 0.95, 1)):
    """Blue square RFID floor tag."""
    return vis_box(name, x, y, 0.0015, 0.20, 0.20, 0.003, rgba)


def home_pad():
    return vis_box("orion_home_pad", HOME_X, HOME_Y, 0.001,
                   0.80, 0.80, 0.002, (0.10, 0.80, 0.20, 1))


def perimeter_walls():
    """Four wall boxes around the warehouse footprint."""
    parts = []
    # north / south
    parts.append(vis_box("wall_n", 0.0, ROOM_MAX_Y + WALL_THICK / 2,
                         WALL_HEIGHT / 2, 2 * ROOM_HALF_X + 2 * WALL_THICK,
                         WALL_THICK, WALL_HEIGHT, (0.85, 0.85, 0.85, 1)))
    parts.append(vis_box("wall_s", 0.0, ROOM_MIN_Y - WALL_THICK / 2,
                         WALL_HEIGHT / 2, 2 * ROOM_HALF_X + 2 * WALL_THICK,
                         WALL_THICK, WALL_HEIGHT, (0.85, 0.85, 0.85, 1)))
    # east / west
    parts.append(vis_box("wall_e", ROOM_HALF_X + WALL_THICK / 2, 0.5 * (ROOM_MIN_Y + ROOM_MAX_Y),
                         WALL_HEIGHT / 2, WALL_THICK,
                         (ROOM_MAX_Y - ROOM_MIN_Y), WALL_HEIGHT, (0.85, 0.85, 0.85, 1)))
    parts.append(vis_box("wall_w", -ROOM_HALF_X - WALL_THICK / 2, 0.5 * (ROOM_MIN_Y + ROOM_MAX_Y),
                         WALL_HEIGHT / 2, WALL_THICK,
                         (ROOM_MAX_Y - ROOM_MIN_Y), WALL_HEIGHT, (0.85, 0.85, 0.85, 1)))
    return "".join(parts)


def build_world() -> str:
    parts = []

    # ---- header ----
    parts.append("""<?xml version='1.0'?>
<sdf version='1.6'>
  <world name='orion_warehouse'>
    <gravity>0 0 -9.81</gravity>
    <physics name='default_physics' type='ode'>
      <max_step_size>0.001</max_step_size>
      <real_time_factor>1.0</real_time_factor>
      <real_time_update_rate>1000</real_time_update_rate>
    </physics>
    <scene>
      <ambient>0.5 0.5 0.5 1</ambient>
      <background>0.7 0.8 0.9 1</background>
      <shadows>1</shadows>
    </scene>

    <include><uri>model://sun</uri></include>
    <include><uri>model://ground_plane</uri></include>
""")

    # ---- HOME pad ----
    parts.append(home_pad())

    # ---- main spine line ----
    parts.append(vis_line("line_spine", 0.0, SPINE_Y_START, 0.0, SPINE_Y_END))

    # ---- aisle lines + shelves + RFID tags ----
    shelf_idx = 1
    for ai, ay in enumerate(AISLE_Y_LIST, start=1):
        parts.append(vis_line(f"line_aisle_{ai}", 0.0, ay, AISLE_X_END, ay))
        for sx in SHELF_X_OFFSETS:
            sid = f"S{shelf_idx:02d}"
            # shelf is placed slightly off the line (+Y side), facing -Y
            shelf_y = ay + 0.45
            parts.append(shelf_model(f"shelf_{sid}", sx, shelf_y, -1.5708))
            # RFID tag is centred on the aisle line directly in front of the shelf
            parts.append(rfid_pad(f"rfid_{sid}", sx, ay))
            shelf_idx += 1

    # HOME RFID pad (red so it stands out from shelf RFIDs)
    parts.append(rfid_pad("rfid_HOME", HOME_X, HOME_Y, (0.90, 0.10, 0.10, 1)))

    # ---- perimeter walls ----
    parts.append(perimeter_walls())

    # ---- footer ----
    parts.append("\n  </world>\n</sdf>\n")
    return "".join(parts)


def main():
    if len(sys.argv) != 2:
        print("Usage: generate_world.py <output_path>", file=sys.stderr)
        sys.exit(1)
    out = sys.argv[1]
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    content = build_world()
    with open(out, "w") as f:
        f.write(content)
    print(f"[orion_world] wrote {out} ({len(content)} bytes)")


if __name__ == "__main__":
    main()
PYEOF
chmod +x orion_world/scripts/generate_world.py

cat > orion_world/launch/world.launch.py <<'PYEOF'
"""Launches Gazebo Classic with the ORION warehouse world (no robot)."""
import os
from launch import LaunchDescription
from launch.actions import ExecuteProcess
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    world_path = os.path.join(
        get_package_share_directory('orion_world'),
        'worlds', 'warehouse.world')

    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose', world_path,
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen')

    return LaunchDescription([gazebo])
PYEOF

# Pre-generate the world so first build succeeds even before colcon configure
python3 orion_world/scripts/generate_world.py orion_world/worlds/warehouse.world
ok "orion_world files written and warehouse.world pre-generated."


# ============================================================================
# PHASE 5 : PACKAGE orion_robot (differential-drive AGV URDF + spawn)
# ============================================================================
section "PHASE 5 - orion_robot"

mkdir -p orion_robot/{urdf,launch,rviz,config}

cat > orion_robot/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_robot</name>
  <version>1.0.0</version>
  <description>ORION differential-drive AGV URDF + spawning utilities.</description>
  <maintainer email="orion@example.com">orion</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_cmake</buildtool_depend>

  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>joint_state_publisher</exec_depend>
  <exec_depend>xacro</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>rviz2</exec_depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
EOF

cat > orion_robot/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(orion_robot)

find_package(ament_cmake REQUIRED)

install(DIRECTORY urdf   DESTINATION share/${PROJECT_NAME})
install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})
install(DIRECTORY rviz   DESTINATION share/${PROJECT_NAME})
install(DIRECTORY config DESTINATION share/${PROJECT_NAME})

ament_package()
EOF

cat > orion_robot/urdf/orion_agv.urdf.xacro <<'EOF'
<?xml version="1.0"?>
<!--
  ORION AGV - differential drive warehouse robot.

  Geometry  : 0.30 (X) x 0.25 (Y) x 0.10 chassis on two driven wheels + 1 caster
  Wheels    : radius 0.05 m, thickness 0.04 m, separation 0.30 m
  Mass      : ~3.0 kg total
  Spawn z   : 0.01 m (just above ground - prevents settling impulses)
  Physics   : joint damping 0.5, joint friction 0.2, surface mu1=1.0/mu2=0.5
              kp=1e6, kd=10. Caster is frictionless (free swivel).
-->
<robot name="orion_agv" xmlns:xacro="http://www.ros.org/wiki/xacro">

  <xacro:property name="WHEEL_R"     value="0.050"/>
  <xacro:property name="WHEEL_T"     value="0.040"/>
  <xacro:property name="WHEEL_SEP"   value="0.300"/>
  <xacro:property name="CHASSIS_X"   value="0.300"/>
  <xacro:property name="CHASSIS_Y"   value="0.250"/>
  <xacro:property name="CHASSIS_Z"   value="0.100"/>
  <xacro:property name="CASTER_R"    value="0.025"/>
  <xacro:property name="CHASSIS_M"   value="2.500"/>
  <xacro:property name="WHEEL_M"     value="0.200"/>
  <xacro:property name="CASTER_M"    value="0.020"/>
  <xacro:property name="PI"          value="3.14159265359"/>

  <material name="orion_navy">   <color rgba="0.10 0.20 0.55 1.0"/></material>
  <material name="orion_amber">  <color rgba="1.00 0.65 0.00 1.0"/></material>
  <material name="orion_black">  <color rgba="0.05 0.05 0.05 1.0"/></material>
  <material name="orion_grey">   <color rgba="0.55 0.55 0.55 1.0"/></material>

  <!-- ================================================================ -->
  <!--  base_footprint : ground projection (origin of the robot frame)  -->
  <!-- ================================================================ -->
  <link name="base_footprint"/>

  <joint name="base_footprint_to_base" type="fixed">
    <parent link="base_footprint"/>
    <child  link="base_link"/>
    <origin xyz="0 0 ${WHEEL_R}" rpy="0 0 0"/>
  </joint>

  <!-- ================================================================ -->
  <!--  Chassis                                                          -->
  <!-- ================================================================ -->
  <link name="base_link">
    <visual>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
      <material name="orion_navy"/>
    </visual>
    <collision>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
    </collision>
    <inertial>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <mass value="${CHASSIS_M}"/>
      <!-- box inertia: Ixx=m/12*(y^2+z^2), etc. -->
      <inertia
        ixx="${CHASSIS_M*(CHASSIS_Y*CHASSIS_Y + CHASSIS_Z*CHASSIS_Z)/12.0}"
        iyy="${CHASSIS_M*(CHASSIS_X*CHASSIS_X + CHASSIS_Z*CHASSIS_Z)/12.0}"
        izz="${CHASSIS_M*(CHASSIS_X*CHASSIS_X + CHASSIS_Y*CHASSIS_Y)/12.0}"
        ixy="0" ixz="0" iyz="0"/>
    </inertial>
  </link>

  <!-- ================================================================ -->
  <!--  Wheels (driven)                                                  -->
  <!-- ================================================================ -->
  <xacro:macro name="wheel" params="name y_sign">
    <link name="wheel_${name}_link">
      <visual>
        <origin xyz="0 0 0" rpy="${PI/2} 0 0"/>
        <geometry><cylinder radius="${WHEEL_R}" length="${WHEEL_T}"/></geometry>
        <material name="orion_black"/>
      </visual>
      <collision>
        <origin xyz="0 0 0" rpy="${PI/2} 0 0"/>
        <geometry><cylinder radius="${WHEEL_R}" length="${WHEEL_T}"/></geometry>
      </collision>
      <inertial>
        <mass value="${WHEEL_M}"/>
        <inertia
          ixx="${WHEEL_M*(3*WHEEL_R*WHEEL_R + WHEEL_T*WHEEL_T)/12.0}"
          iyy="${WHEEL_M*(3*WHEEL_R*WHEEL_R + WHEEL_T*WHEEL_T)/12.0}"
          izz="${WHEEL_M*WHEEL_R*WHEEL_R/2.0}"
          ixy="0" ixz="0" iyz="0"/>
      </inertial>
    </link>

    <joint name="wheel_${name}_joint" type="continuous">
      <parent link="base_link"/>
      <child  link="wheel_${name}_link"/>
      <origin xyz="0 ${y_sign*WHEEL_SEP/2} 0" rpy="0 0 0"/>
      <axis xyz="0 1 0"/>
      <dynamics damping="0.5" friction="0.2"/>
      <limit effort="10.0" velocity="20.0"/>
    </joint>

    <gazebo reference="wheel_${name}_link">
      <mu1>1.0</mu1>
      <mu2>0.5</mu2>
      <kp>1000000.0</kp>
      <kd>10.0</kd>
      <minDepth>0.001</minDepth>
      <maxVel>0.1</maxVel>
      <fdir1>1 0 0</fdir1>
      <material>Gazebo/Black</material>
    </gazebo>
  </xacro:macro>

  <xacro:wheel name="left"  y_sign="1"/>
  <xacro:wheel name="right" y_sign="-1"/>

  <!-- ================================================================ -->
  <!--  Caster (passive front sphere - frictionless to swivel freely)    -->
  <!-- ================================================================ -->
  <link name="caster_link">
    <visual>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><sphere radius="${CASTER_R}"/></geometry>
      <material name="orion_grey"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><sphere radius="${CASTER_R}"/></geometry>
    </collision>
    <inertial>
      <mass value="${CASTER_M}"/>
      <inertia ixx="${2*CASTER_M*CASTER_R*CASTER_R/5.0}"
               iyy="${2*CASTER_M*CASTER_R*CASTER_R/5.0}"
               izz="${2*CASTER_M*CASTER_R*CASTER_R/5.0}"
               ixy="0" ixz="0" iyz="0"/>
    </inertial>
  </link>

  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="caster_link"/>
    <!-- caster sits in front, with sphere bottom flush on ground:
         base_link is at world z=WHEEL_R (=0.05). To put sphere
         bottom at z=0, sphere centre must be at world z=CASTER_R.
         So the joint origin in base_link frame is z = CASTER_R - WHEEL_R.  -->
    <origin xyz="0.110 0 ${CASTER_R - WHEEL_R}" rpy="0 0 0"/>
  </joint>

  <gazebo reference="caster_link">
    <mu1>0.0</mu1>
    <mu2>0.0</mu2>
    <kp>1000000.0</kp>
    <kd>1.0</kd>
    <material>Gazebo/Grey</material>
  </gazebo>

  <!-- ================================================================ -->
  <!--  IMU                                                              -->
  <!-- ================================================================ -->
  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="imu_link"/>
    <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
  </joint>

  <gazebo reference="imu_link">
    <gravity>true</gravity>
    <sensor name="orion_imu" type="imu">
      <always_on>true</always_on>
      <update_rate>100</update_rate>
      <visualize>false</visualize>
      <imu>
        <angular_velocity>
          <x><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></x>
          <y><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></y>
          <z><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></z>
        </angular_velocity>
        <linear_acceleration>
          <x><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></x>
          <y><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></y>
          <z><noise type="gaussian"><mean>0.0</mean><stddev>0.0</stddev></noise></z>
        </linear_acceleration>
      </imu>
      <plugin name="orion_imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros>
          <namespace>/orion</namespace>
          <remapping>~/out:=imu</remapping>
        </ros>
        <initial_orientation_as_reference>false</initial_orientation_as_reference>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>

  <!-- ================================================================ -->
  <!--  Beacon (decorative amber hat - identifies the AGV in the scene)  -->
  <!-- ================================================================ -->
  <link name="beacon_link">
    <visual>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><cylinder radius="0.025" length="0.04"/></geometry>
      <material name="orion_amber"/>
    </visual>
    <inertial>
      <mass value="0.01"/>
      <inertia ixx="0.00001" iyy="0.00001" izz="0.00001" ixy="0" ixz="0" iyz="0"/>
    </inertial>
  </link>
  <joint name="beacon_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="beacon_link"/>
    <origin xyz="-0.10 0 ${CHASSIS_Z + 0.020}" rpy="0 0 0"/>
  </joint>
  <gazebo reference="beacon_link"><material>Gazebo/Orange</material></gazebo>

  <!-- ================================================================ -->
  <!--  Differential drive plugin (single subscriber on /orion/cmd_vel)  -->
  <!-- ================================================================ -->
  <gazebo>
    <plugin name="orion_diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros>
        <namespace>/orion</namespace>
        <remapping>cmd_vel:=cmd_vel</remapping>
        <remapping>odom:=odom</remapping>
      </ros>
      <update_rate>50</update_rate>
      <left_joint>wheel_left_joint</left_joint>
      <right_joint>wheel_right_joint</right_joint>
      <wheel_separation>${WHEEL_SEP}</wheel_separation>
      <wheel_diameter>${2*WHEEL_R}</wheel_diameter>
      <max_wheel_torque>5.0</max_wheel_torque>
      <max_wheel_acceleration>2.0</max_wheel_acceleration>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>true</publish_wheel_tf>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
    </plugin>
  </gazebo>

  <gazebo>
    <plugin name="orion_joint_state" filename="libgazebo_ros_joint_state_publisher.so">
      <ros>
        <namespace>/orion</namespace>
        <remapping>~/out:=joint_states</remapping>
      </ros>
      <update_rate>50</update_rate>
      <joint_name>wheel_left_joint</joint_name>
      <joint_name>wheel_right_joint</joint_name>
    </plugin>
  </gazebo>

  <gazebo reference="base_link"><material>Gazebo/Blue</material></gazebo>

</robot>
EOF

cat > orion_robot/launch/spawn.launch.py <<'PYEOF'
"""Spawns the ORION AGV at the HOME station inside an already-running Gazebo."""
import os
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import Command, LaunchConfiguration
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_share = get_package_share_directory('orion_robot')
    urdf_xacro = os.path.join(pkg_share, 'urdf', 'orion_agv.urdf.xacro')

    # HOME pose: x=0, y=-1, yaw=pi/2 (face +Y along the spine).
    x_arg   = DeclareLaunchArgument('x',   default_value='0.0')
    y_arg   = DeclareLaunchArgument('y',   default_value='-1.0')
    z_arg   = DeclareLaunchArgument('z',   default_value='0.01')
    yaw_arg = DeclareLaunchArgument('yaw', default_value='1.5708')

    robot_description = Command(['xacro ', urdf_xacro])

    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        name='robot_state_publisher',
        namespace='orion',
        output='screen',
        parameters=[{
            'use_sim_time': True,
            'robot_description': robot_description,
        }],
    )

    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        name='spawn_orion_agv',
        output='screen',
        arguments=[
            '-entity', 'orion_agv',
            '-topic', '/orion/robot_description',
            '-x', LaunchConfiguration('x'),
            '-y', LaunchConfiguration('y'),
            '-z', LaunchConfiguration('z'),
            '-Y', LaunchConfiguration('yaw'),
        ],
    )

    return LaunchDescription([x_arg, y_arg, z_arg, yaw_arg, rsp, spawn])
PYEOF

cat > orion_robot/rviz/orion.rviz <<'EOF'
Panels:
  - Class: rviz_common/Displays
    Name: Displays
  - Class: rviz_common/Views
    Name: Views
Visualization Manager:
  Class: ""
  Displays:
    - Class: rviz_default_plugins/Grid
      Name: Grid
      Reference Frame: <Fixed Frame>
      Enabled: true
    - Class: rviz_default_plugins/RobotModel
      Name: RobotModel
      Description Topic:
        Value: /orion/robot_description
      Enabled: true
    - Class: rviz_default_plugins/TF
      Name: TF
      Enabled: true
      Show Names: true
    - Class: rviz_default_plugins/Odometry
      Name: Odometry
      Topic:
        Value: /orion/odom
      Enabled: true
  Global Options:
    Fixed Frame: odom
    Background Color: 48; 48; 48
  Tools:
    - Class: rviz_default_plugins/Interact
    - Class: rviz_default_plugins/MoveCamera
  Views:
    Current:
      Class: rviz_default_plugins/Orbit
      Distance: 4.0
      Pitch: 0.6
      Yaw: 1.5708
      Focal Point: {X: 0, Y: 4, Z: 0}
Window Geometry:
  Height: 800
  Width: 1200
EOF

cat > orion_robot/config/orion_params.yaml <<'EOF'
# Reserved for future per-robot parameter overrides loaded by mission_manager.
# Currently empty - all runtime parameters live in their respective nodes.
orion: {}
EOF
ok "orion_robot files written."


# ============================================================================
# PHASE 6 : PACKAGE orion_core (Python - controllers, manager, GUI, CLI)
# ============================================================================
section "PHASE 6 - orion_core (skeleton)"

mkdir -p orion_core/orion_core orion_core/resource orion_core/test
touch orion_core/resource/orion_core
touch orion_core/orion_core/__init__.py

cat > orion_core/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_core</name>
  <version>1.0.0</version>
  <description>ORION runtime nodes: mission manager (sole cmd_vel arbiter),
    line / turn / pivot controllers, virtual optical sensor array, simulated
    RFID reader, PyQt5 dashboard, CLI tools, heartbeat monitor.</description>
  <maintainer email="orion@example.com">orion</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <depend>rclpy</depend>
  <depend>std_msgs</depend>
  <depend>geometry_msgs</depend>
  <depend>nav_msgs</depend>
  <depend>sensor_msgs</depend>
  <depend>tf2_ros</depend>
  <depend>orion_msgs</depend>

  <exec_depend>python3-pyqt5</exec_depend>
  <exec_depend>tf_transformations</exec_depend>

  <export>
    <build_type>ament_python</build_type>
  </export>
</package>
EOF

cat > orion_core/setup.cfg <<'EOF'
[develop]
script_dir=$base/lib/orion_core
[install]
install_scripts=$base/lib/orion_core
EOF

cat > orion_core/setup.py <<'EOF'
from setuptools import setup

package_name = 'orion_core'

setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
         ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='orion',
    maintainer_email='orion@example.com',
    description='ORION runtime nodes for warehouse AGV simulation.',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'mission_manager   = orion_core.mission_manager:main',
            'line_controller   = orion_core.line_controller:main',
            'turn_controller   = orion_core.turn_controller:main',
            'pivot_controller  = orion_core.pivot_controller:main',
            'optical_sensor    = orion_core.optical_sensor:main',
            'rfid_system       = orion_core.rfid_system:main',
            'gui_dashboard     = orion_core.gui_dashboard:main',
            'send_mission      = orion_core.send_mission:main',
            'heartbeat_monitor = orion_core.heartbeat_monitor:main',
        ],
    },
)
EOF
ok "orion_core skeleton written."


# ---------- track_geometry.py (shared static line/shelf data) ----------
cat > orion_core/orion_core/track_geometry.py <<'PYEOF'
"""
Shared geometric primitives for the ORION line network.

Defines:
    * The world-frame line segments laid out by orion_world.
    * The shelf catalogue (S01 .. S20) with aisle index and (x, y) location.
    * Coordinate conversions between /orion/odom and the gazebo world.
    * Quaternion -> yaw and signed yaw difference helpers.
    * Point-to-segment distance utilities used by the optical sensor.

Coordinate conventions
----------------------
World (gazebo)   : right-hand frame, +X east, +Y north, +Z up. Used by
                   the warehouse generator and by anything that talks
                   about absolute positions.
Robot odom       : published by gazebo_ros_diff_drive starting at the
                   robot's spawn pose. The odom origin is therefore the
                   spawn point, not the world origin. Conversion is a
                   rigid 2D transform driven by SPAWN_X/Y/YAW below.
"""
import math

# Spawn pose - MUST match orion_robot/launch/spawn.launch.py defaults
SPAWN_X    = 0.0
SPAWN_Y    = -1.0
SPAWN_YAW  = math.pi / 2.0    # face +Y (along the spine)

# HOME station (red RFID pad)
HOME_X     = 0.0
HOME_Y     = -1.0
HOME_TAG   = "RFID-HOME"

# Spine + aisles in world coords
SPINE          = ((0.0, -1.0), (0.0, 11.0))
AISLE_Y_LIST   = [1.0, 3.0, 5.0, 7.0, 9.0]
AISLE_X_END    = 4.0
AISLES         = [((0.0, y), (AISLE_X_END, y)) for y in AISLE_Y_LIST]
ALL_SEGMENTS   = [SPINE] + AISLES

# Shelf catalogue: S01..S20  ->  (x, y, aisle_index 1..5)
SHELF_X_OFFSETS = [1.0, 1.8, 2.6, 3.4]
SHELVES = {}
_idx = 1
for _ai, _ay in enumerate(AISLE_Y_LIST, start=1):
    for _sx in SHELF_X_OFFSETS:
        SHELVES[f"S{_idx:02d}"] = (_sx, _ay, _ai)
        _idx += 1
SHELF_IDS = sorted(SHELVES.keys())


def aisle_for_shelf(shelf_id: str) -> int:
    if shelf_id not in SHELVES:
        raise ValueError(f"Unknown shelf '{shelf_id}'")
    return SHELVES[shelf_id][2]


def shelf_world_xy(shelf_id: str):
    return SHELVES[shelf_id][0], SHELVES[shelf_id][1]


def wrap_pi(a: float) -> float:
    """Wrap an angle to (-pi, pi]."""
    return math.atan2(math.sin(a), math.cos(a))


def angle_diff(target: float, current: float) -> float:
    """Smallest signed delta from current to target."""
    return wrap_pi(target - current)


def quat_to_yaw(qx: float, qy: float, qz: float, qw: float) -> float:
    """Yaw of a unit quaternion (z-axis rotation)."""
    return math.atan2(2.0 * (qw * qz + qx * qy),
                      1.0 - 2.0 * (qy * qy + qz * qz))


def odom_to_world(ox: float, oy: float, oyaw: float):
    """Rigid 2D transform odom -> world using the spawn pose."""
    cs = math.cos(SPAWN_YAW)
    sn = math.sin(SPAWN_YAW)
    wx = SPAWN_X + cs * ox - sn * oy
    wy = SPAWN_Y + sn * ox + cs * oy
    wyaw = wrap_pi(SPAWN_YAW + oyaw)
    return wx, wy, wyaw


def distance_point_to_segment(px, py, x1, y1, x2, y2) -> float:
    dx = x2 - x1
    dy = y2 - y1
    if dx == 0.0 and dy == 0.0:
        return math.hypot(px - x1, py - y1)
    t = ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    fx = x1 + t * dx
    fy = y1 + t * dy
    return math.hypot(px - fx, py - fy)


def min_distance_to_lines(px, py, segments=ALL_SEGMENTS) -> float:
    return min(distance_point_to_segment(px, py, s[0][0], s[0][1],
                                         s[1][0], s[1][1])
               for s in segments)
PYEOF

# ---------- optical_sensor.py (8 virtual IR sensors @ 50 Hz) ----------
cat > orion_core/orion_core/optical_sensor.py <<'PYEOF'
"""
Virtual 8-element IR sensor bar.

Layout (looking down at the robot, robot facing +X in body frame)
    sensor 0 (left-most)  ........ sensor 7 (right-most)
    body Y = +0.080  +0.055  +0.030  +0.010  -0.010  -0.030  -0.055  -0.080
    body X = +0.10 (10 cm in front of base_link, on the floor projection)

Each sensor returns 1 if the closest distance from its world-frame footprint
to any guide-line segment is <= LINE_WIDTH / 2, else 0.

Sensor spacing is wider than LINE_WIDTH so that on a straight line only the
two innermost sensors fire (clean PID error signal). At an intersection,
the perpendicular line crosses through the bottom side of the bar and many
sensors fire at once, producing the junction signature (>= 5 hits).

Outputs
-------
/orion/sensors          std_msgs/Int8MultiArray   8-element {0,1} array
/orion/sensors_raw      std_msgs/Float32MultiArray 8-element distances [m]
/orion/junction_event   std_msgs/Empty             one-shot when junction detected
"""
import math
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from nav_msgs.msg import Odometry
from std_msgs.msg import Int8MultiArray, Float32MultiArray, Empty

from orion_core.track_geometry import (
    odom_to_world, quat_to_yaw, min_distance_to_lines,
)

LINE_WIDTH         = 0.040
SENSOR_X           = 0.100
SENSOR_Y_OFFSETS   = [0.080, 0.055, 0.030, 0.010,
                     -0.010, -0.030, -0.055, -0.080]
JUNCTION_THRESHOLD = 5
JUNCTION_CONFIRM   = 2
JUNCTION_COOLDOWN  = 1.5
RATE_HZ            = 50.0


class OpticalSensor(Node):
    def __init__(self):
        super().__init__('orion_optical_sensor')
        qos = QoSProfile(depth=20, reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(Odometry, '/orion/odom', self.odom_cb, qos)
        self.pub_sensors  = self.create_publisher(Int8MultiArray,    '/orion/sensors',        10)
        self.pub_raw      = self.create_publisher(Float32MultiArray, '/orion/sensors_raw',    10)
        self.pub_junction = self.create_publisher(Empty,             '/orion/junction_event', 10)
        self.timer = self.create_timer(1.0 / RATE_HZ, self.tick)
        self.have_odom = False
        self.wx = self.wy = 0.0
        self.wyaw = 0.0
        self.confirm_streak = 0
        self.last_junction_t = 0.0
        self.get_logger().info(
            f'optical_sensor: 8 IR @ {RATE_HZ:.0f}Hz, '
            f'line_width={LINE_WIDTH}, junc_thresh={JUNCTION_THRESHOLD}')

    def odom_cb(self, msg: Odometry):
        ox = msg.pose.pose.position.x
        oy = msg.pose.pose.position.y
        q = msg.pose.pose.orientation
        oyaw = quat_to_yaw(q.x, q.y, q.z, q.w)
        self.wx, self.wy, self.wyaw = odom_to_world(ox, oy, oyaw)
        self.have_odom = True

    def tick(self):
        if not self.have_odom:
            return
        cs = math.cos(self.wyaw)
        sn = math.sin(self.wyaw)
        readings = []
        raw = []
        half = LINE_WIDTH / 2.0
        for off in SENSOR_Y_OFFSETS:
            sx = self.wx + cs * SENSOR_X - sn * off
            sy = self.wy + sn * SENSOR_X + cs * off
            d = min_distance_to_lines(sx, sy)
            raw.append(d)
            readings.append(1 if d <= half else 0)

        m_bin = Int8MultiArray()
        m_bin.data = readings
        self.pub_sensors.publish(m_bin)

        m_raw = Float32MultiArray()
        m_raw.data = [float(v) for v in raw]
        self.pub_raw.publish(m_raw)

        # junction detection (sensor pattern)
        now = self.get_clock().now().nanoseconds * 1e-9
        if sum(readings) >= JUNCTION_THRESHOLD:
            self.confirm_streak += 1
        else:
            self.confirm_streak = 0
        if (self.confirm_streak >= JUNCTION_CONFIRM
                and (now - self.last_junction_t) > JUNCTION_COOLDOWN):
            self.last_junction_t = now
            self.confirm_streak = 0
            self.pub_junction.publish(Empty())
            self.get_logger().info(
                f'JUNCTION at world ({self.wx:+.2f}, {self.wy:+.2f})')


def main(args=None):
    rclpy.init(args=args)
    node = OpticalSensor()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# ---------- line_controller.py (PID line follower) ----------
cat > orion_core/orion_core/line_controller.py <<'PYEOF'
"""
PID line follower.

Reads the 8-element binary IR array on /orion/sensors and publishes a
geometry_msgs/Twist on /orion/follow_vel at 50 Hz. Mission manager is
the sole consumer that may forward this onto /orion/cmd_vel.

Error definition (body frame):
    weight[i] is the normalised body-Y position of sensor i.
    error = sum(weight[i] * reading[i]) / sum(reading[i])
    error in (-1, +1). Positive error = line is to the LEFT of robot
    centre, so the robot must turn LEFT (positive angular_z).

PID:
    kp = 0.50, ki = 0.00, kd = 0.15, linear = 0.50 m/s
    Error stays normalised, never scaled artificially.

Line-loss handling:
    If no sensor sees the line, the controller continues with the last
    successful twist for GRACE_FRAMES frames (~1.6 s). After that it
    publishes zero velocity.
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Int8MultiArray
from geometry_msgs.msg import Twist

LINEAR_SPEED   = 0.50
KP             = 0.50
KI             = 0.00
KD             = 0.15
RATE_HZ        = 50.0
GRACE_FRAMES   = 80

# left side positive (so positive error == line is on the left)
SENSOR_WEIGHTS = [+1.00, +0.71, +0.43, +0.14,
                  -0.14, -0.43, -0.71, -1.00]


class LineController(Node):
    def __init__(self):
        super().__init__('orion_line_controller')
        self.create_subscription(Int8MultiArray, '/orion/sensors', self.cb, 10)
        self.pub = self.create_publisher(Twist, '/orion/follow_vel', 10)
        self.timer = self.create_timer(1.0 / RATE_HZ, self.tick)
        self.last_error = 0.0
        self.integral   = 0.0
        self.lost = GRACE_FRAMES + 1
        self.last_tw = Twist()
        self.have = False
        self.get_logger().info(
            f'line_controller: kp={KP}, ki={KI}, kd={KD}, '
            f'v={LINEAR_SPEED} m/s, grace={GRACE_FRAMES} frames')

    def cb(self, msg: Int8MultiArray):
        readings = list(msg.data)
        if len(readings) != 8:
            return
        total = sum(readings)
        if total == 0:
            self.lost += 1
            return
        error = sum(SENSOR_WEIGHTS[i] * readings[i] for i in range(8)) / float(total)
        derivative = error - self.last_error
        self.last_error = error
        self.integral = max(-1.0, min(1.0, self.integral + error / RATE_HZ))
        self.lost = 0
        ang = KP * error + KI * self.integral + KD * derivative
        tw = Twist()
        tw.linear.x = LINEAR_SPEED
        tw.angular.z = ang
        self.last_tw = tw
        self.have = True

    def tick(self):
        if not self.have:
            self.pub.publish(Twist())
            return
        if self.lost > GRACE_FRAMES:
            self.pub.publish(Twist())
        else:
            self.pub.publish(self.last_tw)


def main(args=None):
    rclpy.init(args=args)
    node = LineController()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# ---------- turn_controller.py (IMU-based 90 deg turn) ----------
cat > orion_core/orion_core/turn_controller.py <<'PYEOF'
"""
IMU yaw-based 90 degree turn controller.

Subscribers
-----------
/orion/imu        sensor_msgs/Imu        current orientation
/orion/turn_cmd   std_msgs/Float32       signed delta yaw [rad] (eg -1.5708 for right)

Publishers
----------
/orion/turn_vel   geometry_msgs/Twist    angular only, fixed magnitude
/orion/turn_done  std_msgs/Empty         emitted once on completion

Algorithm
---------
On receiving a turn_cmd:
    target_yaw = wrap_pi(current_yaw + delta)
    direction  = sign(delta)
At each tick:
    err = angle_diff(target_yaw, current_yaw)
    if |err| < TOLERANCE: stop, fire turn_done
    else angular_z = direction * TURN_SPEED
"""
import math
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Imu
from std_msgs.msg import Float32, Empty
from geometry_msgs.msg import Twist
from orion_core.track_geometry import quat_to_yaw, angle_diff, wrap_pi

TURN_SPEED = 0.5
TOLERANCE  = math.radians(3.0)
RATE_HZ    = 50.0


class TurnController(Node):
    def __init__(self):
        super().__init__('orion_turn_controller')
        self.create_subscription(Imu,     '/orion/imu',      self.imu_cb, 10)
        self.create_subscription(Float32, '/orion/turn_cmd', self.cmd_cb, 10)
        self.pub_vel  = self.create_publisher(Twist, '/orion/turn_vel',  10)
        self.pub_done = self.create_publisher(Empty, '/orion/turn_done', 10)
        self.timer = self.create_timer(1.0 / RATE_HZ, self.tick)
        self.cur_yaw = 0.0
        self.tgt_yaw = 0.0
        self.dir = 0.0
        self.have_imu = False
        self.active = False
        self.get_logger().info(
            f'turn_controller: speed={TURN_SPEED} rad/s, '
            f'tol={math.degrees(TOLERANCE):.1f} deg')

    def imu_cb(self, msg: Imu):
        q = msg.orientation
        self.cur_yaw = quat_to_yaw(q.x, q.y, q.z, q.w)
        self.have_imu = True

    def cmd_cb(self, msg: Float32):
        if not self.have_imu:
            self.get_logger().warn('turn_cmd received before any IMU data')
            return
        delta = float(msg.data)
        self.tgt_yaw = wrap_pi(self.cur_yaw + delta)
        self.dir = 1.0 if delta > 0 else -1.0
        self.active = True
        self.get_logger().info(
            f'turn delta={math.degrees(delta):+.1f} deg, '
            f'target={math.degrees(self.tgt_yaw):+.1f} deg')

    def tick(self):
        tw = Twist()
        if self.active and self.have_imu:
            err = angle_diff(self.tgt_yaw, self.cur_yaw)
            if abs(err) < TOLERANCE:
                self.active = False
                self.pub_vel.publish(Twist())
                self.pub_done.publish(Empty())
                self.get_logger().info('turn complete')
                return
            tw.angular.z = self.dir * TURN_SPEED
        self.pub_vel.publish(tw)


def main(args=None):
    rclpy.init(args=args)
    node = TurnController()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# ---------- pivot_controller.py (IMU-based 180 deg pivot) ----------
cat > orion_core/orion_core/pivot_controller.py <<'PYEOF'
"""
IMU yaw-based 180 deg pivot controller.

Subscribers
-----------
/orion/imu        sensor_msgs/Imu     current orientation
/orion/pivot_cmd  std_msgs/Empty      start a 180 deg CCW pivot

Publishers
----------
/orion/pivot_vel  geometry_msgs/Twist
/orion/pivot_done std_msgs/Empty

Direction is fixed CCW (positive angular_z).
"""
import math
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Imu
from std_msgs.msg import Empty
from geometry_msgs.msg import Twist
from orion_core.track_geometry import quat_to_yaw, angle_diff, wrap_pi

PIVOT_SPEED = 0.5
TOLERANCE   = math.radians(3.0)
RATE_HZ     = 50.0


class PivotController(Node):
    def __init__(self):
        super().__init__('orion_pivot_controller')
        self.create_subscription(Imu,   '/orion/imu',       self.imu_cb, 10)
        self.create_subscription(Empty, '/orion/pivot_cmd', self.cmd_cb, 10)
        self.pub_vel  = self.create_publisher(Twist, '/orion/pivot_vel',  10)
        self.pub_done = self.create_publisher(Empty, '/orion/pivot_done', 10)
        self.timer = self.create_timer(1.0 / RATE_HZ, self.tick)
        self.cur_yaw = 0.0
        self.tgt_yaw = 0.0
        self.have_imu = False
        self.active = False
        self.get_logger().info(
            f'pivot_controller: 180 deg CCW @ {PIVOT_SPEED} rad/s')

    def imu_cb(self, msg: Imu):
        q = msg.orientation
        self.cur_yaw = quat_to_yaw(q.x, q.y, q.z, q.w)
        self.have_imu = True

    def cmd_cb(self, _msg: Empty):
        if not self.have_imu:
            self.get_logger().warn('pivot_cmd received before any IMU data')
            return
        self.tgt_yaw = wrap_pi(self.cur_yaw + math.pi)
        self.active = True
        self.get_logger().info(
            f'pivot start, target={math.degrees(self.tgt_yaw):+.1f} deg')

    def tick(self):
        tw = Twist()
        if self.active and self.have_imu:
            err = angle_diff(self.tgt_yaw, self.cur_yaw)
            if abs(err) < TOLERANCE:
                self.active = False
                self.pub_vel.publish(Twist())
                self.pub_done.publish(Empty())
                self.get_logger().info('pivot complete')
                return
            tw.angular.z = PIVOT_SPEED
        self.pub_vel.publish(tw)


def main(args=None):
    rclpy.init(args=args)
    node = PivotController()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
ok "track_geometry, optical_sensor, line/turn/pivot controllers written."


# ---------- rfid_system.py (pose-based simulated RFID reader) ----------
cat > orion_core/orion_core/rfid_system.py <<'PYEOF'
"""
Simulated RFID reader.

Subscribes to /orion/odom, converts to world coordinates, and computes the
distance to every catalogued floor tag at 50 Hz. A tag fires when the robot
is within DETECTION_RADIUS and the tag is currently armed; it then disarms
and only re-arms once the robot has moved at least REARM_DISTANCE away.

Tags
----
RFID-S01 .. RFID-S20  : one per shelf, located on the aisle line directly
                        in front of the shelf.
RFID-HOME             : at the HOME station.
"""
import math
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from nav_msgs.msg import Odometry
from orion_msgs.msg import RFIDEvent
from orion_core.track_geometry import (
    odom_to_world, SHELVES, HOME_X, HOME_Y, HOME_TAG,
)

DETECTION_RADIUS = 0.60
REARM_DISTANCE   = 0.90
RATE_HZ          = 50.0


class RFIDSystem(Node):
    def __init__(self):
        super().__init__('orion_rfid_system')
        qos = QoSProfile(depth=50, reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(Odometry, '/orion/odom', self.odom_cb, qos)
        self.pub = self.create_publisher(RFIDEvent, '/orion/rfid_event', 10)
        self.create_timer(1.0 / RATE_HZ, self.tick)

        # tag layout: list of dicts { id, shelf_id, x, y, is_home, armed }
        self.tags = []
        for sid, (x, y, _ai) in SHELVES.items():
            self.tags.append({'id': f'RFID-{sid}', 'shelf': sid,
                              'x': x, 'y': y, 'home': False, 'armed': True})
        self.tags.append({'id': HOME_TAG, 'shelf': '',
                          'x': HOME_X, 'y': HOME_Y, 'home': True, 'armed': True})

        self.have_pose = False
        self.rx = self.ry = 0.0
        self.get_logger().info(
            f'rfid_system: {len(self.tags)} tags, '
            f'R={DETECTION_RADIUS} m, rearm={REARM_DISTANCE} m')

    def odom_cb(self, msg: Odometry):
        wx, wy, _ = odom_to_world(msg.pose.pose.position.x,
                                  msg.pose.pose.position.y, 0.0)
        self.rx, self.ry = wx, wy
        self.have_pose = True

    def tick(self):
        if not self.have_pose:
            return
        for t in self.tags:
            d = math.hypot(self.rx - t['x'], self.ry - t['y'])
            if t['armed'] and d <= DETECTION_RADIUS:
                ev = RFIDEvent()
                ev.tag_id = t['id']
                ev.shelf_id = t['shelf']
                ev.distance = float(d)
                ev.is_home = bool(t['home'])
                ev.stamp = self.get_clock().now().to_msg()
                self.pub.publish(ev)
                t['armed'] = False
                self.get_logger().info(f"RFID HIT {t['id']} (d={d:.2f} m)")
            elif (not t['armed']) and d > REARM_DISTANCE:
                t['armed'] = True


def main(args=None):
    rclpy.init(args=args)
    node = RFIDSystem()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# ---------- mission_manager.py (state machine + sole cmd_vel arbiter) ----------
cat > orion_core/orion_core/mission_manager.py <<'PYEOF'
"""
ORION mission manager.

This is the SOLE node permitted to publish on /orion/cmd_vel. All other
controllers publish to private velocity topics that this manager forwards
selectively based on the current state.

Velocity arbitration table
--------------------------
state           | source forwarded to /orion/cmd_vel
----------------+-----------------------------------
IDLE            | Twist() (zero)
NAVIGATING      | /orion/follow_vel   (line PID)
TURNING         | /orion/turn_vel     (IMU 90 deg)
AT_SHELF        | Twist()
LOADING         | Twist()
PIVOTING        | /orion/pivot_vel    (IMU 180 deg)
PIVOT_NUDGE     | fixed (linear.x=0.20, angular.z=0)
RETURNING       | /orion/follow_vel
DOCKED          | Twist()
ERROR           | Twist()

State machine transitions
-------------------------
IDLE          --(mission popped)----------> NAVIGATING (OUTBOUND_SPINE)
NAVIGATING/OUTBOUND_SPINE  --(junction#==target_aisle)--> TURNING (OUT_SPINE)
TURNING/OUT_SPINE  --(turn_done)--> NAVIGATING (OUTBOUND_AISLE)
NAVIGATING/OUTBOUND_AISLE --(RFID match)--> AT_SHELF
AT_SHELF      --(SETTLE_DURATION)-----------> LOADING
LOADING       --(LOADING_DURATION)----------> PIVOTING (carrying=True)
PIVOTING      --(pivot_done)-----------------> PIVOT_NUDGE
PIVOT_NUDGE   --(NUDGE_DURATION)------------> RETURNING (RETURN_AISLE)
RETURNING/RETURN_AISLE --(junction)--------> TURNING (RET_AISLE)
TURNING/RET_AISLE --(turn_done)-------------> RETURNING (RETURN_SPINE)
RETURNING/RETURN_SPINE --(HOME RFID)--------> DOCKED
DOCKED        --(DOCK_DURATION)-------------> IDLE (carrying=False)
ANY           --(/orion/estop)--------------> ERROR
ANY           --(/orion/reset)--------------> IDLE
"""
import math
import uuid
import rclpy
from rclpy.node import Node

from std_msgs.msg import Empty, Float32, String
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry

from orion_msgs.msg import Mission, RFIDEvent, RobotStatus
from orion_core.track_geometry import (
    aisle_for_shelf, odom_to_world, SHELVES,
)

# ---- States (see RobotStatus.msg) ----
S_IDLE        = 'IDLE'
S_NAVIGATING  = 'NAVIGATING'
S_TURNING     = 'TURNING'
S_AT_SHELF    = 'AT_SHELF'
S_LOADING     = 'LOADING'
S_PIVOTING    = 'PIVOTING'
S_PIVOT_NUDGE = 'PIVOT_NUDGE'
S_RETURNING   = 'RETURNING'
S_DOCKED      = 'DOCKED'
S_ERROR       = 'ERROR'

# ---- Phases (sub-states inside NAVIGATING/TURNING/RETURNING) ----
P_OUT_SPINE  = 'OUTBOUND_SPINE'
P_OUT_AISLE  = 'OUTBOUND_AISLE'
P_RET_AISLE  = 'RETURN_AISLE'
P_RET_SPINE  = 'RETURN_SPINE'

# ---- Timing / control constants ----
RATE_HZ          = 50.0
STATUS_HZ        = 10.0
SETTLE_DURATION  = 0.5
LOADING_DURATION = 3.0
NUDGE_DURATION   = 0.75
NUDGE_SPEED      = 0.20
DOCK_DURATION    = 1.0
RIGHT_TURN_DELTA = -math.pi / 2.0   # outbound: spine -> aisle (yaw +pi/2 -> 0)
LEFT_TURN_DELTA  = +math.pi / 2.0   # return:   aisle -> spine (yaw +pi  -> -pi/2)
BATTERY_DRAIN_PER_MIN = 0.5    # %


class MissionManager(Node):
    def __init__(self):
        super().__init__('orion_mission_manager')

        # ---------- inputs from controllers ----------
        self.create_subscription(Twist,     '/orion/follow_vel',     self._fv_cb,     10)
        self.create_subscription(Twist,     '/orion/turn_vel',       self._tv_cb,     10)
        self.create_subscription(Twist,     '/orion/pivot_vel',      self._pv_cb,     10)
        self.create_subscription(Empty,     '/orion/turn_done',      self._turn_done, 10)
        self.create_subscription(Empty,     '/orion/pivot_done',     self._pivot_done,10)
        self.create_subscription(Empty,     '/orion/junction_event', self._junction,  10)
        self.create_subscription(RFIDEvent, '/orion/rfid_event',     self._rfid,      10)
        self.create_subscription(Odometry,  '/orion/odom',           self._odom,      10)

        # ---------- mission / control inputs ----------
        self.create_subscription(Mission, '/orion/mission',     self._mission,    10)
        self.create_subscription(Empty,   '/orion/estop',       self._estop,      10)
        self.create_subscription(Empty,   '/orion/reset',       self._reset,      10)
        self.create_subscription(Empty,   '/orion/clear_queue', self._clear,      10)
        self.create_subscription(Empty,   '/orion/return_home', self._return,     10)

        # ---------- outputs ----------
        self.pub_cmd       = self.create_publisher(Twist,       '/orion/cmd_vel',   10)
        self.pub_turn_cmd  = self.create_publisher(Float32,     '/orion/turn_cmd',  10)
        self.pub_pivot_cmd = self.create_publisher(Empty,       '/orion/pivot_cmd', 10)
        self.pub_status    = self.create_publisher(RobotStatus, '/orion/status',    10)
        self.pub_log       = self.create_publisher(String,      '/orion/event_log', 10)

        # ---------- timers ----------
        self.create_timer(1.0 / RATE_HZ,   self._arbiter_tick)
        self.create_timer(1.0 / STATUS_HZ, self._status_tick)

        # ---------- mutable state ----------
        self.state = S_IDLE
        self.phase = ''
        self.queue = []
        self.active = None
        self.junction_count = 0
        self.last_state_change = self._now()
        self.battery_last_t = self._now()
        self.fv = Twist(); self.tv = Twist(); self.pv = Twist()
        self.last_rfid = ''
        self.battery = 100.0
        self.carrying = False
        self.robot_x = 0.0
        self.robot_y = 0.0
        self.estopped = False

        self.get_logger().info('mission_manager up - sole writer on /orion/cmd_vel')

    # ====================================================================
    # internal helpers
    # ====================================================================
    def _now(self):
        return self.get_clock().now().nanoseconds * 1e-9

    def _log(self, txt):
        self.get_logger().info(txt)
        m = String(); m.data = txt
        self.pub_log.publish(m)

    def _go(self, new_state, phase=''):
        if (new_state, phase) != (self.state, self.phase):
            self._log(f'STATE {self.state}({self.phase}) -> {new_state}({phase})')
            self.state, self.phase = new_state, phase
            self.last_state_change = self._now()

    def _send_turn(self, delta):
        m = Float32(); m.data = float(delta)
        self.pub_turn_cmd.publish(m)

    def _send_pivot(self):
        self.pub_pivot_cmd.publish(Empty())

    # ====================================================================
    # callbacks - velocity sources
    # ====================================================================
    def _fv_cb(self, msg): self.fv = msg
    def _tv_cb(self, msg): self.tv = msg
    def _pv_cb(self, msg): self.pv = msg

    def _odom(self, msg: Odometry):
        wx, wy, _ = odom_to_world(msg.pose.pose.position.x,
                                  msg.pose.pose.position.y, 0.0)
        self.robot_x, self.robot_y = wx, wy

    # ====================================================================
    # callbacks - mission control
    # ====================================================================
    def _mission(self, m: Mission):
        if not m.target_shelf:
            self._log('mission rejected: empty target_shelf'); return
        if m.target_shelf not in SHELVES:
            self._log(f'mission rejected: unknown shelf "{m.target_shelf}"'); return
        if not m.mission_id:
            m.mission_id = f'm-{uuid.uuid4().hex[:6]}'
        self.queue.append(m)
        self._log(f'mission queued: {m.mission_id} -> {m.target_shelf} '
                  f'sku="{m.sku}" prio={m.priority} (queue={len(self.queue)})')

    def _estop(self, _):
        self.estopped = True
        self.queue = []
        self._go(S_ERROR)
        self._log('EMERGENCY STOP engaged')

    def _reset(self, _):
        self.estopped = False
        self.queue = []
        self.active = None
        self.carrying = False
        self.battery = 100.0
        self.junction_count = 0
        self._go(S_IDLE)
        self._log('SYSTEM RESET')

    def _clear(self, _):
        self.queue = []
        self._log('mission queue cleared')

    def _return(self, _):
        if self.state == S_IDLE:
            self._log('return_home: already IDLE (presumed home)')
        else:
            self._log('return_home: current mission will complete normally')

    # ====================================================================
    # callbacks - sensor / controller events
    # ====================================================================
    def _junction(self, _):
        if self.state == S_NAVIGATING and self.phase == P_OUT_SPINE:
            self.junction_count += 1
            target = aisle_for_shelf(self.active.target_shelf)
            self._log(f'spine junction #{self.junction_count}/{target}')
            if self.junction_count >= target:
                self._send_turn(RIGHT_TURN_DELTA)
                self._go(S_TURNING, P_OUT_SPINE)
        elif self.state == S_RETURNING and self.phase == P_RET_AISLE:
            self._log('return junction (spine intersection) - turning LEFT toward HOME')
            self._send_turn(LEFT_TURN_DELTA)
            self._go(S_TURNING, P_RET_AISLE)

    def _rfid(self, ev: RFIDEvent):
        self.last_rfid = ev.tag_id
        if (self.state == S_NAVIGATING and self.phase == P_OUT_AISLE
                and not ev.is_home and self.active
                and ev.shelf_id == self.active.target_shelf):
            self._log(f'RFID match for target {ev.shelf_id} -> AT_SHELF')
            self._go(S_AT_SHELF)
        elif (self.state == S_RETURNING and self.phase == P_RET_SPINE
              and ev.is_home):
            self._log('HOME RFID detected -> DOCKED')
            self._go(S_DOCKED)

    def _turn_done(self, _):
        if self.state != S_TURNING:
            return
        if self.phase == P_OUT_SPINE:
            self._go(S_NAVIGATING, P_OUT_AISLE)
        elif self.phase == P_RET_AISLE:
            self._go(S_RETURNING, P_RET_SPINE)

    def _pivot_done(self, _):
        if self.state == S_PIVOTING:
            self._go(S_PIVOT_NUDGE)

    # ====================================================================
    # 50Hz arbiter - manages timeouts and writes /orion/cmd_vel
    # ====================================================================
    def _arbiter_tick(self):
        now = self._now()
        # battery decay during active operation
        dt = now - self.battery_last_t
        self.battery_last_t = now
        if self.state in (S_NAVIGATING, S_TURNING, S_PIVOTING,
                          S_PIVOT_NUDGE, S_RETURNING):
            self.battery = max(0.0, self.battery - BATTERY_DRAIN_PER_MIN * dt / 60.0)

        # time-based transitions
        if self.state == S_IDLE:
            if not self.estopped and self.queue:
                self.active = self.queue.pop(0)
                self.junction_count = 0
                self._go(S_NAVIGATING, P_OUT_SPINE)
                self._log(f'starting {self.active.mission_id} -> {self.active.target_shelf}')
        elif self.state == S_AT_SHELF:
            if (now - self.last_state_change) >= SETTLE_DURATION:
                self._go(S_LOADING)
        elif self.state == S_LOADING:
            if (now - self.last_state_change) >= LOADING_DURATION:
                self.carrying = True
                self._send_pivot()
                self._go(S_PIVOTING)
        elif self.state == S_PIVOT_NUDGE:
            if (now - self.last_state_change) >= NUDGE_DURATION:
                self._go(S_RETURNING, P_RET_AISLE)
        elif self.state == S_DOCKED:
            if (now - self.last_state_change) >= DOCK_DURATION:
                self.carrying = False
                self.battery = 100.0
                self.active = None
                self._go(S_IDLE)
                self._log('mission complete - docked')

        # arbiter: pick the velocity source
        out = Twist()
        if self.state in (S_NAVIGATING, S_RETURNING):
            out = self.fv
        elif self.state == S_TURNING:
            out = self.tv
        elif self.state == S_PIVOTING:
            out = self.pv
        elif self.state == S_PIVOT_NUDGE:
            out.linear.x = NUDGE_SPEED
        # IDLE / AT_SHELF / LOADING / DOCKED / ERROR -> zero
        if self.estopped or self.state == S_ERROR:
            out = Twist()
        self.pub_cmd.publish(out)

    # ====================================================================
    # 10Hz status broadcast
    # ====================================================================
    def _status_tick(self):
        s = RobotStatus()
        s.state            = self.state
        s.mission_id       = self.active.mission_id   if self.active else ''
        s.target_shelf     = self.active.target_shelf if self.active else ''
        s.current_sku      = self.active.sku          if self.active else ''
        s.last_rfid        = self.last_rfid
        s.carrying_load    = bool(self.carrying)
        s.battery_percent  = float(self.battery)
        self.pub_status.publish(s)


def main(args=None):
    rclpy.init(args=args)
    node = MissionManager()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF

# ---------- heartbeat_monitor.py ----------
cat > orion_core/orion_core/heartbeat_monitor.py <<'PYEOF'
"""
Watches critical /orion/* topics and publishes a /orion/health Bool.
Logs warnings when topics go stale (no message for STALE_AFTER seconds).
"""
import rclpy
from rclpy.node import Node

from std_msgs.msg import Bool, Int8MultiArray
from sensor_msgs.msg import Imu
from nav_msgs.msg import Odometry
from geometry_msgs.msg import Twist
from orion_msgs.msg import RobotStatus

WATCHED = (
    ('/orion/odom',       Odometry),
    ('/orion/imu',        Imu),
    ('/orion/sensors',    Int8MultiArray),
    ('/orion/follow_vel', Twist),
    ('/orion/cmd_vel',    Twist),
    ('/orion/status',     RobotStatus),
)
STALE_AFTER = 2.0


class Heartbeat(Node):
    def __init__(self):
        super().__init__('orion_heartbeat')
        self.last = {topic: 0.0 for topic, _ in WATCHED}
        for topic, msg_type in WATCHED:
            self.create_subscription(
                msg_type, topic,
                lambda _m, t=topic: self._touch(t),
                10)
        self.pub = self.create_publisher(Bool, '/orion/health', 10)
        self.create_timer(1.0, self._tick)
        self.get_logger().info(f'heartbeat watching {len(WATCHED)} topics')

    def _now(self): return self.get_clock().now().nanoseconds * 1e-9
    def _touch(self, t): self.last[t] = self._now()

    def _tick(self):
        now = self._now()
        all_ok = True
        for topic, _ in WATCHED:
            last = self.last[topic]
            if last <= 0.0:
                age = float('inf')
            else:
                age = now - last
            if age > STALE_AFTER:
                all_ok = False
                if last > 0:
                    self.get_logger().warn(f'topic {topic} stale ({age:.1f} s)')
        m = Bool(); m.data = all_ok
        self.pub.publish(m)


def main(args=None):
    rclpy.init(args=args)
    node = Heartbeat()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
ok "rfid_system, mission_manager, heartbeat_monitor written."


# ---------- gui_dashboard.py (PyQt5 mission control) ----------
cat > orion_core/orion_core/gui_dashboard.py <<'PYEOF'
"""
ORION mission-control dashboard.

A PyQt5 GUI that subscribes to /orion/status, /orion/event_log, /orion/odom,
and /orion/rfid_event to display live robot state, and provides buttons
that publish to /orion/mission, /orion/estop, /orion/reset, /orion/clear_queue,
and /orion/return_home.

Threading model
---------------
rclpy spinning runs in a background thread inside RosBridge. ROS callbacks
emit Qt signals so all UI mutation happens on the Qt main thread.
"""
import math
import sys
import threading
import uuid

import rclpy

from std_msgs.msg import Empty, String
from nav_msgs.msg import Odometry
from orion_msgs.msg import Mission, RobotStatus, RFIDEvent
from orion_core.track_geometry import odom_to_world, SHELF_IDS

from PyQt5.QtCore import Qt, QObject, pyqtSignal
from PyQt5.QtGui import QFont
from PyQt5.QtWidgets import (
    QApplication, QWidget, QLabel, QPushButton, QVBoxLayout, QHBoxLayout,
    QGroupBox, QGridLayout, QListWidget, QComboBox, QLineEdit, QFormLayout,
    QDialog, QDialogButtonBox, QTextEdit,
)


class RosBridge(QObject):
    status_sig = pyqtSignal(object)
    log_sig    = pyqtSignal(str)
    pose_sig   = pyqtSignal(float, float, float)
    rfid_sig   = pyqtSignal(object)

    def __init__(self):
        super().__init__()
        rclpy.init()
        self.node = rclpy.create_node('orion_dashboard')

        self.node.create_subscription(RobotStatus, '/orion/status',     self._st, 10)
        self.node.create_subscription(String,      '/orion/event_log',  self._lg, 50)
        self.node.create_subscription(Odometry,    '/orion/odom',       self._od, 10)
        self.node.create_subscription(RFIDEvent,   '/orion/rfid_event', self._rf, 10)

        self.pub_mission = self.node.create_publisher(Mission, '/orion/mission',     10)
        self.pub_estop   = self.node.create_publisher(Empty,   '/orion/estop',       10)
        self.pub_reset   = self.node.create_publisher(Empty,   '/orion/reset',       10)
        self.pub_clear   = self.node.create_publisher(Empty,   '/orion/clear_queue', 10)
        self.pub_home    = self.node.create_publisher(Empty,   '/orion/return_home', 10)

        self._stop = False
        self._thread = threading.Thread(target=self._spin, daemon=True)
        self._thread.start()

    def _spin(self):
        while rclpy.ok() and not self._stop:
            rclpy.spin_once(self.node, timeout_sec=0.05)

    def shutdown(self):
        self._stop = True
        try:
            self.node.destroy_node()
        except Exception:
            pass
        try:
            rclpy.shutdown()
        except Exception:
            pass

    # ROS callbacks (called from spin thread - emit signals to UI thread)
    def _st(self, m): self.status_sig.emit(m)
    def _lg(self, m): self.log_sig.emit(m.data)
    def _od(self, m):
        wx, wy, wyaw = odom_to_world(m.pose.pose.position.x,
                                     m.pose.pose.position.y, 0.0)
        self.pose_sig.emit(wx, wy, wyaw)
    def _rf(self, m): self.rfid_sig.emit(m)

    # publishers
    def send_mission(self, shelf: str, sku: str, prio: int) -> str:
        m = Mission()
        m.mission_id   = f'gui-{uuid.uuid4().hex[:6]}'
        m.target_shelf = shelf
        m.sku          = sku
        m.priority     = int(prio)
        self.pub_mission.publish(m)
        return m.mission_id

    def send_estop(self): self.pub_estop.publish(Empty())
    def send_reset(self): self.pub_reset.publish(Empty())
    def send_clear(self): self.pub_clear.publish(Empty())
    def send_home(self):  self.pub_home.publish(Empty())


class CreateMissionDialog(QDialog):
    def __init__(self, parent):
        super().__init__(parent)
        self.setWindowTitle('Create Mission')
        form = QFormLayout(self)
        self.shelf = QComboBox(); self.shelf.addItems(SHELF_IDS)
        form.addRow('Target shelf:', self.shelf)
        self.sku = QLineEdit('SKU-1042')
        form.addRow('SKU:', self.sku)
        self.prio = QComboBox()
        self.prio.addItems(['low (0)', 'normal (1)', 'high (2)'])
        self.prio.setCurrentIndex(1)
        form.addRow('Priority:', self.prio)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        form.addRow(bb)

    def values(self):
        return self.shelf.currentText(), self.sku.text(), self.prio.currentIndex()


class Dashboard(QWidget):
    def __init__(self, bridge: RosBridge):
        super().__init__()
        self.bridge = bridge
        self.setWindowTitle('ORION Mission Control')
        self.setMinimumSize(960, 620)
        self._build()
        bridge.status_sig.connect(self._on_status)
        bridge.log_sig.connect(self._append_log)
        bridge.pose_sig.connect(self._on_pose)
        bridge.rfid_sig.connect(self._on_rfid)

    def _mono(self, text='--'):
        lbl = QLabel(text)
        lbl.setFont(QFont('Monospace', 11))
        return lbl

    def _build(self):
        root = QVBoxLayout(self)

        # --- title ---
        t = QLabel('ORION  Warehouse  AGV  Mission  Control')
        t.setFont(QFont('Sans', 16, QFont.Bold))
        t.setAlignment(Qt.AlignCenter)
        root.addWidget(t)

        # --- status panel ---
        sb = QGroupBox('Live Robot Status')
        g  = QGridLayout(sb)
        self.l_state   = self._mono('IDLE')
        self.l_mission = self._mono('-')
        self.l_shelf   = self._mono('-')
        self.l_sku     = self._mono('-')
        self.l_rfid    = self._mono('-')
        self.l_carry   = self._mono('false')
        self.l_battery = self._mono('100.0 %')
        self.l_pos     = self._mono('(+0.00, +0.00)  +0.0 deg')
        rows = [('State:', self.l_state),
                ('Mission:', self.l_mission),
                ('Target shelf:', self.l_shelf),
                ('SKU:', self.l_sku),
                ('Last RFID:', self.l_rfid),
                ('Carrying:', self.l_carry),
                ('Battery:', self.l_battery),
                ('Position:', self.l_pos)]
        for i, (k, w) in enumerate(rows):
            r = i // 2
            c = (i % 2) * 2
            g.addWidget(QLabel(k), r, c)
            g.addWidget(w, r, c + 1)
        root.addWidget(sb)

        # --- buttons ---
        btn = QHBoxLayout()
        b1 = QPushButton('Create Mission')
        b2 = QPushButton('Return Home')
        b3 = QPushButton('EMERGENCY STOP')
        b4 = QPushButton('Reset System')
        b5 = QPushButton('Clear Queue')
        b3.setStyleSheet(
            'background:#bb1c1c;color:white;font-weight:bold;padding:6px 12px')
        b1.clicked.connect(self._on_create)
        b2.clicked.connect(self.bridge.send_home)
        b3.clicked.connect(self.bridge.send_estop)
        b4.clicked.connect(self.bridge.send_reset)
        b5.clicked.connect(self.bridge.send_clear)
        for b in (b1, b2, b3, b4, b5):
            btn.addWidget(b)
        root.addLayout(btn)

        # --- log + active info ---
        bot = QHBoxLayout()
        log_box = QGroupBox('Event Log')
        lv = QVBoxLayout(log_box)
        self.log = QTextEdit()
        self.log.setReadOnly(True)
        self.log.setFont(QFont('Monospace', 10))
        lv.addWidget(self.log)

        q_box = QGroupBox('Active Mission / Recent RFID')
        qv = QVBoxLayout(q_box)
        self.q_list = QListWidget()
        self.q_list.setFont(QFont('Monospace', 10))
        qv.addWidget(self.q_list)

        bot.addWidget(log_box, 2)
        bot.addWidget(q_box, 1)
        root.addLayout(bot)

    def _on_create(self):
        d = CreateMissionDialog(self)
        if d.exec_() == QDialog.Accepted:
            shelf, sku, prio = d.values()
            mid = self.bridge.send_mission(shelf, sku, prio)
            self._append_log(f'[GUI] sent mission {mid} -> {shelf} '
                             f'sku="{sku}" prio={prio}')

    def _on_status(self, s):
        self.l_state.setText(s.state)
        self.l_mission.setText(s.mission_id or '-')
        self.l_shelf.setText(s.target_shelf or '-')
        self.l_sku.setText(s.current_sku or '-')
        self.l_rfid.setText(s.last_rfid or '-')
        self.l_carry.setText('TRUE' if s.carrying_load else 'false')
        self.l_battery.setText(f'{s.battery_percent:.1f} %')
        self.q_list.clear()
        if s.mission_id:
            self.q_list.addItem(f'ACTIVE: {s.mission_id}')
            self.q_list.addItem(f'  -> shelf {s.target_shelf}')
            self.q_list.addItem(f'  -> sku   {s.current_sku}')
            self.q_list.addItem(f'  state {s.state}')
        else:
            self.q_list.addItem('(no active mission)')

    def _append_log(self, text: str):
        self.log.append(text)
        if self.log.document().blockCount() > 200:
            cur = self.log.textCursor()
            cur.movePosition(cur.Start)
            cur.movePosition(cur.Down, cur.KeepAnchor, 50)
            cur.removeSelectedText()

    def _on_pose(self, wx, wy, wyaw):
        deg = math.degrees(wyaw)
        self.l_pos.setText(f'({wx:+.2f}, {wy:+.2f})  {deg:+.1f} deg')

    def _on_rfid(self, ev):
        self._append_log(
            f'[RFID] {ev.tag_id} d={ev.distance:.2f}m home={ev.is_home}')

    def closeEvent(self, ev):
        self.bridge.shutdown()
        ev.accept()


def main(args=None):
    app = QApplication(sys.argv)
    bridge = RosBridge()
    dash = Dashboard(bridge)
    dash.show()
    sys.exit(app.exec_())


if __name__ == '__main__':
    main()
PYEOF

# ---------- send_mission.py (CLI publisher) ----------
cat > orion_core/orion_core/send_mission.py <<'PYEOF'
"""
CLI mission sender.

Usage
-----
    ros2 run orion_core send_mission <SHELF_ID> [SKU] [PRIORITY]

Examples
--------
    ros2 run orion_core send_mission S07
    ros2 run orion_core send_mission S12 SKU-9001 2
"""
import sys
import time
import uuid

import rclpy
from orion_msgs.msg import Mission
from orion_core.track_geometry import SHELVES, SHELF_IDS


def _usage():
    print('Usage: ros2 run orion_core send_mission <SHELF_ID> [SKU] [PRIORITY]')
    print(f'Valid shelves: {", ".join(SHELF_IDS)}')
    print('Priority: 0=low, 1=normal (default), 2=high')


def main(args=None):
    rclpy.init(args=args)
    node = rclpy.create_node('orion_send_mission_cli')

    if len(sys.argv) < 2:
        _usage()
        node.destroy_node()
        rclpy.shutdown()
        sys.exit(1)

    shelf = sys.argv[1].upper().strip()
    if shelf not in SHELVES:
        print(f'ERROR: unknown shelf "{shelf}"')
        _usage()
        node.destroy_node()
        rclpy.shutdown()
        sys.exit(2)

    sku = sys.argv[2] if len(sys.argv) > 2 else f'SKU-{uuid.uuid4().hex[:4].upper()}'
    try:
        prio = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    except ValueError:
        print('ERROR: PRIORITY must be an integer 0..2')
        node.destroy_node()
        rclpy.shutdown()
        sys.exit(3)
    if prio not in (0, 1, 2):
        print('ERROR: PRIORITY must be 0, 1 or 2')
        node.destroy_node()
        rclpy.shutdown()
        sys.exit(3)

    pub = node.create_publisher(Mission, '/orion/mission', 10)

    # wait briefly for subscription to appear
    deadline = time.time() + 2.0
    while time.time() < deadline and pub.get_subscription_count() == 0:
        rclpy.spin_once(node, timeout_sec=0.05)

    msg = Mission()
    msg.mission_id   = f'cli-{uuid.uuid4().hex[:6]}'
    msg.target_shelf = shelf
    msg.sku          = sku
    msg.priority     = prio
    pub.publish(msg)
    print(f'Sent mission: id={msg.mission_id} shelf={shelf} sku="{sku}" prio={prio}')

    # spin briefly so the message actually leaves
    end = time.time() + 0.5
    while time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.05)

    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
ok "gui_dashboard and send_mission written."


# ============================================================================
# PHASE 7 : PACKAGE orion_launch (master warehouse.launch.py)
# ============================================================================
section "PHASE 7 - orion_launch"

mkdir -p orion_launch/launch

cat > orion_launch/package.xml <<'EOF'
<?xml version="1.0"?>
<package format="3">
  <name>orion_launch</name>
  <version>1.0.0</version>
  <description>Master launch package for ORION warehouse simulation -
    starts Gazebo, spawns the AGV, brings up every runtime node, RViz
    and the dashboard with a single command.</description>
  <maintainer email="orion@example.com">orion</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_cmake</buildtool_depend>

  <exec_depend>orion_world</exec_depend>
  <exec_depend>orion_robot</exec_depend>
  <exec_depend>orion_core</exec_depend>
  <exec_depend>orion_msgs</exec_depend>
  <exec_depend>gazebo_ros</exec_depend>
  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>rviz2</exec_depend>
  <exec_depend>xacro</exec_depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
EOF

cat > orion_launch/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.8)
project(orion_launch)
find_package(ament_cmake REQUIRED)
install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})
ament_package()
EOF

cat > orion_launch/launch/warehouse.launch.py <<'PYEOF'
"""
ORION master launch file.

Brings up the entire stack from a single command:

    ros2 launch orion_launch warehouse.launch.py

Components
----------
    1. Gazebo Classic with the ORION warehouse world.
    2. robot_state_publisher (under /orion namespace) + xacro URDF.
    3. spawn_entity for the AGV at HOME (delayed to allow gazebo start).
    4. optical_sensor, line/turn/pivot controllers, rfid_system,
       mission_manager, heartbeat_monitor (delayed for plugins).
    5. RViz2 with the ORION view config.
    6. PyQt5 GUI dashboard.

Launch arguments
----------------
    rviz   : 'true' | 'false'  start RViz (default true)
    gui    : 'true' | 'false'  start the PyQt5 dashboard (default true)
    world  : path override     full path to a custom .world file (optional)
"""
import os
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument, ExecuteProcess, TimerAction,
)
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, Command, PythonExpression
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    pkg_world = get_package_share_directory('orion_world')
    pkg_robot = get_package_share_directory('orion_robot')

    default_world = os.path.join(pkg_world, 'worlds', 'warehouse.world')
    urdf_xacro    = os.path.join(pkg_robot, 'urdf',   'orion_agv.urdf.xacro')
    rviz_cfg      = os.path.join(pkg_robot, 'rviz',   'orion.rviz')

    arg_rviz  = DeclareLaunchArgument('rviz',  default_value='true')
    arg_gui   = DeclareLaunchArgument('gui',   default_value='true')
    arg_world = DeclareLaunchArgument('world', default_value=default_world)

    # ---------- Gazebo Classic ----------
    gazebo = ExecuteProcess(
        cmd=['gazebo', '--verbose',
             LaunchConfiguration('world'),
             '-s', 'libgazebo_ros_init.so',
             '-s', 'libgazebo_ros_factory.so'],
        output='screen',
    )

    # ---------- Robot description / state publisher ----------
    robot_description = Command(['xacro ', urdf_xacro])
    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        name='robot_state_publisher',
        namespace='orion',
        output='screen',
        parameters=[{'use_sim_time': True,
                     'robot_description': robot_description}],
    )

    # ---------- Spawn the AGV (delayed so gazebo is ready) ----------
    spawn = Node(
        package='gazebo_ros',
        executable='spawn_entity.py',
        name='spawn_orion_agv',
        output='screen',
        arguments=[
            '-entity', 'orion_agv',
            '-topic',  '/orion/robot_description',
            '-x', '0.0', '-y', '-1.0', '-z', '0.01', '-Y', '1.5708',
        ],
    )
    spawn_delayed = TimerAction(period=5.0, actions=[spawn])

    # ---------- ORION runtime nodes ----------
    optical = Node(package='orion_core', executable='optical_sensor',
                   name='orion_optical_sensor', output='screen')
    line    = Node(package='orion_core', executable='line_controller',
                   name='orion_line_controller', output='screen')
    turn    = Node(package='orion_core', executable='turn_controller',
                   name='orion_turn_controller', output='screen')
    pivot   = Node(package='orion_core', executable='pivot_controller',
                   name='orion_pivot_controller', output='screen')
    rfid    = Node(package='orion_core', executable='rfid_system',
                   name='orion_rfid_system', output='screen')
    mission = Node(package='orion_core', executable='mission_manager',
                   name='orion_mission_manager', output='screen')
    heart   = Node(package='orion_core', executable='heartbeat_monitor',
                   name='orion_heartbeat', output='screen')

    stack_delayed = TimerAction(
        period=8.0,
        actions=[optical, line, turn, pivot, rfid, mission, heart],
    )

    # ---------- RViz ----------
    rviz = Node(
        package='rviz2',
        executable='rviz2',
        name='orion_rviz',
        arguments=['-d', rviz_cfg],
        output='log',
        parameters=[{'use_sim_time': True}],
        condition=IfCondition(LaunchConfiguration('rviz')),
    )
    rviz_delayed = TimerAction(period=10.0, actions=[rviz])

    # ---------- PyQt5 GUI ----------
    gui = Node(
        package='orion_core',
        executable='gui_dashboard',
        name='orion_gui',
        output='log',
        condition=IfCondition(LaunchConfiguration('gui')),
    )
    gui_delayed = TimerAction(period=10.0, actions=[gui])

    return LaunchDescription([
        arg_rviz, arg_gui, arg_world,
        gazebo, rsp,
        spawn_delayed,
        stack_delayed,
        rviz_delayed,
        gui_delayed,
    ])
PYEOF
ok "orion_launch package written."


# ============================================================================
# PHASE 8 : BUILD - messages first, then everything else
# ============================================================================
section "PHASE 8 - colcon build"

cd "${WS_ROOT}"
# shellcheck disable=SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"

step "Building orion_msgs (interfaces) in isolation"
colcon build --packages-select orion_msgs --symlink-install
ok "orion_msgs built."

# shellcheck disable=SC1091
source "${WS_ROOT}/install/setup.bash"

step "Verifying generated message interfaces"
ros2 interface show orion_msgs/msg/Mission     >/dev/null
ros2 interface show orion_msgs/msg/RFIDEvent   >/dev/null
ros2 interface show orion_msgs/msg/RobotStatus >/dev/null
ok "All three orion_msgs interfaces are visible."

step "Building remaining packages (orion_world, orion_robot, orion_core, orion_launch)"
colcon build --packages-skip orion_msgs --symlink-install
ok "All packages built."

# shellcheck disable=SC1091
source "${WS_ROOT}/install/setup.bash"

# ============================================================================
# PHASE 9 : SELF VALIDATION
# ============================================================================
section "PHASE 9 - validation report"

REPORT_FAILS=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    warn "$label  [FAILED]"
    REPORT_FAILS=$((REPORT_FAILS + 1))
  fi
}

# package presence
for p in orion_msgs orion_world orion_robot orion_core orion_launch; do
  check "package $p installed" ros2 pkg prefix "$p"
done

# msg interfaces
check "interface Mission"     ros2 interface show orion_msgs/msg/Mission
check "interface RFIDEvent"   ros2 interface show orion_msgs/msg/RFIDEvent
check "interface RobotStatus" ros2 interface show orion_msgs/msg/RobotStatus

# orion_core executables
for x in mission_manager line_controller turn_controller pivot_controller \
         optical_sensor rfid_system gui_dashboard send_mission heartbeat_monitor; do
  check "executable orion_core/$x" \
    bash -c "ros2 pkg executables orion_core | grep -q ' $x\$'"
done

# URDF parses cleanly
URDF=$(ros2 pkg prefix orion_robot)/share/orion_robot/urdf/orion_agv.urdf.xacro
check "URDF xacro file present" test -s "$URDF"
check "URDF xacro parses cleanly" xacro "$URDF"

# world file presence
WORLD=$(ros2 pkg prefix orion_world)/share/orion_world/worlds/warehouse.world
check "warehouse.world generated" test -s "$WORLD"

# launch file presence
LAUNCH=$(ros2 pkg prefix orion_launch)/share/orion_launch/launch/warehouse.launch.py
check "warehouse.launch.py installed" test -s "$LAUNCH"

# RViz config presence
RVIZ=$(ros2 pkg prefix orion_robot)/share/orion_robot/rviz/orion.rviz
check "RViz config installed" test -s "$RVIZ"

# python imports work (catches typos before launch time)
check "python import orion_core.track_geometry" \
  python3 -c 'import orion_core.track_geometry as t; assert len(t.SHELVES)==20'

# Static check: only mission_manager publishes /orion/cmd_vel
PUB_CMD=$(grep -rn "create_publisher(.*'/orion/cmd_vel'" "${SRC_DIR}/orion_core/orion_core" || true)
PUB_COUNT=$(printf '%s\n' "$PUB_CMD" | grep -cv '^$' || true)
if [ "$PUB_COUNT" = "1" ] && echo "$PUB_CMD" | grep -q mission_manager.py; then
  ok "single-arbiter check: only mission_manager.py publishes /orion/cmd_vel"
else
  warn "single-arbiter check FAILED (${PUB_COUNT} publishers found)"
  echo "$PUB_CMD"
  REPORT_FAILS=$((REPORT_FAILS + 1))
fi

# launch file exec permission for python module is not required (run via ros2 run)
echo
if [ "$REPORT_FAILS" -eq 0 ]; then
  echo -e "${C_GREEN}=========================================="
  echo -e "  VALIDATION REPORT : ALL CHECKS PASSED"
  echo -e "==========================================${C_RESET}"
else
  echo -e "${C_YELLOW}=========================================="
  echo -e "  VALIDATION REPORT : ${REPORT_FAILS} FAILURES"
  echo -e "==========================================${C_RESET}"
fi

# ============================================================================
# PHASE 10 : LAUNCH INFO
# ============================================================================
section "PHASE 10 - launch information"

cat <<'BANNER'
ORION installation complete.

Workspace : ~/orion_ws
Source    : source ~/orion_ws/install/setup.bash

Master launch command (single command brings up everything):
    ros2 launch orion_launch warehouse.launch.py

CLI mission sender:
    ros2 run orion_core send_mission S07
    ros2 run orion_core send_mission S12 SKU-9001 2

Disable optional components if needed:
    ros2 launch orion_launch warehouse.launch.py rviz:=false gui:=false

Inspect topics live:
    ros2 topic echo /orion/status
    ros2 topic echo /orion/event_log
    ros2 topic echo /orion/sensors
BANNER

if [ "${LAUNCH_AFTER_BUILD}" = "1" ]; then
  echo
  step "Launching ORION (set LAUNCH_AFTER_BUILD=0 to skip auto-launch)"
  exec ros2 launch orion_launch warehouse.launch.py
fi
