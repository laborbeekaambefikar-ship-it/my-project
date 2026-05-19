# 🔥 HOTFIX — AGV Hops Off Line at Junction Turn

## What You See
The AGV reaches a junction, starts turning, then:
- Spins past the spur line completely
- Ends up at a diagonal angle
- Falls off the line
- Mission gets stuck

## Root Cause (Exact)

The current `turn_node.py` uses a **sensor-watching exit strategy**:

```
1. Start turning at 0.60 rad/s
2. Wait 0.5s (warmup)
3. Watch sensors — if 1-4 black sensors for 3 consecutive frames → "spur found!"
4. If never found → timeout after 6s
```

This fails for **three compounding reasons**:

### Reason 1: The spur line is only 5 cm wide
At 0.60 rad/s angular speed, the AGV's sensor array sweeps across that
5 cm spur in about **0.08 seconds** (2-4 sensor frames at 50 Hz).
The `confirm_frames = 3` requirement needs 3 consecutive frames = 0.06s minimum.
The spur is gone before the 3rd frame arrives. The condition never triggers.

### Reason 2: Forward motion during turn physically moves AGV off centre
`fwd_speed = 0.10 m/s` during the turn means the AGV travels ~8 cm forward
over 6 seconds of turning. This physically repositions the AGV centre off
the junction crossing point, making line reacquisition harder.

### Reason 3: 6-second timeout = 3.6 full rotations
When the sensor check never fires, the timeout kills the turn after 6 seconds.
At 0.60 rad/s, that is `6 × 0.60 = 3.6 radians = 206°` of rotation.
The AGV ends up pointing a random direction, nowhere near 90° from its start.

## The Fix — IMU Yaw Controlled Turn (Same as `pivot_node`)

`pivot_node` already does **exact-angle rotation** using odometry yaw and it
works perfectly for the 180° pivot. We apply the exact same approach to
junction turns.

```
NEW turn strategy:
  1. Record current yaw from /agv/odom when turn command arrives
  2. Compute target yaw = current_yaw ± 90° (π/2 radians)
  3. Rotate at 0.50 rad/s until |yaw_error| < 0.05 rad (~3°)
  4. Stop. Done. Exact 90° every time.
  5. No sensors watched during the turn at all.
  6. After turn_done fires, line follower reacquires the spur line.
```

### Why this works
- **Exact angle**: The exit condition is a yaw measurement, not a sensor flash.
  The turn always completes exactly 90°, putting the AGV facing directly
  up the spur regardless of line width or turn speed.
- **No forward motion during turn**: Pure in-place rotation (`linear.x = 0`).
  The AGV stays at the junction centre, directly over the spur line.
- **Same logic as pivot_node**: We know this approach works — it's why the
  180° pivot succeeds every time.

---

## What You Change

**Only ONE file changes: `turn_node.py`**

Everything else — `follow_node.py`, `pivot_node.py`, `state_node.py`,
`optical_node.py`, `rfid_node.py`, `arm_node.py`, `shelf_lib.py`,
`track_lib.py`, all `.msg` files — stays exactly as it is.

---

## Step 1 — Replace `turn_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/turn_node.py
```

Select all (Ctrl+K repeatedly, or in most editors Ctrl+A then delete), then
paste the entire file below:

```python
#!/usr/bin/env python3
"""
turn_node.py  —  Exact 90° junction turn using IMU yaw.

APPROACH (same as pivot_node, which already works):
  - On 'left'  command: rotate +π/2 radians (counter-clockwise in ROS)
  - On 'right' command: rotate -π/2 radians (clockwise)
  - Exit when |yaw_error| < TOLERANCE
  - No forward motion during turn (pure in-place rotation)
  - No sensor watching during turn

PUBLISHES to /agv/turn_vel  (NOT /agv/cmd_vel).
state_node arbitrates and forwards to /agv/cmd_vel while turning=True.
"""
import math
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from std_msgs.msg import String, Bool
from geometry_msgs.msg import Twist


# ── Tuning constants ──────────────────────────────────────────────────────
TURN_SPEED  = 0.50    # rad/s  (slow enough for accuracy)
TOLERANCE   = 0.05    # rad    (~3 degrees) — stop when within this of target
TURN_ANGLE  = math.pi / 2.0   # 90 degrees exactly
# ─────────────────────────────────────────────────────────────────────────


