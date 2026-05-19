# 🔥 HOTFIX — Stage 4 Bugs

> Two bugs you hit:
> 1. AGV starts moving immediately when you launch brain (should wait for order)
> 2. AGV stops diagonally at junctions and gets stuck

This document gives you 4 surgical fixes. Total time: ~10 minutes.

---

## 🐛 Bug 1 Explanation

`follow_node.py` reads `enabled: true` from the YAML and starts driving immediately. `state_node` tries to disable it but loses a race condition.

**Fix:** Make `follow_node` start with `enabled: false` by default. Only the state machine can turn it on.

## 🐛 Bug 2 Explanation

When the AGV reaches a junction:
1. `follow_node` is still publishing weird PID corrections (because 5+ sensors black is a confusing input)
2. `turn_node` simultaneously starts publishing turn commands
3. Both fight for control of `/agv/cmd_vel` — chaos ensues
4. AGV ends up in a weird diagonal pose

**Fix:**
- Higher junction threshold (6 sensors, not 5) — more reliable signal
- Add debounce (2 frames in a row before firing)
- `follow_node` publishes ONE stop command when disabled, before silencing
- `state_node` sends a brief stop before triggering turn

---

# 🔧 The 4 Fixes

## Fix #1 — Update `follow_params.yaml`

```bash
nano ~/agv_ws/src/agv_brain/config/follow_params.yaml
```

**Replace the entire file** with:

```yaml
follow_node:
  ros__parameters:
    linear_speed: 0.50
    kp: 0.50
    ki: 0.00
    kd: 0.15
    enabled: false   # ← CHANGED: starts DISABLED, state_node enables it
```

The only change is `enabled: false` instead of `enabled: true`.

---

## Fix #2 — Update `follow_node.py` (junction debounce)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/follow_node.py
```

Replace the **entire file** with this fixed version:

```python
#!/usr/bin/env python3
"""
follow_node.py - PID line follower with proper junction debouncing.
"""
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
        self.declare_parameter('enabled', False)  # ← default DISABLED

        self.linear_speed = self.get_parameter('linear_speed').value
        self.kp = self.get_parameter('kp').value
        self.ki = self.get_parameter('ki').value
        self.kd = self.get_parameter('kd').value
        self.enabled = self.get_parameter('enabled').value

        self.prev_err = 0.0
        self.integral = 0.0
        self.last_offset = 0.0
        self.lost_count = 0
        self.MAX_LOST = 25

        # Junction debouncing
        self.JUNCTION_THRESHOLD = 6   # was 5, now 6 (more reliable)
        self.junction_streak = 0
        self.JUNCTION_STREAK_NEEDED = 2  # need 2 consecutive frames to fire
        self.junction_just_fired = False

        self.create_subscription(Float32MultiArray, '/agv/line_sensors',
                                 self.sensors_cb, 10)
        self.create_subscription(Bool, '/agv/follow_enable', self.enable_cb, 10)

        self.cmd_pub = self.create_publisher(Twist, '/agv/cmd_vel', 10)
        self.junction_pub = self.create_publisher(Bool, '/agv/junction_detected', 10)

        self.frame_count = 0

        # CRITICAL: Publish a stop command immediately so AGV doesn't drift
        self.cmd_pub.publish(Twist())

        self.get_logger().info(
            f'follow_node ready (enabled={self.enabled}) '
            f'speed={self.linear_speed} kp={self.kp} kd={self.kd}'
        )

    def enable_cb(self, msg):
        was_enabled = self.enabled
        self.enabled = msg.data

        if not self.enabled:
            # CRITICAL: Publish stop multiple times to ensure it sticks
            stop = Twist()
            for _ in range(3):
                self.cmd_pub.publish(stop)
            self.prev_err = 0.0
            self.integral = 0.0
            self.lost_count = 0
            self.junction_streak = 0

        if was_enabled != self.enabled:
            self.get_logger().info(
                f'follow_node {"ENABLED" if self.enabled else "DISABLED"}'
            )

    def sensors_cb(self, msg):
        if len(msg.data) < 8:
            return

        binary = np.array(msg.data, dtype=np.float32)
        black = int(binary.sum())

        # ----- Junction detection (with debounce) -----
        if black >= self.JUNCTION_THRESHOLD:
            self.junction_streak += 1
            if (self.junction_streak >= self.JUNCTION_STREAK_NEEDED
                    and not self.junction_just_fired):
                j = Bool(); j.data = True
                self.junction_pub.publish(j)
                self.junction_just_fired = True
        else:
            self.junction_streak = 0
            self.junction_just_fired = False

        # ----- If disabled, just don't publish cmd_vel -----
        if not self.enabled:
            return

        # ----- If we're on a junction (lots of black), drive STRAIGHT -----
        # Don't try to PID on confusing junction data
        if black >= self.JUNCTION_THRESHOLD:
            t = Twist()
            t.linear.x = self.linear_speed
            t.angular.z = 0.0
            self.cmd_pub.publish(t)
            return

        # ----- Normal PID control -----
        offset, detected = self.compute_offset(binary)

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

        self.frame_count += 1
        if self.frame_count % 100 == 0:
            s = ''.join('#' if b > 0.5 else '.' for b in binary)
            self.get_logger().info(
                f'[{s}]  off={offset:+.2f}  ang={ang:+.2f}  lin={lin:.2f}  bk={black}'
            )

    def compute_offset(self, binary):
        if binary.sum() == 0:
            return 0.0, False
        idx = np.arange(len(binary))
        com = float((idx * binary).sum() / binary.sum())
        center = (len(binary) - 1) / 2.0
        offset = (com - center) / center
        return offset, True

    def pid(self, error):
        self.integral += error
        self.integral = max(min(self.integral, 2.0), -2.0)
        deriv = error - self.prev_err
        out = (self.kp * error) + (self.ki * self.integral) + (self.kd * deriv)
        self.prev_err = error
        out = max(min(out, 1.5), -1.5)
        return -out


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

