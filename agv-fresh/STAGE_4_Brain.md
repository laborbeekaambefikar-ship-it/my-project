# 🧠 Stage 4 — Autonomous Brain (Orders + RFID + Junctions)

> **Goal:** Add the brain. The AGV will receive orders, navigate to specific shelves, return home autonomously.

**Time:** ~90 minutes. **Files created:** 3 messages + 8 Python files + 1 launch file.

---

## 🧠 The Big Idea — Junction Counting

Instead of the AGV calculating "where am I right now?", we use a much simpler trick: **count junctions**.

```
AGV at HOME, facing east:
  As it drives east on main aisle, it crosses 5 junctions:
    Junction 1 = aisle 1 (X=0)
    Junction 2 = aisle 2 (X=3)
    Junction 3 = aisle 3 (X=6)
    Junction 4 = aisle 4 (X=9)
    Junction 5 = aisle 5 (X=12)

For shelf S07: 
   S07 is in aisle 2 (because S05-S08 are in aisle 2).
   So: turn LEFT at junction #2.
```

### Math: which aisle is each shelf in?

| Shelves | Aisle | Spur X |
|---|---|---|
| S01–S04 | 1 | 0 |
| S05–S08 | 2 | 3 |
| S09–S12 | 3 | 6 |
| S13–S16 | 4 | 9 |
| S17–S20 | 5 | 12 |

Formula: `aisle = ((shelf_num - 1) // 4) + 1`.

---

## 📋 Step 1 — Create Custom Messages (`agv_msgs`)

The brain needs new "envelope types" for sending orders, RFID detections, and state updates.

```bash
mkdir -p ~/agv_ws/src/agv_msgs/msg
```

### 1.1 — `Order.msg`

```bash
nano ~/agv_ws/src/agv_msgs/msg/Order.msg
```

Paste:
```
string shelf_id
int32  aisle
string sku
```

### 1.2 — `RFIDRead.msg`

```bash
nano ~/agv_ws/src/agv_msgs/msg/RFIDRead.msg
```

Paste:
```
string  tag_id
float32 distance
bool    is_home
```

### 1.3 — `AGVState.msg`

```bash
nano ~/agv_ws/src/agv_msgs/msg/AGVState.msg
```

Paste:
```
string state
string current_target
string last_rfid
```

### 1.4 — Replace `agv_msgs/CMakeLists.txt`

```bash
nano ~/agv_ws/src/agv_msgs/CMakeLists.txt
```

Replace with:

```cmake
cmake_minimum_required(VERSION 3.8)
project(agv_msgs)

find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/Order.msg"
  "msg/RFIDRead.msg"
  "msg/AGVState.msg"
  DEPENDENCIES std_msgs
)

ament_export_dependencies(rosidl_default_runtime)
ament_package()
```

### 1.5 — Replace `agv_msgs/package.xml`

```bash
nano ~/agv_ws/src/agv_msgs/package.xml
```

Replace with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>agv_msgs</name>
  <version>0.1.0</version>
  <description>AGV custom messages</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_cmake</buildtool_depend>
  <buildtool_depend>rosidl_default_generators</buildtool_depend>

  <depend>std_msgs</depend>

  <member_of_group>rosidl_interface_packages</member_of_group>
  <exec_depend>rosidl_default_runtime</exec_depend>

  <export><build_type>ament_cmake</build_type></export>
</package>
```

### 1.6 — Build messages NOW

```bash
cd ~/agv_ws
colcon build --packages-select agv_msgs
source install/setup.bash
```

✅ **Test:**
```bash
ros2 interface show agv_msgs/msg/Order
```
Should show the 3 fields.

---

## 📋 Step 2 — Create `shelf_lib.py` (Shelf Locations)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/shelf_lib.py
```

Paste:

```python
#!/usr/bin/env python3
"""
shelf_lib.py - Shelf locations and aisle numbers.
Numbers must match build_world.py from Stage 1.
"""
from typing import Dict, List

# Layout (matches build_world.py)
SPUR_X_LIST       = [0.0, 3.0, 6.0, 9.0, 12.0]
SHELF_X_OFFSET    = -0.9
TAG_X_OFFSET      = -0.4
SHELF_Y_START     = 0.8
SHELF_Y_STEP      = 0.8
SHELVES_PER_AISLE = 4

HOME_X = -2.0
HOME_Y = 0.0


def build_shelf_map() -> Dict[str, dict]:
    shelves = {}
    n = 1
    for aisle_idx, ax in enumerate(SPUR_X_LIST, start=1):
        for slot in range(SHELVES_PER_AISLE):
            sid = f"S{n:02d}"
            shelves[sid] = {
                'shelf_x': ax + SHELF_X_OFFSET,
                'shelf_y': SHELF_Y_START + slot * SHELF_Y_STEP,
                'tag_x':   ax + TAG_X_OFFSET,
                'tag_y':   SHELF_Y_START + slot * SHELF_Y_STEP,
                'aisle':   aisle_idx,
                'aisle_x': ax,
                'slot':    slot + 1,
            }
            n += 1
    return shelves


SHELF_MAP = build_shelf_map()


def list_shelves() -> List[str]:
    return sorted(SHELF_MAP.keys())


def get_aisle(shelf_id: str) -> int:
    """Returns aisle number (1-5) for a shelf, or 0 if invalid."""
    return SHELF_MAP.get(shelf_id, {}).get('aisle', 0)


if __name__ == "__main__":
    print(f"Total shelves: {len(SHELF_MAP)}")
    for sid, d in SHELF_MAP.items():
        print(f"  {sid}: aisle={d['aisle']} slot={d['slot']} "
              f"shelf=({d['shelf_x']:+.1f},{d['shelf_y']:+.1f}) "
              f"tag=({d['tag_x']:+.1f},{d['tag_y']:+.1f})")
```

✅ **Test:**
```bash
python3 ~/agv_ws/src/agv_brain/agv_brain/shelf_lib.py
```
Should list 20 shelves.

---

## 📋 Step 3 — Create `rfid_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/rfid_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
rfid_node.py - Pose-based RFID simulation.
Watches /agv/odom; fires /agv/rfid_detected when AGV is near a tag.
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from agv_msgs.msg import RFIDRead
from agv_brain.shelf_lib import SHELF_MAP, HOME_X, HOME_Y


DETECTION_RADIUS = 0.45    # meters — tag fires when AGV within this
REARM_DISTANCE   = 0.80    # tag rearms when AGV moves this far away


class RfidNode(Node):
    def __init__(self):
        super().__init__('rfid_node')

        # All tags = shelf tags + HOME
        self.tags = {sid: (d['tag_x'], d['tag_y'], False)
                     for sid, d in SHELF_MAP.items()}
        self.tags['HOME'] = (HOME_X, HOME_Y, True)

        # "armed" = ready to fire
        self.armed = {tid: True for tid in self.tags}

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 10)
        self.pub = self.create_publisher(RFIDRead, '/agv/rfid_detected', 10)

        self.get_logger().info(f'rfid_node ready — {len(self.tags)} tags')

    def odom_cb(self, msg):
        x = msg.pose.pose.position.x
        y = msg.pose.pose.position.y

        for tid, (tx, ty, is_home) in self.tags.items():
            d = math.hypot(x - tx, y - ty)
            if d < DETECTION_RADIUS and self.armed[tid]:
                self.fire(tid, d, is_home)
                self.armed[tid] = False
            elif d > REARM_DISTANCE and not self.armed[tid]:
                self.armed[tid] = True

    def fire(self, tid, d, is_home):
        m = RFIDRead()
        m.tag_id = tid
        m.distance = float(d)
        m.is_home = is_home
        self.pub.publish(m)
        icon = 'HOME' if is_home else 'TAG'
        self.get_logger().info(f'[{icon}] {tid} (dist={d:.2f}m)')