def yaw_from_quat(q):
    """Extract yaw (Z-rotation) from a quaternion."""
    s = 2.0 * (q.w * q.z + q.x * q.y)
    c = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(s, c)


def angle_diff(target, current):
    """Signed shortest-path difference: target - current, wrapped to [-π, π]."""
    d = target - current
    while d >  math.pi: d -= 2.0 * math.pi
    while d < -math.pi: d += 2.0 * math.pi
    return d


class TurnNode(Node):
    def __init__(self):
        super().__init__('turn_node')

        self.current_yaw = 0.0
        self.target_yaw  = None
        self.turning     = False
        self.direction   = 0        # +1 = left (CCW),  -1 = right (CW)

        # Subscribers
        self.create_subscription(Odometry, '/agv/odom',      self.odom_cb, 50)
        self.create_subscription(String,   '/agv/turn_cmd',  self.cmd_cb,  10)

        # Publishers
        self.vel_pub  = self.create_publisher(Twist, '/agv/turn_vel',  10)
        self.done_pub = self.create_publisher(Bool,  '/agv/turn_done', 10)

        # 50 Hz control loop
        self.create_timer(0.02, self.tick)

        self.get_logger().info(
            f'turn_node ready  '
            f'speed={TURN_SPEED} rad/s  tol={math.degrees(TOLERANCE):.1f}°  '
            f'→ /agv/turn_vel'
        )

    # ── Odometry callback — keeps current yaw up to date ─────────────────
    def odom_cb(self, msg):
        self.current_yaw = yaw_from_quat(msg.pose.pose.orientation)

    # ── Command callback — arms a new 90° turn ────────────────────────────
    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if   d == 'left':  self.direction = +1   # +π/2
        elif d == 'right': self.direction = -1   # -π/2
        else:
            self.get_logger().warn(f'turn_node: unknown command "{msg.data}"')
            return

        # Lock in the target yaw RIGHT NOW based on current reading
        self.target_yaw = self.current_yaw + self.direction * TURN_ANGLE
        # Wrap to [-π, π]
        while self.target_yaw >  math.pi: self.target_yaw -= 2.0 * math.pi
        while self.target_yaw < -math.pi: self.target_yaw += 2.0 * math.pi

        self.turning = True
        self.get_logger().info(
            f'turn START: {d.upper()}  '
            f'from {math.degrees(self.current_yaw):.1f}°  '
            f'to   {math.degrees(self.target_yaw):.1f}°'
        )

    # ── 50 Hz control loop ────────────────────────────────────────────────
    def tick(self):
        if not self.turning or self.target_yaw is None:
            # Not turning — publish zero so arbiter always has a value to read
            self.vel_pub.publish(Twist())
            return

        err = angle_diff(self.target_yaw, self.current_yaw)

        # ── Done? ─────────────────────────────────────────────────────────
        if abs(err) < TOLERANCE:
            self.vel_pub.publish(Twist())   # stop
            self.turning    = False
            self.target_yaw = None
            done = Bool(); done.data = True
            self.done_pub.publish(done)
            self.get_logger().info(
                f'turn DONE  final_yaw={math.degrees(self.current_yaw):.1f}°'
            )
            return

        # ── Still turning — publish angular velocity only ─────────────────
        # linear.x = 0 intentionally: pure in-place rotation
        # This keeps the AGV centred over the junction cross-point
        t = Twist()
        t.linear.x  = 0.0
        t.angular.z = TURN_SPEED * (1.0 if err > 0 else -1.0)
        self.vel_pub.publish(t)


def main(args=None):
    rclpy.init(args=args)
    node = TurnNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.vel_pub.publish(Twist())
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## Step 2 — Rebuild (only agv_brain, fast)

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Because `--symlink-install` was used originally, Python files are symlinked.
If the file was already symlinked, you may not even need to rebuild — just
saving the file is enough. But rebuild anyway to be safe.

Expected output:
```
Summary: 1 package finished [<5s]
```

---

## Step 3 — Kill everything and relaunch clean

```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3
```

Then in 3 terminals (each sourced):

