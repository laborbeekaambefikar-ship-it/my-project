# 🔥 HOTFIX — AGV Moves On Its Own (Physics Issue)

## Confirmed Diagnosis

Your diagnostic output proves:
- The brain publishes `linear.x = 0, angular.z = 0` (correct)
- AGV moves anyway, even with NO brain running (Test 1: yes)
- All file fingerprints are correct
- `state_node` is the sole publisher on `/agv/cmd_vel`

**This is a Gazebo physics problem, not a code problem.**

The AGV chassis is intersecting the floor on spawn. The physics engine
detects the collision and "pushes" the AGV to resolve it — that push
creates a residual velocity that never decays because the wheels have no
damping or friction in the rolling direction.

The fix: a corrected URDF with proper wheel placement, friction values,
joint damping, and inertia.

---

## Step 1 — Replace `agv.urdf.xacro`

```bash
nano ~/agv_ws/src/agv_robot/urdf/agv.urdf.xacro
```

Delete everything in the file. Paste this:

```xml
<?xml version="1.0"?>
<robot name="agv" xmlns:xacro="http://www.ros.org/wiki/xacro">

  <!-- ========== MATERIALS ========== -->
  <material name="black">  <color rgba="0.1 0.1 0.1 1"/></material>
  <material name="gray">   <color rgba="0.4 0.4 0.4 1"/></material>
  <material name="orange"> <color rgba="1.0 0.5 0.0 1"/></material>
  <material name="blue">   <color rgba="0.1 0.3 1.0 1"/></material>

  <!-- ========== CONSTANTS ========== -->
  <xacro:property name="WHEEL_RADIUS"  value="0.04"/>
  <xacro:property name="WHEEL_LENGTH"  value="0.025"/>
  <xacro:property name="WHEEL_SEP"     value="0.21"/>
  <xacro:property name="CHASSIS_X"     value="0.25"/>
  <xacro:property name="CHASSIS_Y"     value="0.20"/>
  <xacro:property name="CHASSIS_Z"     value="0.08"/>
  <xacro:property name="CASTER_RADIUS" value="0.02"/>

  <!-- ========== BASE FOOTPRINT (origin on the floor) ========== -->
  <link name="base_footprint"/>

  <!-- base_link is at wheel-axis height = WHEEL_RADIUS above ground -->
  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/>
    <child  link="base_link"/>
    <origin xyz="0 0 ${WHEEL_RADIUS}" rpy="0 0 0"/>
  </joint>

  <!-- ========== CHASSIS ========== -->
  <link name="base_link">
    <visual>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
      <material name="gray"/>
    </visual>
    <collision>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <geometry><box size="${CHASSIS_X} ${CHASSIS_Y} ${CHASSIS_Z}"/></geometry>
    </collision>
    <inertial>
      <origin xyz="0 0 ${CHASSIS_Z/2}" rpy="0 0 0"/>
      <mass value="2.5"/>
      <inertia ixx="0.020" ixy="0.0"  ixz="0.0"
               iyy="0.025" iyz="0.0"  izz="0.030"/>
    </inertial>
  </link>

  <!-- ========== TRAY (cosmetic) ========== -->
  <link name="tray_link">
    <visual>
      <origin xyz="0 0 0.005" rpy="0 0 0"/>
      <geometry><box size="0.20 0.18 0.01"/></geometry>
      <material name="orange"/>
    </visual>
    <inertial>
      <mass value="0.05"/>
      <inertia ixx="1e-4" ixy="0" ixz="0" iyy="1e-4" iyz="0" izz="1e-4"/>
    </inertial>
  </link>
  <joint name="tray_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="tray_link"/>
    <origin xyz="0 0 ${CHASSIS_Z + 0.005}" rpy="0 0 0"/>
  </joint>

  <!-- ========== LEFT WHEEL ========== -->
  <link name="wheel_left">
    <visual>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <surface>
        <friction>
          <ode>
            <mu>1.0</mu>
            <mu2>0.5</mu2>
            <fdir1>1 0 0</fdir1>
          </ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0"
               iyy="1.5e-4" iyz="0" izz="1.2e-4"/>
    </inertial>
  </link>
  <joint name="joint_left_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_left"/>
    <origin xyz="0 ${WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <!-- ========== RIGHT WHEEL ========== -->
  <link name="wheel_right">
    <visual>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <origin xyz="0 0 0" rpy="${pi/2} 0 0"/>
      <geometry><cylinder length="${WHEEL_LENGTH}" radius="${WHEEL_RADIUS}"/></geometry>
      <surface>
        <friction>
          <ode>
            <mu>1.0</mu>
            <mu2>0.5</mu2>
            <fdir1>1 0 0</fdir1>
          </ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.15"/>
      <inertia ixx="1.5e-4" ixy="0" ixz="0"
               iyy="1.5e-4" iyz="0" izz="1.2e-4"/>
    </inertial>
  </link>
  <joint name="joint_right_wheel" type="continuous">
    <parent link="base_link"/>
    <child  link="wheel_right"/>
    <origin xyz="0 ${-WHEEL_SEP/2} 0" rpy="0 0 0"/>
    <axis xyz="0 1 0"/>
    <dynamics damping="0.5" friction="0.2"/>
  </joint>

  <!-- ========== CASTER (rear ball) ========== -->
  <link name="caster_link">
    <visual>
      <geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <material name="black"/>
    </visual>
    <collision>
      <geometry><sphere radius="${CASTER_RADIUS}"/></geometry>
      <surface>
        <friction>
          <ode>
            <mu>0.0</mu>
            <mu2>0.0</mu2>
          </ode>
        </friction>
      </surface>
    </collision>
    <inertial>
      <mass value="0.05"/>
      <inertia ixx="1e-5" ixy="0" ixz="0" iyy="1e-5" iyz="0" izz="1e-5"/>
    </inertial>
  </link>
  <joint name="caster_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="caster_link"/>
    <origin xyz="-0.10 0 ${-(WHEEL_RADIUS - CASTER_RADIUS)}" rpy="0 0 0"/>
  </joint>

  <!-- ========== IMU LINK ========== -->
  <link name="imu_link"/>
  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/>
    <child  link="imu_link"/>
    <origin xyz="0 0 0.01" rpy="0 0 0"/>
  </joint>

  <!-- ========== 8 IR SENSOR LINKS (visual only) ========== -->
  <xacro:macro name="ir_sensor" params="idx y_offset">
    <link name="ir_${idx}">
      <visual>
        <geometry><box size="0.006 0.006 0.004"/></geometry>
        <material name="blue"/>
      </visual>
      <inertial>
        <mass value="0.001"/>
        <inertia ixx="1e-7" ixy="0" ixz="0" iyy="1e-7" iyz="0" izz="1e-7"/>
      </inertial>
    </link>
    <joint name="ir_${idx}_joint" type="fixed">
      <parent link="base_link"/>
      <child  link="ir_${idx}"/>
      <origin xyz="0.10 ${y_offset} -0.035" rpy="0 0 0"/>
    </joint>
  </xacro:macro>

  <xacro:ir_sensor idx="1" y_offset="0.042"/>
  <xacro:ir_sensor idx="2" y_offset="0.030"/>
  <xacro:ir_sensor idx="3" y_offset="0.018"/>
  <xacro:ir_sensor idx="4" y_offset="0.006"/>
  <xacro:ir_sensor idx="5" y_offset="-0.006"/>
  <xacro:ir_sensor idx="6" y_offset="-0.018"/>
  <xacro:ir_sensor idx="7" y_offset="-0.030"/>
  <xacro:ir_sensor idx="8" y_offset="-0.042"/>

  <!-- ========== GAZEBO SURFACE PROPERTIES ========== -->
  <gazebo reference="base_link"><material>Gazebo/Grey</material></gazebo>
  <gazebo reference="tray_link"><material>Gazebo/Orange</material></gazebo>

  <gazebo reference="wheel_left">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1>
    <mu2>0.5</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>

  <gazebo reference="wheel_right">
    <material>Gazebo/Black</material>
    <mu1>1.0</mu1>
    <mu2>0.5</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
    <fdir1>1 0 0</fdir1>
  </gazebo>

  <gazebo reference="caster_link">
    <material>Gazebo/Black</material>
    <mu1>0.0</mu1>
    <mu2>0.0</mu2>
    <kp>1000000.0</kp>
    <kd>10.0</kd>
  </gazebo>

  <!-- ========== DIFFERENTIAL DRIVE PLUGIN ========== -->
  <gazebo>
    <plugin name="diff_drive" filename="libgazebo_ros_diff_drive.so">
      <ros>
        <namespace>/agv</namespace>
      </ros>
      <update_rate>50</update_rate>
      <left_joint>joint_left_wheel</left_joint>
      <right_joint>joint_right_wheel</right_joint>
      <wheel_separation>${WHEEL_SEP}</wheel_separation>
      <wheel_diameter>${WHEEL_RADIUS*2}</wheel_diameter>
      <max_wheel_torque>20.0</max_wheel_torque>
      <max_wheel_acceleration>5.0</max_wheel_acceleration>
      <command_topic>cmd_vel</command_topic>
      <publish_odom>true</publish_odom>
      <publish_odom_tf>true</publish_odom_tf>
      <publish_wheel_tf>false</publish_wheel_tf>
      <odometry_topic>odom</odometry_topic>
      <odometry_frame>odom</odometry_frame>
      <robot_base_frame>base_footprint</robot_base_frame>
    </plugin>
  </gazebo>

  <!-- ========== JOINT STATE PUBLISHER ========== -->
  <gazebo>
    <plugin name="joint_states" filename="libgazebo_ros_joint_state_publisher.so">
      <ros><namespace>/agv</namespace><remapping>~/out:=joint_states</remapping></ros>
      <update_rate>50</update_rate>
      <joint_name>joint_left_wheel</joint_name>
      <joint_name>joint_right_wheel</joint_name>
    </plugin>
  </gazebo>

  <!-- ========== IMU PLUGIN ========== -->
  <gazebo reference="imu_link">
    <sensor name="imu" type="imu">
      <update_rate>100</update_rate>
      <always_on>true</always_on>
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
      <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
        <ros>
          <namespace>/agv</namespace>
          <remapping>~/out:=imu</remapping>
        </ros>
        <frame_name>imu_link</frame_name>
      </plugin>
    </sensor>
  </gazebo>

</robot>
```

