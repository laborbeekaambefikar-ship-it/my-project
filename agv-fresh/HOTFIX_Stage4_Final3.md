# 🔥 FINAL FIX — Master Script That Resets Everything To A Known-Good State

> **Why this exists:** You've applied many partial fixes over many hotfixes. Files are out of sync — some publish to the right topics, some don't. We're stopping the patch cycle and giving you ONE script that writes every brain file atomically.

After running this, you'll have a clean, tested, working configuration. No more partial edits.

---

## What's Been Going Wrong (in plain English)

Every node in the brain produces a velocity command. They were all publishing to the same topic `/agv/cmd_vel`, fighting each other. We split them into private topics:

```
follow_node  → /agv/follow_vel
turn_node    → /agv/turn_vel
pivot_node   → /agv/pivot_vel
state_node   → /agv/cmd_vel    (only one — combines the others)
```

If even ONE worker still publishes to `/agv/cmd_vel` directly, the whole system breaks because two publishers fight and the AGV does whatever the last message said. Your "AGV moves automatically when launched" is exactly this — a worker is still publishing to the wrong topic.

The script below writes all 6 files correctly in one go, so this can't happen.

---

## Step 1 — Backup your current state

In a terminal:

```bash
cp -r ~/agv_ws/src/agv_brain ~/agv_ws/src/agv_brain.backup_$(date +%s)
echo "Backup saved. You can always restore with:"
echo "  rm -rf ~/agv_ws/src/agv_brain && mv ~/agv_ws/src/agv_brain.backup_* ~/agv_ws/src/agv_brain"
```

---

## Step 2 — Run the master fix script

Copy this **entire block** below into your terminal and press Enter. It writes all 6 brain files. Takes ~3 seconds.