## Fix #3 — Update `state_node.py` (briefly stop before turning)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Find this method:

```python
    def do_turn(self, direction):
        self.turning = True
        m = String(); m.data = direction
        self.turn_pub.publish(m)
```

**Replace** with:

```python
    def do_turn(self, direction):
        self.turning = True
        # CRITICAL: Stop the AGV briefly before turn_node takes over.
        # Otherwise follow_node and turn_node fight for control.
        self.set_follow(False)
        self.stop()
        # Small delay (in ROS we just send the cmd, turn_node will read it)
        m = String(); m.data = direction
        self.turn_pub.publish(m)
        self.get_logger().info(f'turn requested: {direction}')
```

The change: we now call `self.set_follow(False)` and `self.stop()` BEFORE telling `turn_node` to start.

---

## Fix #4 — Update `turn_node.py` (give time to settle)

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/turn_node.py
```

Find this in `cmd_cb`:

```python
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
```

**Replace** with:

```python
    def cmd_cb(self, msg):
        d = msg.data.lower().strip()
        if d == 'left':    direction = +1
        elif d == 'right': direction = -1
        else:
            self.get_logger().warn(f'unknown turn cmd: {msg.data}')
            return

        self.get_logger().info(f'turn START: {d.upper()}')

        # Make sure line follower is disabled (state_node may have already done this)
        e = Bool(); e.data = False
        self.enable_pub.publish(e)

        # Brief stop to let any pending commands clear
        for _ in range(3):
            self.cmd_pub.publish(Twist())

        self.turning = True
        self.direction = direction
        self.start_time = self.get_clock().now()
        self.line_count = 0
        self.warmup_done = False  # ← NEW: short delay before turning starts
```

Then find this in `tick`:

```python
    def tick(self):
        if not self.turning:
            return

        elapsed = (self.get_clock().now() - self.start_time).nanoseconds / 1e9

        # Safety timeout
        if elapsed > self.timeout:
```

**Replace** the entire `tick` method with:

```python
    def tick(self):
        if not self.turning:
            return

        elapsed = (self.get_clock().now() - self.start_time).nanoseconds / 1e9

        # WARMUP: First 0.3 seconds, just stop completely (let prior commands clear)
        if not self.warmup_done:
            if elapsed < 0.3:
                self.cmd_pub.publish(Twist())
                return
            self.warmup_done = True
            self.start_time = self.get_clock().now()  # reset timer for actual turn
            elapsed = 0.0

        # Safety timeout (now measures from end of warmup)
        if elapsed > self.timeout:
            self.get_logger().warn('turn TIMEOUT')
            self.finish()
            return

        # After 0.5s of turning, watch for line reacquire
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
```

The change: we added a 0.3-second "warmup" where the AGV sits still before the turn begins. This lets any leftover commands from `follow_node` clear out.

---

# 🔨 Apply The Fixes

```bash
# Rebuild
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

---

# 🧪 Test It