**Terminal 1:**
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```
Wait until Gazebo is fully loaded (you see the warehouse and AGV).

**Terminal 2:**
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```
You should see `turn_node ready  speed=0.50 rad/s  tol=2.9°` in the output.
AGV must be sitting still (not moving).

**Terminal 3:**
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```
S05 is in aisle 2 — the AGV will cross 1 junction, then turn at the 2nd.

---

## Step 4 — Watch the logs (what good looks like)

In Terminal 2 you should see this sequence:

```
[state_node]  STATE: IDLE -> GOING
[follow_node] [....##....] off=+0.00 ang=-0.00 lin=0.50   ← driving straight
[state_node]  junction #1  (target aisle 2)               ← passed aisle 1
[state_node]  junction #2  (target aisle 2)               ← AT aisle 2
[state_node]  turn requested: left
[turn_node]   turn START: LEFT  from 0.0°  to 90.0°       ← locking target yaw
[turn_node]   turn DONE  final_yaw=90.1°                  ← exact 90° achieved
[state_node]  turn complete — resuming line following
[follow_node] [....##....] off=+0.00 ang=-0.00 lin=0.50   ← now on spur, going north
[rfid_node]   [TAG] S05 (dist=0.22m)
[state_node]  TARGET REACHED: S05
[state_node]  STATE: GOING -> AT_SHELF -> WAITING
[arm_node]    arm task done
[state_node]  STATE: WAITING -> PIVOTING
[pivot_node]  pivot start: 180 deg
[pivot_node]  pivot done
[state_node]  STATE: PIVOTING -> RETURNING
[follow_node] [....##....] lin=0.50                       ← going south on spur
[state_node]  return junction — turning onto main aisle
[turn_node]   turn START: RIGHT  from 90.0°  to 0.0°
[turn_node]   turn DONE  final_yaw=0.1°
[follow_node] [....##....] lin=0.50                       ← heading west on main
[rfid_node]   [HOME] HOME (dist=0.19m)
[state_node]  HOME reached — mission complete
[state_node]  STATE: RETURNING -> IDLE
```

---

## Step 5 — If the AGV misses the spur line after turning

The turn now ends exactly at 90°. The AGV is facing directly up the spur.
But the spur line might be slightly to the left or right of the AGV centre
(the AGV didn't drive forward during the turn so it's still at the junction).

The **line follower handles this automatically** — it starts running again
immediately after `turn_done` fires. Even if the spur is 2-3 cm off-centre,
the PID will correct within 0.5 seconds.

If the AGV consistently misses (spur always to the left or right after turn):
- This means the junction point is not directly under the spur line centre
- Fix: add a small forward nudge before the turn by bumping `SPUR_ENTRY_NUDGE`

Add this at the top of `turn_node.py` (after the constants):
```python
SPUR_ENTRY_NUDGE = 0.05   # metres to drive forward before turning
                           # set to 0.0 to disable
```

Then in `cmd_cb`, after setting `self.target_yaw`, add:
```python
self.nudge_remaining = SPUR_ENTRY_NUDGE
```

And in `tick`, add a nudge phase before the rotation. But only do this if
you consistently need it — most setups work fine without it.

---

## Why This Is Now Reliable

| Old behaviour | New behaviour |
|---|---|
| Sensor-based exit: needed 3 frames of 1-4 black | Yaw-based exit: stops at exactly ±90° |
| 5 cm spur swept past in 0.08s (< 3 frames) | No sensors watched during turn |
| Forward motion during turn moved AGV off centre | Pure in-place rotation (linear.x = 0) |
| 6s timeout → 206° overshoot | Max possible error: < 3° (tolerance) |
| Randomly wrong heading after timeout | Always correct heading after exit |
| Same approach as pivot (180°) which worked | Identical approach — known-good |

---

## Quick debug commands

```bash
# Watch the turn happen in real time
ros2 topic echo /agv/turn_vel

# See the yaw update as AGV rotates
ros2 topic echo /agv/odom --field pose.pose.orientation

# Confirm only 1 publisher on cmd_vel
ros2 topic info /agv/cmd_vel --verbose
```

The turn_vel topic should show:
- Before turn command: `linear.x: 0.0, angular.z: 0.0`
- During turn: `linear.x: 0.0, angular.z: ±0.5`
- After turn done: `linear.x: 0.0, angular.z: 0.0`