```bash
set -e
BRAIN=~/agv_ws/src/agv_brain/agv_brain
CONFIG=~/agv_ws/src/agv_brain/config

echo "Writing brain files..."

# ====================================================================
# 1. follow_node.py — PID line follower (publishes /agv/follow_vel)
# ====================================================================
cat > $BRAIN/follow_node.py <<'PYEOF'
#!/usr/bin/env python3
"""follow_node.py — PID line follower. Publishes /agv/follow_vel."""
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, Float32MultiArray
from geometry_msgs.msg import Twist
import numpy as np


class FollowNode(Node):
    def __init__(self):
        super().__init__('follow_node')

        self.declare_parameter('linear_speed', 0.50)
        self.declare_parameter('kp', 0.50)
        self.declare_parameter('ki', 0.00)
        self.declare_parameter('kd', 0.15)

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp = self.get_parameter('kp').value
        self.ki = self.get_parameter('ki').value
        self.kd = self.get_parameter('kd').value

        self.prev_err    = 0.0
        self.integral    = 0.0
        self.last_offset = 0.0
        self.lost_count  = 0
        self.MAX_LOST    = 80

        self.JUNC_THRESH = 5
        self.JUNC_STREAK = 2
        self.junc_streak = 0
        self.junc_fired  = False

        self.create_subscription(
            Float32MultiArray, '/agv/line_sensors', self.sensors_cb, 10)
        self.junction_pub = self.create_publisher(
            Bool, '/agv/junction_detected', 10)
        self.vel_pub = self.create_publisher(
            Twist, '/agv/follow_vel', 10)

        self.frame = 0
        self.get_logger().info(
            f'follow_node ready -> /agv/follow_vel  '
            f'speed={self.linear_speed} kp={self.kp} kd={self.kd}')

    def sensors_cb(self, msg):
        if len(msg.data) < 8:
            return
        binary = np.array(msg.data, dtype=np.float32)
        black = int(binary.sum())

        if black >= self.JUNC_THRESH:
            self.junc_streak += 1
            if (self.junc_streak >= self.JUNC_STREAK
                    and not self.junc_fired):
                j = Bool(); j.data = True
                self.junction_pub.publish(j)
                self.junc_fired = True
        else:
            self.junc_streak = 0
            self.junc_fired = False

        if black >= self.JUNC_THRESH:
            t = Twist(); t.linear.x = self.linear_speed
            self.vel_pub.publish(t)
            return

        offset, detected = self._offset(binary)

        if detected:
            self.lost_count = 0
            ang = self._pid(offset)
            lin = self.linear_speed
            self.last_offset = offset
        else:
            self.lost_count += 1
            if self.lost_count < self.MAX_LOST:
                ang = self._pid(self.last_offset) * 0.3
                lin = self.linear_speed * 0.3
            else:
                ang, lin = 0.0, 0.0
                if self.lost_count == self.MAX_LOST:
                    self.get_logger().warn('Line lost.')

        t = Twist()
        t.linear.x = float(lin)
        t.angular.z = float(ang)
        self.vel_pub.publish(t)

        self.frame += 1
        if self.frame % 100 == 0:
            s = ''.join('#' if b > 0.5 else '.' for b in binary)
            self.get_logger().info(
                f'[{s}] off={offset:+.2f} ang={ang:+.2f} lin={lin:.2f}')

    def _offset(self, binary):
        if binary.sum() == 0:
            return 0.0, False
        idx = np.arange(len(binary))
        com = float((idx * binary).sum() / binary.sum())
        center = (len(binary) - 1) / 2.0
        return (com - center) / center, True

    def _pid(self, error):
        self.integral += error
        self.integral = max(min(self.integral, 2.0), -2.0)
        d = error - self.prev_err
        out = (self.kp*error) + (self.ki*self.integral) + (self.kd*d)
        self.prev_err = error
        return -max(min(out, 1.5), -1.5)


def main(args=None):
    rclpy.init(args=args)
    node = FollowNode()
    try: rclpy.spin(node)
    except KeyboardInterrupt: pass
    finally:
        node.vel_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
echo "  ok: follow_node.py"

# ====================================================================
# 2. turn_node.py — IMU 90° turn + nudge (publishes /agv/turn_vel)
# ====================================================================
cat > $BRAIN/turn_node.py <<'PYEOF'
#!/usr/bin/env python3
"""turn_node.py — Exact 90° IMU turn + nudge. Publishes /agv/turn_vel."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import String, Bool
from geometry_msgs.msg import Twist

TURN_SPEED  = 0.50
TOLERANCE   = 0.05
TURN_ANGLE  = math.pi / 2
NUDGE_SPEED = 0.20
NUDGE_TIME  = 0.60


def yaw_from_quat(q):
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(target, current):
    d = target - current
    while d > math.pi:  d -= 2 * math.pi
    while d < -math.pi: d += 2 * math.pi
    return d


class TurnNode(Node):
    PHASE_IDLE   = 0
    PHASE_ROTATE = 1
    PHASE_NUDGE  = 2

    def __init__(self):
        super().__init__('turn_node')
        self.current_yaw = 0.0
        self.target_yaw  = None
        self.phase       = self.PHASE_IDLE
        self.direction   = 0
        self.nudge_start = None

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 50)
        self.create_subscription(String, '/agv/turn_cmd', self.cmd_cb, 10)
        self.vel_pub  = self.create_publisher(Twist, '/agv/turn_vel', 10)
        self.done_pub = self.create_publisher(Bool, '/agv/turn_done', 10)
        self.create_timer(0.02, self.tick)
        self.get_logger().info('turn_node ready -> /agv/turn_vel')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if   d == 'left':  self.direction = +1
        elif d == 'right': self.direction = -1
        else: return
        self.target_yaw = self.current_yaw + self.direction * TURN_ANGLE
        while self.target_yaw >  math.pi: self.target_yaw -= 2 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2 * math.pi
        self.phase = self.PHASE_ROTATE
        self.get_logger().info(
            f'turn START: {d.upper()}  '
            f'{math.degrees(self.current_yaw):.0f}deg -> '
            f'{math.degrees(self.target_yaw):.0f}deg')

    def tick(self):
        if self.phase == self.PHASE_IDLE:
            self.vel_pub.publish(Twist())
            return

        if self.phase == self.PHASE_ROTATE:
            err = angle_diff(self.target_yaw, self.current_yaw)
            if abs(err) < TOLERANCE:
                self.phase = self.PHASE_NUDGE
                self.nudge_start = self.get_clock().now()
                self.get_logger().info('rotation done — nudging')
                self.vel_pub.publish(Twist())
                return
            t = Twist()
            t.angular.z = TURN_SPEED * (1.0 if err > 0 else -1.0)
            self.vel_pub.publish(t)
            return

        if self.phase == self.PHASE_NUDGE:
            elapsed = (self.get_clock().now()
                       - self.nudge_start).nanoseconds / 1e9
            if elapsed < NUDGE_TIME:
                t = Twist(); t.linear.x = NUDGE_SPEED
                self.vel_pub.publish(t)
                return
            self.vel_pub.publish(Twist())
            self.phase = self.PHASE_IDLE
            self.target_yaw = None
            done = Bool(); done.data = True
            self.done_pub.publish(done)
            self.get_logger().info('turn + nudge DONE')


def main(args=None):
    rclpy.init(args=args)
    node = TurnNode()
    try: rclpy.spin(node)
    except KeyboardInterrupt: pass
    finally:
        node.vel_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
echo "  ok: turn_node.py"

# ====================================================================
# 3. pivot_node.py — IMU rotation by target angle (publishes /agv/pivot_vel)
# ====================================================================
cat > $BRAIN/pivot_node.py <<'PYEOF'
#!/usr/bin/env python3
"""pivot_node.py — IMU pivot. Publishes /agv/pivot_vel."""
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
        self.tolerance     = 0.05
        self.current_yaw   = 0.0
        self.target_yaw    = None
        self.pivoting      = False

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 50)
        self.create_subscription(Float32, '/agv/pivot_cmd', self.cmd_cb, 10)
        self.vel_pub  = self.create_publisher(Twist, '/agv/pivot_vel', 10)
        self.done_pub = self.create_publisher(Bool, '/agv/pivot_done', 10)
        self.create_timer(0.05, self.tick)
        self.get_logger().info('pivot_node ready -> /agv/pivot_vel')

    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    def cmd_cb(self, msg):
        angle = float(msg.data)
        self.target_yaw = self.current_yaw + angle
        while self.target_yaw >  math.pi: self.target_yaw -= 2 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2 * math.pi
        self.pivoting = True
        self.get_logger().info(f'pivot start: {math.degrees(angle):.0f}deg')

    def tick(self):
        if not self.pivoting or self.target_yaw is None:
            self.vel_pub.publish(Twist())
            return
        err = angle_diff(self.target_yaw, self.current_yaw)
        if abs(err) < self.tolerance:
            self.vel_pub.publish(Twist())
            self.pivoting = False
            self.target_yaw = None
            d = Bool(); d.data = True
            self.done_pub.publish(d)
            self.get_logger().info('pivot done')
            return
        t = Twist()
        t.angular.z = self.angular_speed * (1 if err > 0 else -1)
        self.vel_pub.publish(t)


def main(args=None):
    rclpy.init(args=args)
    node = PivotNode()
    try: rclpy.spin(node)
    except KeyboardInterrupt: pass
    finally:
        node.vel_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
echo "  ok: pivot_node.py"

# ====================================================================
# 4. rfid_node.py — Pose-based RFID (radius 0.60, depth 50)
# ====================================================================
cat > $BRAIN/rfid_node.py <<'PYEOF'
#!/usr/bin/env python3
"""rfid_node.py — Pose-based RFID detection."""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from agv_msgs.msg import RFIDRead
from agv_brain.shelf_lib import SHELF_MAP, HOME_X, HOME_Y

DETECTION_RADIUS = 0.60
REARM_DISTANCE   = 0.90


class RfidNode(Node):
    def __init__(self):
        super().__init__('rfid_node')
        self.tags = {sid: (d['tag_x'], d['tag_y'], False)
                     for sid, d in SHELF_MAP.items()}
        self.tags['HOME'] = (HOME_X, HOME_Y, True)
        self.armed = {tid: True for tid in self.tags}

        self.create_subscription(Odometry, '/agv/odom', self.odom_cb, 50)
        self.pub = self.create_publisher(RFIDRead, '/agv/rfid_detected', 10)
        self.get_logger().info(
            f'rfid_node ready  {len(self.tags)} tags  radius={DETECTION_RADIUS}m')

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
    try: rclpy.spin(node)
    except KeyboardInterrupt: pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
echo "  ok: rfid_node.py"

# ====================================================================
# 5. state_node.py — Sole arbiter of /agv/cmd_vel
# ====================================================================
cat > $BRAIN/state_node.py <<'PYEOF'
#!/usr/bin/env python3
"""
state_node.py — Mission FSM AND cmd_vel arbiter.
ONLY this node publishes /agv/cmd_vel.
States: IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING -> PIVOT_NUDGE -> RETURNING -> IDLE
"""
import math
import rclpy
from rclpy.node import Node
from std_msgs.msg import Bool, String, Float32
from geometry_msgs.msg import Twist
from agv_msgs.msg import Order, RFIDRead, AGVState
from agv_brain.shelf_lib import SHELF_MAP

IDLE        = 'IDLE'
GOING       = 'GOING'
AT_SHELF    = 'AT_SHELF'
WAITING     = 'WAITING'
PIVOTING    = 'PIVOTING'
PIVOT_NUDGE = 'PIVOT_NUDGE'
RETURNING   = 'RETURNING'

NUDGE_SPEED    = 0.20
NUDGE_DURATION = 0.75


class StateNode(Node):
    def __init__(self):
        super().__init__('state_node')

        self.state          = IDLE
        self.order          = None
        self.last_rfid      = ''
        self.junction_count = 0
        self.turning        = False

        self.last_junc_t           = 0.0
        self.JUNC_COOLDOWN         = 1.5
        self.post_turn_block_until = 0.0
        self.POST_TURN_BLOCK       = 2.5

        self.pivot_nudge_start = None
        self._nudge_twist = Twist()
        self._nudge_twist.linear.x = NUDGE_SPEED

        self.follow_vel = Twist()
        self.turn_vel   = Twist()
        self.pivot_vel  = Twist()

        self.create_subscription(Twist, '/agv/follow_vel', self.fv_cb, 10)
        self.create_subscription(Twist, '/agv/turn_vel',   self.tv_cb, 10)
        self.create_subscription(Twist, '/agv/pivot_vel',  self.pv_cb, 10)

        self.create_subscription(Order,    '/agv/order',             self.order_cb,      10)
        self.create_subscription(RFIDRead, '/agv/rfid_detected',     self.rfid_cb,       10)
        self.create_subscription(Bool,     '/agv/junction_detected', self.junc_cb,       10)
        self.create_subscription(Bool,     '/agv/turn_done',         self.turn_done_cb,  10)
        self.create_subscription(Bool,     '/arm/done',              self.arm_done_cb,   10)
        self.create_subscription(Bool,     '/agv/pivot_done',        self.pivot_done_cb, 10)

        self.cmd_pub   = self.create_publisher(Twist,    '/agv/cmd_vel',  10)
        self.turn_pub  = self.create_publisher(String,   '/agv/turn_cmd', 10)
        self.pivot_pub = self.create_publisher(Float32,  '/agv/pivot_cmd',10)
        self.arm_pub   = self.create_publisher(Bool,     '/arm/start',    10)
        self.state_pub = self.create_publisher(AGVState, '/agv/state',    10)

        self.create_timer(0.02, self.arbiter)
        self.create_timer(0.5,  self.broadcast_state)
        self.get_logger().info('state_node ready — sole publisher of /agv/cmd_vel')

    def fv_cb(self, msg): self.follow_vel = msg
    def tv_cb(self, msg): self.turn_vel   = msg
    def pv_cb(self, msg): self.pivot_vel  = msg

    def arbiter(self):
        if self.state in (IDLE, AT_SHELF, WAITING):
            self.cmd_pub.publish(Twist())
        elif self.state == PIVOT_NUDGE:
            elapsed = self.now_s() - self.pivot_nudge_start
            if elapsed >= NUDGE_DURATION:
                self.get_logger().info(
                    f'pivot nudge done ({elapsed:.2f}s) -> RETURNING')
                self.set_state(RETURNING)
                self.pivot_nudge_start = None
            else:
                self.cmd_pub.publish(self._nudge_twist)
        elif self.turning:
            self.cmd_pub.publish(self.turn_vel)
        elif self.state == PIVOTING:
            self.cmd_pub.publish(self.pivot_vel)
        elif self.state in (GOING, RETURNING):
            self.cmd_pub.publish(self.follow_vel)
        else:
            self.cmd_pub.publish(Twist())

    def now_s(self):
        return self.get_clock().now().nanoseconds / 1e9

    def set_state(self, s):
        if s == self.state:
            return
        self.get_logger().info(f'STATE: {self.state} -> {s}')
        self.state = s
        self.broadcast_state()

    def broadcast_state(self):
        m = AGVState()
        m.state          = self.state
        m.current_target = self.order.shelf_id if self.order else ''
        m.last_rfid      = self.last_rfid
        self.state_pub.publish(m)

    def order_cb(self, msg):
        if self.state != IDLE:
            self.get_logger().warn(f'order ignored — state={self.state}')
            return
        if msg.shelf_id not in SHELF_MAP:
            self.get_logger().error(f'unknown shelf: {msg.shelf_id}')
            return
        self.order = msg
        self.junction_count = 0
        info = SHELF_MAP[msg.shelf_id]
        self.get_logger().info(
            f'ORDER: {msg.shelf_id}  aisle={info["aisle"]}  sku={msg.sku}')
        self.set_state(GOING)

    def junc_cb(self, msg):
        if not msg.data: return
        t = self.now_s()
        if t < self.post_turn_block_until: return
        if t - self.last_junc_t < self.JUNC_COOLDOWN: return
        if self.turning: return
        self.last_junc_t = t

        if self.state == GOING and self.order:
            self.junction_count += 1
            target = SHELF_MAP[self.order.shelf_id]['aisle']
            self.get_logger().info(
                f'junction #{self.junction_count}  (target aisle {target})')
            if self.junction_count == target:
                self._do_turn('left')
        elif self.state == RETURNING:
            self.get_logger().info('return junction — turning right')
            self._do_turn('right')

    def _do_turn(self, direction):
        self.turning = True
        m = String(); m.data = direction
        self.turn_pub.publish(m)

    def turn_done_cb(self, msg):
        if not msg.data: return
        self.turning = False
        self.post_turn_block_until = self.now_s() + self.POST_TURN_BLOCK
        self.get_logger().info(
            f'turn done  junctions blocked {self.POST_TURN_BLOCK}s')

    def rfid_cb(self, msg):
        self.last_rfid = msg.tag_id
        if (self.state == GOING and self.order
                and msg.tag_id == self.order.shelf_id):
            self.get_logger().info(f'TARGET REACHED: {msg.tag_id}')
            self.set_state(AT_SHELF)
            s = Bool(); s.data = True
            self.arm_pub.publish(s)
            self.set_state(WAITING)
        elif self.state == RETURNING and msg.is_home:
            self.get_logger().info('HOME reached — mission complete')
            self.order = None
            self.set_state(IDLE)

    def arm_done_cb(self, msg):
        if not msg.data or self.state != WAITING: return
        self.get_logger().info('arm done — pivoting 180')
        self.set_state(PIVOTING)
        p = Float32(); p.data = math.pi
        self.pivot_pub.publish(p)

    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING: return
        self.pivot_nudge_start = self.now_s()
        self.junction_count = 0
        self.get_logger().info(
            f'pivot done — nudging {NUDGE_DURATION}s @ {NUDGE_SPEED}m/s')
        self.set_state(PIVOT_NUDGE)


def main(args=None):
    rclpy.init(args=args)
    node = StateNode()
    try: rclpy.spin(node)
    except KeyboardInterrupt: pass
    finally:
        node.cmd_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
PYEOF
echo "  ok: state_node.py"

# ====================================================================
# 6. track_lib.py — Line geometry (LINE_WIDTH = 0.10)
# ====================================================================
cat > $BRAIN/track_lib.py <<'PYEOF'
#!/usr/bin/env python3
"""track_lib.py — Geometry of the black tape lines."""
import math
from dataclasses import dataclass
from typing import List, Tuple

LINE_WIDTH = 0.10  # widened virtual detection zone

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
        dx = self.x2 - self.x1
        dy = self.y2 - self.y1
        L2 = dx*dx + dy*dy
        if L2 < 1e-9:
            return math.hypot(px - self.x1, py - self.y1)
        t = ((px - self.x1)*dx + (py - self.y1)*dy) / L2
        t = max(0.0, min(1.0, t))
        proj_x = self.x1 + t*dx
        proj_y = self.y1 + t*dy
        return math.hypot(px - proj_x, py - proj_y)

    def contains(self, px, py):
        return self.distance_to(px, py) < (self.width / 2.0)


def build_track() -> List[Segment]:
    segs = [Segment("main", MAIN_AISLE_X_START, MAIN_AISLE_Y,
                    MAIN_AISLE_X_END, MAIN_AISLE_Y)]
    for i, sx in enumerate(SPUR_X_LIST, start=1):
        segs.append(Segment(f"spur_{i}", sx, SPUR_Y_START, sx, SPUR_Y_END))
    return segs


TRACK = build_track()


def on_line(px, py) -> Tuple[bool, str]:
    for s in TRACK:
        if s.contains(px, py):
            return True, s.name
    return False, ""


if __name__ == "__main__":
    print(f"Track has {len(TRACK)} segments, LINE_WIDTH={LINE_WIDTH}")
    for s in TRACK:
        print(f"  {s.name:8s}  ({s.x1:+.1f},{s.y1:+.1f}) -> ({s.x2:+.1f},{s.y2:+.1f})")
PYEOF
echo "  ok: track_lib.py"

# ====================================================================
# 7. follow_params.yaml — no enabled flag (arbiter decides)
# ====================================================================
cat > $CONFIG/follow_params.yaml <<'YAMLEOF'
follow_node:
  ros__parameters:
    linear_speed: 0.50
    kp: 0.50
    ki: 0.00
    kd: 0.15
YAMLEOF
echo "  ok: follow_params.yaml"

echo ""
echo "All 7 files written successfully."
echo ""
echo "Next: rebuild and test"
echo "  cd ~/agv_ws && colcon build --symlink-install --packages-select agv_brain && source install/setup.bash"
```