Save and exit.

---

## Step 2 — Update `spawn.launch.py`

```bash
nano ~/agv_ws/src/agv_robot/launch/spawn.launch.py
```

Find this block:
```python
arguments=['-entity', 'agv',
           '-topic', 'robot_description',
           '-x', '-2.0', '-y', '0.0', '-z', '0.05',
           '-Y', '0.0'],
```

Change `-z 0.05` to `-z 0.01`:
```python
arguments=['-entity', 'agv',
           '-topic', 'robot_description',
           '-x', '-2.0', '-y', '0.0', '-z', '0.01',
           '-Y', '0.0'],
```

The new URDF places the AGV with its wheels exactly on the ground.
We only need a tiny `z=0.01` clearance to avoid spawning *inside* the
ground plane. Spawning at `z=0.05` was making the AGV fall 5 cm on
spawn and bounce, creating residual velocity.

Save and exit.

---

## Step 3 — Rebuild the robot package

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_robot
source install/setup.bash
```

Expected: `Summary: 1 package finished` with no errors.

---

## Step 4 — Test ONLY the spawn (no brain)

```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3

source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

Wait 30 seconds. Watch the AGV in Gazebo.

**The AGV must NOT move.** It should sit perfectly still on the green
HOME pad.

---

## Step 5 — Verify with odometry

