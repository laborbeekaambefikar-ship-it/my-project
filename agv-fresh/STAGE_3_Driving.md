# 🛣️ Stage 3 — Make the AGV Drive on the Line

> **Goal:** Add 3 Python files that turn the AGV into a line-following robot. By the end, the AGV will drive itself along the black tape lines.

**Time:** ~45 minutes. **Files created:** 4 Python files, 1 launch file, 1 params file.

---

## 🧠 The Big Idea

We're going to add **3 nodes** that work together:

```
   Gazebo publishes AGV's position
            ↓
      /agv/odom
            ↓
   ┌──────────────────┐
   │  optical_node    │  ← Computes 8 binary sensor values
   │  (NEW)           │     from AGV pose + line geometry
   └────────┬─────────┘
            ↓
      /agv/line_sensors
            ↓
   ┌──────────────────┐
   │  follow_node     │  ← Runs PID, computes turn correction
   │  (NEW)           │
   └────────┬─────────┘
            ↓
      /agv/cmd_vel
            ↓
       Gazebo moves AGV
```

**Plus one helper file:**
- `track_lib.py` — knows where the lines are. Used by `optical_node`.

---

## 📋 Step 1 — Create Folders

```bash
mkdir -p ~/agv_ws/src/agv_brain/agv_brain
mkdir -p ~/agv_ws/src/agv_brain/launch
mkdir -p ~/agv_ws/src/agv_brain/config
touch    ~/agv_ws/src/agv_brain/agv_brain/__init__.py
```

---

## 📋 Step 2 — Create `track_lib.py` (Line Geometry Library)

This file knows **where the black tape is**. Same numbers as `build_world.py` (Stage 1).

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/track_lib.py
```

Paste:

```python
#!/usr/bin/env python3
"""
track_lib.py — Geometry of the black tape lines on the floor.

The optical_node imports this to ask "is point (x,y) on a line?"
NUMBERS HERE MUST MATCH build_world.py FROM STAGE 1.
"""

import math
from dataclasses import dataclass
from typing import List, Tuple


# === Source-of-truth constants (same as build_world.py) ===
LINE_WIDTH = 0.05    # 5 cm wide tape

MAIN_AISLE_X_START = -2.5
MAIN_AISLE_X_END   = 12.5
MAIN_AISLE_Y       = 0.0

SPUR_X_LIST  = [0.0, 3.0, 6.0, 9.0, 12.0]
SPUR_Y_START = 0.0
SPUR_Y_END   = 4.0


@dataclass
class Segment:
    name: str
    x1: float
    y1: float
    x2: float
    y2: float
    width: float = LINE_WIDTH

    def distance_to(self, px, py):
        """Perpendicular distance from point to this segment (clamped to endpoints)."""
        dx = self.x2 - self.x1
        dy = self.y2 - self.y1
        L2 = dx*dx + dy*dy
        if L2 < 1e-9:
            return math.hypot(px - self.x1, py - self.y1)
        t = ((px - self.x1) * dx + (py - self.y1) * dy) / L2
        t = max(0.0, min(1.0, t))
        proj_x = self.x1 + t * dx
        proj_y = self.y1 + t * dy
        return math.hypot(px - proj_x, py - proj_y)

    def contains(self, px, py):
        return self.distance_to(px, py) < (self.width / 2.0)


def build_track() -> List[Segment]:
    segs = []
    segs.append(Segment("main", MAIN_AISLE_X_START, MAIN_AISLE_Y,
                        MAIN_AISLE_X_END,   MAIN_AISLE_Y))
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        segs.append(Segment(f"spur_{i}", sx, SPUR_Y_START, sx, SPUR_Y_END))
    return segs


TRACK = build_track()


def on_line(px, py) -> Tuple[bool, str]:
    """Returns (True, line_name) if point is on tape, else (False, '')."""
    for s in TRACK:
        if s.contains(px, py):
            return True, s.name
    return False, ""


# Quick self-test if run directly
if __name__ == "__main__":
    print(f"Track has {len(TRACK)} segments:")
    for s in TRACK:
        print(f"  {s.name:10s}  ({s.x1:+.1f},{s.y1:+.1f}) -> ({s.x2:+.1f},{s.y2:+.1f})")
    tests = [
        (0.0, 0.0, True),
        (1.5, 0.0, True),
        (1.5, 1.0, False),
        (3.0, 2.0, True),
        (3.0, 4.5, False),
        (-2.0, 0.0, True),  # Home is on the main aisle line
    ]
    print("\nSelf-test:")
    for x, y, expected in tests:
        got, name = on_line(x, y)
        ok = "OK" if got == expected else "FAIL"
        print(f"  [{ok}] ({x:+.1f},{y:+.1f}) -> on={got} ({name})")