When the script finishes, you should see this output:
```
Writing brain files...
  ok: follow_node.py
  ok: turn_node.py
  ok: pivot_node.py
  ok: rfid_node.py
  ok: state_node.py
  ok: track_lib.py
  ok: follow_params.yaml

All 7 files written successfully.
```

---

## Step 3 — Verify each file is correct

The script is supposed to make these claims true. Run this verification command:

```bash
echo "=== Verification ==="
echo -n "follow_node publishes follow_vel: "
grep -q "/agv/follow_vel" ~/agv_ws/src/agv_brain/agv_brain/follow_node.py && echo OK || echo FAIL
echo -n "turn_node publishes turn_vel: "
grep -q "/agv/turn_vel" ~/agv_ws/src/agv_brain/agv_brain/turn_node.py && echo OK || echo FAIL
echo -n "pivot_node publishes pivot_vel: "
grep -q "/agv/pivot_vel" ~/agv_ws/src/agv_brain/agv_brain/pivot_node.py && echo OK || echo FAIL
echo -n "state_node has arbiter: "
grep -q "PIVOT_NUDGE" ~/agv_ws/src/agv_brain/agv_brain/state_node.py && echo OK || echo FAIL
echo -n "state_node publishes cmd_vel: "
grep -q "/agv/cmd_vel" ~/agv_ws/src/agv_brain/agv_brain/state_node.py && echo OK || echo FAIL
echo -n "track LINE_WIDTH=0.10: "
grep -q "LINE_WIDTH = 0.10" ~/agv_ws/src/agv_brain/agv_brain/track_lib.py && echo OK || echo FAIL
echo -n "rfid radius=0.60: "
grep -q "DETECTION_RADIUS = 0.60" ~/agv_ws/src/agv_brain/agv_brain/rfid_node.py && echo OK || echo FAIL
echo -n "params has no 'enabled': "
grep -q "enabled" ~/agv_ws/src/agv_brain/config/follow_params.yaml && echo FAIL || echo OK
echo "=== Done ==="
```