def main(args=None):
    rclpy.init(args=args)
    node = RfidNode()
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

## 📋 Step 4 — Create `pivot_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/pivot_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
pivot_node.py - In-place rotation by a target angle.
Listens: /agv/pivot_cmd (Float32 = radians)
Outputs: /agv/cmd_vel (Twist) + /agv/pivot_done (Bool)
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import Bool, Float32
from geometry_msgs.msg import Twist


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(a, b):
    d = a - b
    while d > math.pi:  d -= 2 * math.pi
    while d < -math.pi: d += 2 * math.pi
    return d


class PivotNode(Node):
    def __init__(self):
        super().__init__('pivot_node')

        self.angular_speed = 0.7
        self.tolerance = 0.05
        self.current_yaw = 0.0
        self.target_yaw = None
        self.pivoting = False

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 10)
        self.create_subscription(Float32, '/agv/pivot_cmd', self.cmd_cb, 10)

        self.cmd_pub  = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.done_pub = self.create_publisher(Bool, '/agv/pivot_done', 10)

        self.create_timer(0.05, self.tick)
        self.get_logger().info('pivot_node ready')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        angle = float(msg.data)
        self.target_yaw = self.current_yaw + angle
        # wrap
        while self.target_yaw >  math.pi: self.target_yaw -= 2*math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2*math.pi
        self.pivoting = True
        self.get_logger().info(f'pivot start: {math.degrees(angle):.0f}deg')

    def tick(self):
        if not self.pivoting or self.target_yaw is None:
            return
        err = angle_diff(self.target_yaw, self.current_yaw)
        if abs(err) < self.tolerance:
            self.cmd_pub.publish(Twist())
            self.pivoting = False
            self.target_yaw = None
            d = Bool(); d.data = True
            self.done_pub.publish(d)
            self.get_logger().info('pivot done')
            return
        t = Twist()
        t.angular.z = self.angular_speed * (1 if err > 0 else -1)
        self.cmd_pub.publish(t)


def main(args=None):
    rclpy.init(args=args)
    node = PivotNode()
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

## 📋 Step 5 — Create `arm_node.py` (Stub)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/arm_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""arm_node.py - Stub: waits 3 seconds when triggered, then signals done."""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool


class ArmNode(Node):
    def __init__(self):
        super().__init__('arm_node')
        self.duration = 3.0
        self.timer = None
        self.create_subscription(Bool, '/arm/start', self.start_cb, 10)
        self.done_pub = self.create_publisher(Bool, '/arm/done', 10)
        self.get_logger().info('arm_node ready (stub: 3s task)')

    def start_cb(self, msg):
        if not msg.data:
            return
        self.get_logger().info('arm task starting...')
        if self.timer:
            self.timer.cancel()
        self.timer = self.create_timer(self.duration, self.finish)

    def finish(self):
        self.timer.cancel()
        self.timer = None
        d = Bool(); d.data = True
        self.done_pub.publish(d)
        self.get_logger().info('arm task done')


def main(args=None):
    rclpy.init(args=args)
    node = ArmNode()
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

## 📋 Step 6 — Create `turn_node.py` (Junction Turn Executor)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/turn_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
turn_node.py - Executes a 90° turn while disabling/re-enabling line follower.

Listens:  /agv/turn_cmd  (String: "left" or "right")
Outputs:  /agv/cmd_vel + /agv/follow_enable + /agv/turn_done

