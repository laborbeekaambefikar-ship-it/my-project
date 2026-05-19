# 🔥 HOTFIX — AGV Loses Line While Returning

## What You See
AGV completes the outbound trip, reaches shelf, pivots 180°. Then while
driving back south on the spur it drifts off the line and stops.

## Exact Root Cause

After the 180° pivot, the AGV is facing south but its **wheel position
has not changed** — only its heading rotated. The robot stopped wherever
the RFID detected the shelf (~0.48m from the tag). That stopping point
may be 2–4 cm off the spur line centre.

When `RETURNING` starts, `follow_node` takes over. It reads the sensors:
maybe 1–2 sensors see the line (AGV is slightly off-centre). The PID
tries to correct, but:

- The PID correction takes 0.5–1 second to steer back on-centre
- `MAX_LOST = 25` frames × 0.02s = **only 0.5 seconds grace period**

The grace period expires before the PID correction completes.
`follow_node` hits "Line lost — stopping." and the AGV freezes on the spur.

**Three compounding factors:**
1. `SPUR LINE_WIDTH = 0.05m` (5 cm) is very narrow — easy to be off it
2. `MAX_LOST = 25` (0.5s) is too short for recovery after a pivot
3. No forward nudge after pivot — AGV starts following from wherever it stopped

## Fixes (Only 2 Files Change)

### Fix A: `follow_node.py` — increase MAX_LOST and LINE_WIDTH
### Fix B: `track_lib.py` — wider virtual tape

---

## Step 1 — Edit `follow_node.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/follow_node.py
```

Find this line:
```python
self.MAX_LOST    = 25  # 0.5 s grace at 50 Hz
```

Change it to:
```python
self.MAX_LOST    = 80  # 1.6 s grace at 50 Hz  ← was 25 (0.5s), now 80 (1.6s)
```

That is literally the **only change** in this file. One number.

Save and exit.

---

## Step 2 — Edit `track_lib.py`

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/track_lib.py
```

Find this line:
```python
LINE_WIDTH = 0.05    # 5 cm wide tape
```

Change it to:
```python
LINE_WIDTH = 0.10    # 10 cm wide virtual detection zone
                     # (actual tape is still 5 cm in Gazebo world;
                     #  this widens the SENSOR DETECTION ZONE so the
                     #  AGV can recover from being a few cm off-centre)
```

Save and exit.

---

## Step 3 — Edit `state_node.py` — add post-pivot nudge

After the 180° pivot, the AGV needs to drive forward a few centimetres
to position itself cleanly on the spur before the line follower takes over.
Right now `pivot_done_cb` immediately sets state to RETURNING and enables
the line follower. We add a short timer between them.

```bash
nano ~/agv_ws/src/agv_brain/agv_brain/state_node.py
```

Find `pivot_done_cb`:

```python
    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        self.get_logger().info('pivot done — starting return')
        self.junction_count = 0
        self.set_state(RETURNING)
```

Replace with:

```python
    def pivot_done_cb(self, msg):
        if not msg.data or self.state != PIVOTING:
            return
        self.get_logger().info('pivot done — nudging onto spur before return')
        self.junction_count = 0
        # Drive forward 15 cm at 0.20 m/s = 0.75s before starting line follower.
        # This ensures the AGV is clearly on the spur centreline.
        self._pivot_nudge_remaining = 0.75  # seconds
        self._pivot_nudge_start = self.get_clock().now()
        self.set_state(RETURNING)
        # Start a timer that enables follow_node after the nudge
        self._pivot_nudge_timer = self.create_timer(0.02, self._pivot_nudge_tick)

    def _pivot_nudge_tick(self):
        elapsed = (self.get_clock().now() - self._pivot_nudge_start).nanoseconds / 1e9
        if elapsed < self._pivot_nudge_remaining:
            # Publish nudge directly to follow_vel style
            # Actually: use cmd_pub directly here since we're in state_node (the arbiter)
            t = Twist()
            t.linear.x = 0.20
            self.cmd_pub.publish(t)
        else:
            self._pivot_nudge_timer.cancel()
            self._pivot_nudge_timer = None
            self.get_logger().info('pivot nudge done — line follower active')
            # Line follower will take over via arbiter naturally
            # (state=RETURNING, arbiter forwards follow_vel)
```

Also add these two initializations in `__init__` (anywhere after the other `self.` assignments):

```python
        self._pivot_nudge_timer     = None
        self._pivot_nudge_start     = None
        self._pivot_nudge_remaining = 0.0
```

Save and exit.

---

## Step 4 — Rebuild

Because `--symlink-install` was used, Python changes in `follow_node.py`
and `track_lib.py` are already live (no rebuild needed for those two).