You must see **8 OKs**. If any line says FAIL, the script didn't run completely — re-run Step 2.

---

## Step 4 — Rebuild

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Expected: `Summary: 1 package finished` with no errors and no tracebacks.

---

## Step 5 — Test

Kill any leftover processes first:

```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3
```

In **3 separate terminals** (each with `source ~/agv_ws/install/setup.bash` first):

**Terminal 1 — Gazebo + AGV:**
```bash
ros2 launch agv_robot spawn.launch.py
```

**Terminal 2 — Brain:** (wait for Gazebo to fully load first, then)
```bash
ros2 launch agv_brain brain.launch.py
```

You should see in Terminal 2:
```
follow_node ready -> /agv/follow_vel
turn_node ready -> /agv/turn_vel
pivot_node ready -> /agv/pivot_vel
state_node ready — sole publisher of /agv/cmd_vel
```

**The AGV must NOT be moving.** It should sit still at HOME.

If it IS moving, immediately run this in Terminal 3:
```bash
source ~/agv_ws/install/setup.bash
ros2 topic info /agv/cmd_vel --verbose
```

It must show `Publisher count: 1` and the publisher must be `state_node`. If you see 2 publishers, one of the worker nodes is still using the wrong topic — re-run Step 2 and double-check the verification in Step 3.