Strategy: drive slowly forward while turning until sensors detect the new
line (1-4 black sensors AFTER initial 0.5s blind period).
"""
import rclpy
from rclpy.node import Node
from std_msgs.msg import String, Bool, Float32MultiArray
from geometry_msgs.msg import Twist


class TurnNode(Node):
    def __init__(self):
        super().__init__('turn_node')

        self.turn_speed = 0.6
        self.fwd_speed  = 0.10
        self.timeout    = 5.0
        self.confirm_frames = 3

        self.turning = False
        self.direction = 0
        self.start_time = None
        self.line_count = 0
        self.sensors = [0.0]*8

        self.create_subscription(String, '/agv/turn_cmd', self.cmd_cb, 10)
        self.create_subscription(Float32MultiArray, '/agv/line_sensors',
                                  self.sensors_cb, 10)

        self.cmd_pub    = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.enable_pub = self.create_publisher(Bool,  '/agv/follow_enable', 10)
        self.done_pub   = self.create_publisher(Bool,  '/agv/turn_done', 10)

        self.create_timer(0.05, self.tick)
        self.get_logger().info('turn_node ready')

    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if d == 'left':    direction = +1
        elif d == 'right': direction = -1
        else:
            self.get_logger().warn(f'unknown turn cmd: {msg.data}')
            return

        self.get_logger().info(f'turn START: {d.upper()}')

        # Disable line follower
        e = Bool(); e.data = False
        self.enable_pub.publish(e)

        self.turning = True
        self.direction = direction
        self.start_time = self.get_clock().now()
        self.line_count = 0

    def sensors_cb(self, msg):
        if len(msg.data) >= 8:
            self.sensors = list(msg.data)

    def tick(self):
        if not self.turning:
            return

        elapsed = (self.get_clock().now() - self.start_time).nanoseconds / 1e9

        # Safety timeout
        if elapsed > self.timeout:
            self.get_logger().warn('turn TIMEOUT')
            self.finish()
            return

        # After 0.5s blind turn, watch for line reacquire
        if elapsed > 0.5:
            black = sum(1 for s in self.sensors if s > 0.5)
            if 1 <= black <= 4:
                self.line_count += 1
            else:
                self.line_count = 0
            if self.line_count >= self.confirm_frames:
                self.get_logger().info(f'turn done @ {elapsed:.1f}s')
                self.finish()
                return

        # Keep turning
        t = Twist()
        t.linear.x  = self.fwd_speed
        t.angular.z = self.turn_speed * self.direction
        self.cmd_pub.publish(t)

    def finish(self):
        self.cmd_pub.publish(Twist())
        self.turning = False

        e = Bool(); e.data = True
        self.enable_pub.publish(e)

        d = Bool(); d.data = True
        self.done_pub.publish(d)


def main(args=None):
    rclpy.init(args=args)
    node = TurnNode()
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

## 📋 Step 7 — Create `state_node.py` (The Brain)

This is the boss. ~150 lines.

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Paste:

```python
#!/usr/bin/env python3
"""
state_node.py - Mission orchestrator.

States: IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING -> RETURNING -> IDLE

Junction counting (the trick):
  - GOING:     count main-aisle junctions; turn LEFT at the Nth
  - RETURNING: on spur, first junction = back at main aisle; turn RIGHT