### Step 1: Make sure nothing is running
```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 2
```

### Step 2: Launch in 3 fresh terminals
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

✅ **Test 1 — AGV should NOT move yet.** It should sit still at HOME. If it moves, check Terminal 2 logs — `follow_node` should print `enabled=False` and `state_node` should print `state=IDLE`.

### Step 3: Send an order

**Terminal 3:**
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

Why S05? Because it's in **aisle 2**, so the AGV will need to:
1. Drive on main aisle
2. Cross junction #1 (count = 1, not target)
3. Cross junction #2 (count = 2 = target → TURN LEFT)
4. Find the spur, drive north
5. Reach S05's RFID tag
6. Pivot 180°
7. Return

✅ **Test 2 — Watch Terminal 2 carefully.** You should see this sequence:

```
[state_node] STATE: IDLE -> GOING
[follow_node] follow_node ENABLED
[follow_node] [...##....]  off=+0.00  ang=+0.00  lin=0.50  bk=2  ← driving on main aisle
...
[state_node] junction #1 (target aisle 2)
[state_node] junction #2 (target aisle 2)
[state_node] turn requested: left
[follow_node] follow_node DISABLED
[turn_node] turn START: LEFT
... (0.3s warmup) ...
[turn_node] turn done @ 1.4s
[follow_node] follow_node ENABLED
[follow_node] [...##....]  ← now on spur 2
...
[rfid_node] [TAG] S05 (dist=0.20m)
[state_node] TARGET REACHED: S05
[state_node] STATE: GOING -> AT_SHELF
[state_node] STATE: AT_SHELF -> WAITING
[arm_node] arm task starting...
[arm_node] arm task done
[state_node] STATE: WAITING -> PIVOTING
[pivot_node] pivot start: 180deg
[pivot_node] pivot done
[state_node] STATE: PIVOTING -> RETURNING
[follow_node] follow_node ENABLED
... (drives south) ...
[state_node] hit main aisle on return
[state_node] turn requested: right
[turn_node] turn START: RIGHT
[turn_node] turn done @ 1.5s
... (drives west) ...
[rfid_node] [HOME] HOME (dist=0.18m)
[state_node] HOME reached - mission complete
[state_node] STATE: RETURNING -> IDLE
```

If you see all 18 events, **it's fixed.** 🎉

---

# 🆘 If Test 1 Fails (AGV still moves on launch)

Run this and tell me what you see:
```bash
ros2 param get /follow_node enabled
```

Should print `Boolean value is: False`. If it prints `True`, the YAML didn't load. Make sure you saved the YAML file with `enabled: false` and rebuilt.

Also check:
```bash
ros2 topic info /agv/cmd_vel --verbose
```

There should only be ONE publisher (`follow_node`). If there are multiple, kill all processes and restart.

---

# 🆘 If Test 2 Fails (still gets stuck at junction)

The most likely issue is the AGV doesn't see enough black sensors. Run while it's mid-mission:

```bash
ros2 topic echo /agv/line_sensors
```

When it crosses a junction, you should see arrays like:
```
[1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]  ← all 8 black
```

If you only see 4-5 black, the AGV is misaligned. Possible causes:
- The IR sensors in the URDF aren't far enough forward (Stage 2 places them at `x=0.10`)
- The line tape is too narrow (`LINE_WIDTH = 0.05` in `build_world.py`)

Quick fix: increase `LINE_WIDTH` to `0.08` (8 cm) in `build_world.py`, regenerate the world, and rebuild.

```bash
# Edit build_world.py, change LINE_WIDTH = 0.08
python3 ~/agv_ws/src/agv_world/scripts/build_world.py
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_world
source install/setup.bash
```

But also update `track_lib.py` to match:
```python
LINE_WIDTH = 0.08
```
And rebuild `agv_brain` too.

---

# 📊 Why These Fixes Work

| Bug | Old behavior | New behavior |
|---|---|---|
| Auto-start | YAML had `enabled: true`; race condition | YAML has `enabled: false`; only state_node turns it on |
| Junction confusion | PID computed weird offset on 5+ black | When 5+ black, drive straight (don't PID) |
| Junction false positive | Single frame of 5 black = trigger | Need 6+ black for 2 consecutive frames |
| Multiple publishers | follow + turn fighting | state_node disables follow + stops AGV BEFORE turn starts |
| No settling time | turn started instantly | 0.3s warmup gives commands time to clear |

---

You should now have a solid, reliable system. Apply the fixes and try it. 🛠️