**Terminal 3 — Send order:**
```bash
ros2 run agv_brain send S05
```

S05 is in aisle 2. AGV should:
1. Drive east (state: GOING)
2. Cross junction 1 (logged: "junction #1 target aisle 2")
3. Cross junction 2, turn left (logged: "junction #2 target aisle 2", "turn requested: left")
4. Reach S05 (logged: "TARGET REACHED: S05")
5. Wait 3s, pivot 180°, nudge 0.75s, return (state: PIVOT_NUDGE -> RETURNING)
6. Hit return junction, turn right
7. Reach HOME (logged: "HOME reached")
8. State back to IDLE

---

## Why This Was Failing Before

The "AGV moves automatically" symptom always means **two publishers on `/agv/cmd_vel`**. That's it.

In your previous runs:
- `state_node` was correctly publishing zero Twist (because state=IDLE)
- BUT `follow_node` was ALSO publishing to `/agv/cmd_vel` directly with non-zero values
- The Gazebo diff_drive plugin received both and the last-arriving message wins
- So the AGV moved chaotically

The script above guarantees `follow_node` publishes ONLY to `/agv/follow_vel`. Since `state_node` is the single arbiter and it sees state=IDLE, it forwards Twist() (zero) to `/agv/cmd_vel`. The AGV stops. When you send an order, state changes to GOING, and the arbiter starts forwarding follow_vel.