"""
import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from agv_msgs.msg import Order, RFIDRead, AGVState
from agv_brain.shelf_lib import SHELF_MAP


IDLE      = 'IDLE'
GOING     = 'GOING'
AT_SHELF  = 'AT_SHELF'
WAITING   = 'WAITING'
PIVOTING  = 'PIVOTING'
RETURNING = 'RETURNING'


class StateNode(Node):
    def __init__(self):
        super().__init__('state_node')

        # State
        self.state = IDLE
        self.order = None       # current Order msg
        self.junction_count = 0
        self.turning = False
        self.last_rfid = ''

        # Cooldowns
        self.last_junction_time = 0.0
        self.JUNCTION_COOLDOWN = 1.5  # seconds between counted junctions

        # Subscribers
        self.create_subscription(Order,    '/agv/order',           self.order_cb, 10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',   self.rfid_cb,  10)
        self.create_subscription(Bool,     '/agv/junction_detected',self.junc_cb, 10)
        self.create_subscription(Bool,     '/agv/turn_done',       self.turn_done_cb, 10)
        self.create_subscription(Bool,     '/arm/done',            self.arm_done_cb, 10)
        self.create_subscription(Bool,     '/agv/pivot_done',      self.pivot_done_cb, 10)

        # Publishers
        self.enable_pub = self.create_publisher(Bool,    '/agv/follow_enable', 10)
        self.cmd_pub    = self.create_publisher(Twist,   '/agv/cmd_vel', 10)
        self.turn_pub   = self.create_publisher(String,  '/agv/turn_cmd', 10)
        self.pivot_pub  = self.create_publisher(Float32, '/agv/pivot_cmd', 10)
        self.arm_pub    = self.create_publisher(Bool,    '/arm/start', 10)
        self.state_pub  = self.create_publisher(AGVState,'/agv/state', 10)

        # Periodic state broadcast
        self.create_timer(0.5, self.broadcast_state)

        # Start with line follower DISABLED
        self.set_follow(False)

        self.get_logger().info('state_node ready (state=IDLE)')

    # ============================================================
    def set_state(self, s):
        if s == self.state:
            return
        self.get_logger().info(f'STATE: {self.state} -> {s}')
        self.state = s
        self.broadcast_state()

    def broadcast_state(self):
        m = AGVState()
        m.state = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.last_rfid = self.last_rfid
        self.state_pub.publish(m)

    def set_follow(self, enabled):
        m = Bool(); m.data = enabled
        self.enable_pub.publish(m)

    def stop(self):
        self.cmd_pub.publish(Twist())

    def now(self):
        return self.get_clock().now().nanoseconds / 1e9

    # ============================================================
    def order_cb(self, msg):
        if self.state != IDLE:
            self.get_logger().warn(f'order ignored — state is {self.state}')
            return
        if msg.shelf_id not in SHELF_MAP:
            self.get_logger().error(f'unknown shelf: {msg.shelf_id}')
            return
        self.order = msg
        self.junction_count = 0
        info = SHELF_MAP[msg.shelf_id]
        self.get_logger().info(
            f'ORDER: {msg.shelf_id} (aisle {info["aisle"]}, sku={msg.sku})'
        )
        self.set_state(GOING)
        self.set_follow(True)

    def junc_cb(self, msg):
        if not msg.data:
            return
        # Cooldown to avoid double-counting same junction
        if self.now() - self.last_junction_time < self.JUNCTION_COOLDOWN:
            return
        self.last_junction_time = self.now()

        if self.turning:
            return  # ignore junctions during a turn

        if self.state == GOING and self.order:
            self.junction_count += 1
            target_aisle = SHELF_MAP[self.order.shelf_id]['aisle']
            self.get_logger().info(
                f'junction #{self.junction_count} (target aisle {target_aisle})'
            )
            if self.junction_count == target_aisle:
                self.do_turn('left')

        elif self.state == RETURNING:
            # First junction on returning = we hit the main aisle
            self.get_logger().info('hit main aisle on return')
            self.do_turn('right')

    def do_turn(self, direction):
        self.turning = True
        m = String(); m.data = direction
        self.turn_pub.publish(m)

    def turn_done_cb(self, msg):
        if not msg.data:
            return
        self.turning = False
        self.get_logger().info('turn complete')

    def rfid_cb(self, msg):
        self.last_rfid = msg.tag_id

        if self.state == GOING and self.order and msg.tag_id == self.order.shelf_id:
            self.get_logger().info(f'TARGET REACHED: {msg.tag_id}')
            self.set_follow(False)
            self.stop()
            self.set_state(AT_SHELF)
            # Trigger arm
            s = Bool(); s.data = True
            self.arm_pub.publish(s)
            self.set_state(WAITING)

        elif self.state == RETURNING and msg.is_home:
            self.get_logger().info('HOME reached — mission complete')
            self.set_follow(False)
            self.stop()
            self.order = None
            self.set_state(IDLE)

    def arm_done_cb(self, msg):
        if not msg.data or self.state != WAITING:
            return
        self.get_logger().info('arm done — pivoting 180')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        self.get_logger().info('pivot done — returning')
        self.set_state(RETURNING)
        self.junction_count = 0
        self.set_follow(True)


def main(args=None):
    rclpy.init(args=args)
    node = StateNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.stop()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## 📋 Step 8 — Create `send.py` (CLI Order Sender)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/send.py
```

Paste:

```python
#!/usr/bin/env python3
"""send.py - CLI tool to send an order. Usage: ros2 run agv_brain send S07"""
import sys
import time
import rclpy
from rclpy.node import Node
from agv_msgs.msg import Order
from agv_brain.shelf_lib import SHELF_MAP


def main():
    if len(sys.argv) < 2:
        print("Usage: ros2 run agv_brain send <SHELF_ID> [SKU]")
        print(f"Available: {', '.join(sorted(SHELF_MAP.keys()))}")
        sys.exit(1)

    shelf_id = sys.argv[1].upper()
    sku = sys.argv[2] if len(sys.argv) > 2 else 'SKU-0000'

    if shelf_id not in SHELF_MAP:
        print(f"Invalid shelf: {shelf_id}")
        sys.exit(1)

    rclpy.init()
    node = Node('order_sender')
    pub = node.create_publisher(Order, '/agv/order', 10)
    time.sleep(0.5)

    info = SHELF_MAP[shelf_id]
    m = Order()
    m.shelf_id = shelf_id
    m.aisle = info['aisle']
    m.sku = sku
    pub.publish(m)
    print(f"Order sent: {shelf_id} (aisle {info['aisle']}, sku={sku})")
    time.sleep(0.3)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## 📋 Step 9 — Update `setup.py` for `agv_brain`

```bash
nano ~/agv_ws/src/agv_brain/setup.py
```

Replace with the updated version (note the new entry_points):

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
    description='AGV brain',
    license='MIT',
    entry_points={
        'console_scripts': [
            'optical_node = agv_brain.optical_node:main',
            'follow_node  = agv_brain.follow_node:main',
            'rfid_node    = agv_brain.rfid_node:main',
            'turn_node    = agv_brain.turn_node:main',
            'pivot_node   = agv_brain.pivot_node:main',
            'arm_node     = agv_brain.arm_node:main',
            'state_node   = agv_brain.state_node:main',
            'send         = agv_brain.send:main',
        ],
    },
)
```

---

## 📋 Step 10 — Update `package.xml` for `agv_brain`

```bash
nano ~/agv_ws/src/agv_brain/package.xml
```

Replace with:

```xml
<?xml version="1.0"?>
<package format="3">
  <name>agv_brain</name>
  <version>0.1.0</version>
  <description>AGV brain (line follower + autonomy)</description>
  <maintainer email="you@example.com">you</maintainer>
  <license>MIT</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <exec_depend>rclpy</exec_depend>
  <exec_depend>nav_msgs</exec_depend>
  <exec_depend>std_msgs</exec_depend>
  <exec_depend>geometry_msgs</exec_depend>
  <exec_depend>visualization_msgs</exec_depend>
  <exec_depend>agv_msgs</exec_depend>
  <exec_depend>python3-numpy</exec_depend>

  <export><build_type>ament_python</build_type></export>
</package>
```

---

## 📋 Step 11 — Create the Brain Launch File

```bash
nano ~/agv_ws/src/agv_brain/launch/brain.launch.py
```

Paste:

```python
#!/usr/bin/env python3
"""brain.launch.py - Launches all 7 brain nodes."""

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
        Node(package='agv_brain', executable='optical_node', name='optical_node', output='screen'),
        Node(package='agv_brain', executable='follow_node',  name='follow_node',  output='screen', parameters=[params]),
        Node(package='agv_brain', executable='rfid_node',    name='rfid_node',    output='screen'),
        Node(package='agv_brain', executable='turn_node',    name='turn_node',    output='screen'),
        Node(package='agv_brain', executable='pivot_node',   name='pivot_node',   output='screen'),
        Node(package='agv_brain', executable='arm_node',     name='arm_node',     output='screen'),
        Node(package='agv_brain', executable='state_node',   name='state_node',   output='screen'),
    ])
```

---

## 📋 Step 12 — Build EVERYTHING

```bash
cd ~/agv_ws
colcon build --symlink-install
source install/setup.bash
```

✅ **Test:** `Summary: 5 packages finished` with no errors.

---

## 📋 Step 13 — Run the Full Mission!

### Terminal 1 — World + AGV
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

### Terminal 2 — Brain (all 7 nodes)
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```

The AGV should be **idle** at HOME (line follower disabled until order arrives).

### Terminal 3 — Send an order
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S07
```

🎉 **Watch the magic:**
1. State goes `IDLE -> GOING`
2. Line follower enabled
3. AGV drives east on main aisle
4. Crosses junction 1 (X=0): logs `junction #1 (target aisle 2)`
5. Crosses junction 2 (X=3): logs `junction #2 (target aisle 2)` then `turn START: LEFT`
6. AGV turns left, finds the spur line
7. Drives north on spur 2
8. Reaches S07 RFID tag → `TARGET REACHED: S07`
9. State: `GOING -> AT_SHELF -> WAITING`
10. Arm waits 3s → `arm task done`
11. State: `WAITING -> PIVOTING`
12. AGV rotates 180°
13. State: `PIVOTING -> RETURNING`
14. AGV drives back south on spur
15. Hits main aisle (junction!) → `turn START: RIGHT`
16. Turns right, drives west on main aisle
17. Reaches HOME → `HOME reached - mission complete`
18. State: `RETURNING -> IDLE`

### Verify with logs
In Terminal 2 you'll see all the state transitions. In Terminal 3, send another order to a different shelf:

```bash
ros2 run agv_brain send S13
```

This should turn at junction #4 (since S13 is in aisle 4).

---

## 🎉 Stage 4 Done!

You now have a **fully autonomous warehouse AGV**:
- ✅ Receives orders via CLI
- ✅ Counts junctions to navigate
- ✅ Detects shelves via RFID
- ✅ Pivots and returns home
- ✅ Resets to IDLE for next order

### What's Next?

`STAGE_5_GUI.md` — replace the CLI with a nice GUI + order queue.

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| `agv_msgs not found` | You forgot `source install/setup.bash` |
| AGV doesn't start moving after order | Check Terminal 2 — does state_node log show `STATE: IDLE -> GOING`? |
| AGV starts but doesn't turn | Watch logs for `junction #N`. If no junctions detected, optical sensors aren't seeing the wide black areas at intersections. Check RViz markers — when AGV crosses junction, all 8 should turn red briefly. |
| AGV turns at WRONG junction | Double-check shelf number → aisle math. S05–S08 = aisle 2, S09–S12 = aisle 3, etc. |
| Turn never finishes | Either `turn_node`'s sensor confirm count is too high (try `confirm_frames=2`) or AGV missed the new line. Increase `timeout`. |
| AGV passes shelf without stopping | Increase `DETECTION_RADIUS` in `rfid_node.py` to 0.6 |
| Pivot is messy | Increase `tolerance` in `pivot_node.py` to 0.08 |
| AGV doesn't return home | Check that pivot completed (state should be `RETURNING`). Check that follow_enable is True. |
| State stuck on something | `ros2 topic echo /agv/state` will show you what's happening. |

---

## 🔍 Powerful Debug Commands

```bash
# Watch state transitions live
ros2 topic echo /agv/state

# See all junctions as they happen
ros2 topic echo /agv/junction_detected

# See RFID detections
ros2 topic echo /agv/rfid_detected

# Visualize node graph
rqt_graph
```