```

✅ **Test it now:**
```bash
python3 ~/agv_ws/src/agv_brain/agv_brain/track_lib.py
```
Should print 6 segments and 6 OK tests.

---

## 📋 Step 3 — Create `optical_node.py` (Virtual IR Sensor)

This is the node that **simulates the 8 IR sensors** by computing each sensor's world position and asking `track_lib` if it's on a line.

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/optical_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
optical_node.py - Simulates 8 IR line sensors using AGV pose + track geometry.
Publishes /agv/line_sensors at 50 Hz.
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import Float32MultiArray
from visualization_msgs.msg import Marker, MarkerArray
from agv_brain.track_lib import on_line


# Sensor array — MUST match URDF in agv_robot/urdf/agv.urdf.xacro
SENSOR_X       = 0.10    # 10 cm in front of base_link
SENSOR_Z       = 0.005   # for visualization marker
SENSOR_OFFSETS_Y = [0.042, 0.030, 0.018, 0.006,
                    -0.006, -0.018, -0.030, -0.042]
NUM_SENSORS = len(SENSOR_OFFSETS_Y)


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


class OpticalNode(Node):
    def __init__(self):
        super().__init__('optical_node')
        self.last = None  # (x, y, yaw)

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 50)
        self.sensors_pub = self.create_publisher(Float32MultiArray,
                                                  '/agv/line_sensors', 10)
        self.markers_pub = self.create_publisher(MarkerArray,
                                                  '/agv/line_sensors_markers', 10)
        self.create_timer(0.02, self.tick)  # 50 Hz
        self.get_logger().info('optical_node ready (8 virtual sensors @ 50 Hz)')

    def odom_cb(self, msg):
        p = msg.pose.pose
        self.last = (p.position.x, p.position.y, yaw_from_quat(p.orientation))

    def tick(self):
        if self.last is None:
            return
        bx, by, yaw = self.last
        c, s = math.cos(yaw), math.sin(yaw)

        binary = []
        positions = []
        for off_y in SENSOR_OFFSETS_Y:
            wx = bx + c*SENSOR_X - s*off_y
            wy = by + s*SENSOR_X + c*off_y
            ok, _ = on_line(wx, wy)
            binary.append(1.0 if ok else 0.0)
            positions.append((wx, wy))

        m = Float32MultiArray()
        m.data = binary
        self.sensors_pub.publish(m)
        self.publish_markers(positions, binary)

    def publish_markers(self, positions, binary):
        ma = MarkerArray()
        now = self.get_clock().now().to_msg()
        for i, ((wx, wy), b) in enumerate(zip(positions, binary)):
            mk = Marker()
            mk.header.frame_id = 'odom'
            mk.header.stamp = now
            mk.ns = 'ir'
            mk.id = i
            mk.type = Marker.SPHERE
            mk.action = Marker.ADD
            mk.pose.position.x = wx
            mk.pose.position.y = wy
            mk.pose.position.z = SENSOR_Z
            mk.pose.orientation.w = 1.0
            mk.scale.x = mk.scale.y = mk.scale.z = 0.025
            if b > 0.5:
                mk.color.r, mk.color.g, mk.color.b = 1.0, 0.0, 0.0
            else:
                mk.color.r, mk.color.g, mk.color.b = 0.0, 1.0, 0.0
            mk.color.a = 1.0
            ma.markers.append(mk)
        self.markers_pub.publish(ma)


def main(args=None):
    rclpy.init(args=args)
    node = OpticalNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## 📋 Step 4 — Create `follow_node.py` (PID Line Follower)

This is the **brain that drives**. It reads the 8 sensor values and computes how to steer.

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/follow_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
follow_node.py - PID line follower. Reads /agv/line_sensors -> publishes /agv/cmd_vel.

ALSO publishes /agv/junction_detected when 5+ sensors see black (used in Stage 4).
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist
import numpy as np


class FollowNode(Node):
    def __init__(self):
        super().__init__('follow_node')

        # Tunable parameters (load from YAML in Step 6)
        self.declare_parameter('linear_speed', 0.50)
        self.declare_parameter('kp', 0.50)
        self.declare_parameter('ki', 0.00)
        self.declare_parameter('kd', 0.15)
        self.declare_parameter('enabled', True)

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp = self.get_parameter('kp').value
        self.ki = self.get_parameter('ki').value
        self.kd = self.get_parameter('kd').value
        self.enabled = self.get_parameter('enabled').value

        # PID state
        self.prev_err = 0.0
        self.integral = 0.0
        self.last_offset = 0.0
        self.lost_count = 0
        self.MAX_LOST = 25  # 0.5s grace period at 50Hz

        # Subscribers
        self.create_subscription(Float32MultiArray, '/agv/line_sensors',
                                 self.sensors_cb, 10)
        self.create_subscription(Bool, '/agv/follow_enable', self.enable_cb, 10)

        # Publishers
        self.cmd_pub = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.junction_pub = self.create_publisher(Bool, '/agv/junction_detected', 10)

        self.frame_count = 0
        self.last_was_junction = False

        self.get_logger().info(
            f'follow_node ready  speed={self.linear_speed} kp={self.kp} kd={self.kd}'
        )

    def enable_cb(self, msg):
        self.enabled = msg.data
        if not self.enabled:
            self.cmd_pub.publish(Twist())
            self.prev_err = 0.0
            self.integral = 0.0
            self.lost_count = 0
        self.get_logger().info(f'follow_node {"ENABLED" if self.enabled else "DISABLED"}')

    def sensors_cb(self, msg):
        if not self.enabled or len(msg.data) < 8:
            return
        binary = np.array(msg.data, dtype=np.float32)
        black = int(binary.sum())

        # --- Junction detection ---
        is_junction = (black >= 5)
        if is_junction and not self.last_was_junction:
            j = Bool(); j.data = True
            self.junction_pub.publish(j)
        self.last_was_junction = is_junction

        # --- Compute offset ---
        offset, detected = self.compute_offset(binary)

        # --- Drive ---
        if detected:
            self.lost_count = 0
            ang = self.pid(offset)
            lin = self.linear_speed
            self.last_offset = offset
        else:
            self.lost_count += 1
            if self.lost_count < self.MAX_LOST:
                ang = self.pid(self.last_offset) * 0.3
                lin = self.linear_speed * 0.3
            else:
                ang = 0.0
                lin = 0.0
                if self.lost_count == self.MAX_LOST:
                    self.get_logger().warn('Line lost — stopping.')

        t = Twist()
        t.linear.x = float(lin)
        t.angular.z = float(ang)
        self.cmd_pub.publish(t)

        # Debug log every 2 seconds
        self.frame_count += 1
        if self.frame_count % 100 == 0:
            s = ''.join('#' if b > 0.5 else '.' for b in binary)
            self.get_logger().info(
                f'[{s}]  off={offset:+.2f}  ang={ang:+.2f}  lin={lin:.2f}'
            )

    def compute_offset(self, binary):
        """
        Weighted center-of-mass.
        Returns offset in [-1, +1]; -1 = far left, +1 = far right.
        """
        if binary.sum() == 0:
            return 0.0, False
        idx = np.arange(len(binary))
        com = float((idx * binary).sum() / binary.sum())
        center = (len(binary) - 1) / 2.0  # = 3.5
        offset = (com - center) / center  # normalized to [-1, +1]
        return offset, True

    def pid(self, error):
        self.integral += error
        self.integral = max(min(self.integral, 2.0), -2.0)
        deriv = error - self.prev_err
        out = (self.kp * error) + (self.ki * self.integral) + (self.kd * deriv)
        self.prev_err = error
        out = max(min(out, 1.5), -1.5)
        return -out  # negative because positive offset (line right) → turn right (negative angular.z)


def main(args=None):
    rclpy.init(args=args)
    node = FollowNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.cmd_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## 📋 Step 5 — Create the Params File

```bash
nano ~/agv_ws/src/agv_brain/config/follow_params.yaml
```

Paste:

```yaml
follow_node:
  ros__parameters:
    linear_speed: 0.50      # m/s — fast enough for the warehouse scale
    kp: 0.50                # proportional gain
    ki: 0.00                # integral (only enable if there's drift)
    kd: 0.15                # derivative (smooths oscillation)
    enabled: true