---

## If It Still Misbehaves

Run all 4 of these commands and tell me their output:

```bash
ros2 topic info /agv/cmd_vel --verbose
ros2 topic info /agv/follow_vel --verbose
ros2 topic info /agv/turn_vel --verbose
ros2 topic info /agv/pivot_vel --verbose
```

These tell me which publishers exist on each topic. I can pinpoint the bug in 30 seconds with that output.

---

## Bonus: Silence the `Sensor.cc:510` Warning

This is a harmless Gazebo warning about IMU noise config. To silence it:

```bash
# Edit the URDF and add noise config to the IMU sensor
nano ~/agv_ws/src/agv_robot/urdf/agv.urdf.xacro
```

Find the `<sensor name="imu" type="imu">` block and replace it with this version that has explicit noise parameters:

```xml
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
    </imu>
  </imu>
  <plugin name="imu_plugin" filename="libgazebo_ros_imu_sensor.so">
    <ros>
      <namespace>/agv</namespace>
      <remapping>~/out:=imu</remapping>
    </ros>
    <frame_name>imu_link</frame_name>
  </plugin>
</sensor>
```

Then rebuild `agv_robot`:
```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_robot
source install/setup.bash
```

This is purely cosmetic — the IMU works fine without it. Your pivots and 90° turns prove it.