But `state_node.py` was changed, and we need the symlinks to be correct.
Do a quick selective rebuild to be safe:

```bash
cd ~/agv_ws
colcon build --symlink-install --packages-select agv_brain
source install/setup.bash
```

Expected: `Summary: 1 package finished`.

---

## Step 5 — Test

```bash
pkill -9 -f ros2; pkill -9 -f gz; pkill -9 -f rviz; sleep 3
```

Terminal 1:
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_robot spawn.launch.py
```

Terminal 2:
```bash
source ~/agv_ws/install/setup.bash
ros2 launch agv_brain brain.launch.py
```

Terminal 3:
```bash
source ~/agv_ws/install/setup.bash
ros2 run agv_brain send S05
```

### What you should see in Terminal 2

```
STATE: IDLE -> GOING
[....##....] lin=0.50                     ← going east on main aisle
junction #1  (target aisle 2)
junction #2  (target aisle 2)
turn requested: left
turn START: LEFT  0.0° → 90.0°
rotation done — nudging forward 0.60s
turn + nudge DONE
turn complete — junctions blocked 2.5s
[....##....] lin=0.50                     ← going north on spur
[TAG] DETECTED S05  dist=0.52m
TARGET REACHED: S05
STATE: GOING -> AT_SHELF -> WAITING
arm task done
STATE: WAITING -> PIVOTING
pivot done — nudging onto spur before return   ← NEW
pivot nudge done — line follower active        ← NEW
STATE: PIVOTING -> RETURNING
[....##....] lin=0.50                     ← going south on spur ✓ NO LINE LOST
return junction — turning onto main aisle
turn START: RIGHT  270.0° → 180.0°
rotation done — nudging 0.60s
turn + nudge DONE
turn complete — junctions blocked 2.5s
[....##....] lin=0.50                     ← going west on main aisle
[HOME] DETECTED HOME  dist=0.22m
HOME reached — mission complete
STATE: RETURNING -> IDLE
```

---

## Why This Fixes It

| Problem | Root cause | Fix |
|---|---|---|
| Line lost on return spur | AGV slightly off-centre after pivot, 0.5s grace too short | `MAX_LOST` 25 → 80 (1.6s grace) |
| Hard to reacquire narrow spur | `LINE_WIDTH = 0.05` too narrow for 8.4cm sensor array | `LINE_WIDTH` 0.05 → 0.10 (virtual detection zone) |
| AGV starts from bad position after pivot | No forward nudge after pivot | 0.75s nudge at 0.20 m/s = 15 cm forward before line follower |

### Why increasing LINE_WIDTH is safe
`LINE_WIDTH` in `track_lib.py` is only used by `optical_node.py` to decide
"is this sensor position on a line?" It is NOT the physical tape width in
Gazebo — that is still 5 cm. Making the virtual detection zone 10 cm simply
means the sensors can be 5 cm off the tape centre and still detect it.
This helps the PID get a useful reading even when the AGV is slightly
off-centre, rather than seeing nothing and hitting line-lost.

### Why 1.6s grace period is better
0.5s was tuned for a perfectly-centred AGV that never loses the line.
In practice, the pivot leaves the AGV slightly off-centre. The PID needs
up to 1 second to steer back. 1.6s (80 frames) gives full recovery time
while still being short enough to stop if the AGV genuinely leaves the track.

### Why the pivot nudge helps
The 180° pivot rotates in place — it does NOT move the AGV forward.
So the AGV starts heading south from wherever it stopped. If that is 3 cm
to the right of the spur, it will spend ~0.8s correcting. With the nudge,
the AGV drives 15 cm south first (while still roughly aligned with the spur
from the RFID stop), which gives the PID a running start with the line
already under the sensors.

---

## If It Still Loses the Line

If `LINE_WIDTH = 0.10` is not enough, increase it further:
```python
LINE_WIDTH = 0.15    # 15 cm virtual zone
```

If the return-junction turn is now firing at the wrong place (the wider
line means the `on_line()` function detects the main aisle while still
on the spur near Y=0), you may need to slightly shorten the spur:
```python
SPUR_Y_START = 0.1   # start spur detection 10cm above the main aisle
```
This avoids the sensor detecting the main aisle before the AGV has actually
crossed over to it. But only do this if you see the return junction firing
too early.

---

## Quick Debug: Watch Sensor Output During Return

While the AGV is heading south on the return spur:

```bash
ros2 topic echo /agv/line_sensors
```

You should see something like:
```
data: [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]   ← 2 centre sensors = good
data: [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0]   ← slight left drift
data: [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]   ← PID corrected
```

If you see all zeros for more than 2 seconds, the AGV is off the spur.
Increase `LINE_WIDTH` further.