```

---

## 📋 Step 6 — Create the Launch File

```bash
nano ~/agv_ws/src/agv_brain/launch/drive.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""drive.launch.py - Starts optical_node + follow_node together."""

import os
from launch import LaunchDescription
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory


def generate_launch_description():
    params = os.path.join(
        get_package_share_directory('agv_brain'),
        'config', 'follow_params.yaml'
    )

    return LaunchDescription([
        Node(package='agv_brain', executable='optical_node',
             name='optical_node', output='screen'),
        Node(package='agv_brain', executable='follow_node',
             name='follow_node', output='screen', parameters=[params]),
    ])
```

---

## 📋 Step 7 — Update `setup.py` for `agv_brain`

```bash
nano ~/agv_ws/src/agv_brain/setup.py
```

Replace with:

```python
from setuptools import setup
from glob import glob
import os

package_name = 'agv_brain'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'launch'), glob('launch/*.py')),
        (os.path.join('share', package_name, 'config'), glob('config/*.yaml')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='you',
    maintainer_email='you@example.com',
    description='AGV brain (line follower, state machine, etc.)',
    license='MIT',
    entry_points={
        'console_scripts': [
            'optical_node = agv_brain.optical_node:main',
            'follow_node  = agv_brain.follow_node:main',
        ],
    },
)
```

---

## 📋 Step 8 — Update `package.xml` for `agv_brain`

```bash
nano ~/agv_ws/src/agv_brain/package.xml
```

Replace with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>agv_brain</name>
  <version>0.1.0</version>
  <description>AGV brain - line follower and (later) state machine</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <exec_depend>rclpy</exec_depend>
  <exec_depend>nav_msgs</exec_depend>
  <exec_depend>std_msgs</exec_depend>
  <exec_depend>geometry_msgs</exec_depend>
  <exec_depend>visualization_msgs</exec_depend>
  <exec_depend>python3-numpy</exec_depend>

  <export><build_type>ament_python</build_type></export>
</package>
```

---

## 📋 Step 9 — Build

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-skip agv_msgs
source install/setup.bash
```

✅ **Test:** `Summary: 4 packages finished` with no errors.

---

## 📋 Step 10 — Run It! (The Big Test)

### Terminal 1 — World + AGV
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

Wait for everything to load.

### Terminal 2 — Brain
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain drive.launch.py
```

🎉 The AGV should **immediately start driving forward** along the main aisle line.

---

## 🔬 Verification Tests

### Test A: Watch the sensors
```bash
ros2 topic echo /agv/line_sensors
```
Should print arrays. When AGV is on the line, you'll see middle sensors at `1.0`:
```
data: [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]
```

### Test B: Watch the velocity
```bash
ros2 topic echo /agv/cmd_vel
```
Should show `linear.x: 0.5` while moving forward. `angular.z` should be small (±0.3).

### Test C: Watch the markers in RViz
In RViz:
1. Click **Add** → By topic → `/agv/line_sensors_markers` → **MarkerArray**
2. You'll see 8 colored dots tracking under the AGV. **Red = on line, Green = off line.**

### Test D: Disable / re-enable
```bash
ros2 topic pub --once /agv/follow_enable std_msgs/Bool "data: false"
# AGV stops
ros2 topic pub --once /agv/follow_enable std_msgs/Bool "data: true"
# AGV resumes
```

---

## 🎉 Stage 3 Done!

You now have:
- ✅ Virtual IR sensors (no camera, no OpenCV)
- ✅ PID line follower
- ✅ AGV drives along the main aisle on its own
- ✅ Junction detection bonus topic ready for Stage 4

### What's Next?

`STAGE_4_Brain.md` — make the AGV truly autonomous (orders, RFID, junctions, return home).

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| AGV doesn't move | Check `ros2 topic hz /agv/cmd_vel` — should be ~50Hz. If 0, check follow_node terminal for errors. |
| AGV moves super slow / wiggling crazily | Confirm params loaded: `ros2 param get /follow_node linear_speed` should be `0.5`, not `0.3`. |
| AGV oscillates side-to-side | Live tune: `ros2 param set /follow_node kp 0.4` (try smaller values). |
| All sensors stay at 0 forever | `track_lib.py` numbers don't match `build_world.py`. Re-run self-test: `python3 src/agv_brain/agv_brain/track_lib.py`. |
| AGV drifts off line at junctions | Normal! Junction handling is Stage 4. |
| Markers don't show in RViz | Set RViz Fixed Frame to `odom`. |
| `No module named 'agv_brain'` | You forgot `source install/setup.bash` in that terminal. |
| `colcon build` fails | Make sure your params YAML has correct indentation (must be 2 spaces, not tabs). |

---

## 📊 Live PID Tuning Cheat Sheet

While the system is running, you can tune in real-time:

```bash
# Make it faster
ros2 param set /follow_node linear_speed 0.7

# Make it more aggressive at correcting
ros2 param set /follow_node kp 0.7

# Smooth out oscillation
ros2 param set /follow_node kd 0.2
```

When you find values that work well, edit `follow_params.yaml` to make them permanent.