While Gazebo is running, in another terminal:

```bash
source ~/agv_ws/install/setup.bash
ros2 topic echo /agv/odom --once | grep -A 6 twist
```

The output should show:
```
twist:
  twist:
    linear:
      x: 0.0
      y: 0.0
      z: 0.0
    angular:
      x: 0.0
      y: 0.0
      z: 0.0
```

All zeros means the AGV is genuinely stationary. If you see any non-zero
value here, the physics fix isn't complete — see Troubleshooting at the
bottom.

---

## Step 6 — Test the full mission

If Steps 4 and 5 pass:

**Terminal 1:**
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

**Terminal 2:**
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```

**Terminal 3:**
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

The AGV should drive east, turn left at junction 2, find S05, wait,
pivot 180°, return home.

---

## Why The Old URDF Was Broken

| Old URDF problem | What happened | New URDF fix |
|---|---|---|
| `base_link` at `z=0.040`, wheels at `z=-0.005` | Wheel CENTERS were 5mm BELOW base_link, but base_link only 4cm above ground → wheels embedded 1cm in floor | Wheels at `z=0` of base_link, base_link at `z=WHEEL_RADIUS` above ground → wheel bottoms exactly on ground |
| Caster at `z=-0.025` | Caster also embedded slightly | Caster at `z=-(WHEEL_R - CASTER_R) = -0.02` → caster bottom on ground exactly |
| No `<dynamics damping>` on joints | Wheels free-spin even with no torque; tiny initial impulse persists forever | `damping=0.5 friction=0.2` stops wheel rotation when no command |
| `mu2` not set in Gazebo block | Sideways slip caused drift | `mu2=0.5` grips floor laterally |
| `kp/kd` not set | Wheel-ground contact bouncy | `kp=1e6 kd=10` firm contact, no bounce |
| `fdir1` not set | Friction direction undefined | `1 0 0` (rolling axis) |
| `max_wheel_torque=5.0` | Could overshoot at startup | `20.0` holds firmly |
| Spawn at `z=0.05` | AGV dropped 5cm and bounced | Spawn at `z=0.01` (just above ground, no fall) |

The most important fix is **wheel placement**. In the old URDF:
- `base_link` was at `z=0.040`
- Wheel joint origin was `z=-0.005`
- So wheel CENTER was at `z=0.035`
- Wheel radius is `0.040`, so wheel BOTTOM was at `z=-0.005`
- Ground is at `z=0`

→ The wheel bottoms were **5 millimeters below the ground**. On spawn,
Gazebo's collision solver sees this overlap and applies a large impulse
to push the wheels up. With no joint damping, this impulse becomes
rotational velocity that the wheels hold forever.

In the new URDF:
- `base_link` at `z=WHEEL_RADIUS = 0.040`
- Wheel joint origin `z=0`
- Wheel center at `z=0.040`
- Wheel bottom at `z=0.000` exactly

→ No overlap. No impulse. AGV sits still.

---

## Troubleshooting

### If the AGV still moves after this fix

Check the Gazebo world's ground plane friction:
```bash
grep -A 5 "ground_plane\|<mu>" ~/agv_ws/src/agv_world/worlds/warehouse.world | head -20
```

If you see `<mu>0</mu>` or `<mu1>0</mu1>` for the ground, the floor is
frictionless. Edit the world file or rerun `build_world.py` with proper
friction.

### If the AGV moves only slightly then stops

That's actually OK — the simulation is settling. As long as it doesn't
keep moving, you're good. Re-run Step 5 after 5 seconds and the velocity
should be zero.

### If you can't tell whether AGV is moving by eye

Use this command to print AGV velocity continuously:
```bash
watch -n 0.5 'ros2 topic echo /agv/odom --once | grep -A 1 "twist:" | tail -5'
```

Watch the `linear.x` value. If it stays at 0.000 for 10+ seconds, the
AGV is stationary.
