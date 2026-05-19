# 🔧 How to Apply These Fixes

These 3 files fix the "AGV too slow" and "AGV never turns" bugs.

---

## Step 1: Replace `line_follower_node.py`

```bash
cp ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py \
   ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py.BROKEN

cp FIXES/line_follower_node_FIXED.py \
   ~/warehouse_agv_sim/src/agv_control/agv_control/line_follower_node.py
```

## Step 2: Replace `junction_handler_node.py`

```bash
cp ~/warehouse_agv_sim/src/agv_control/agv_control/junction_handler_node.py \
   ~/warehouse_agv_sim/src/agv_control/agv_control/junction_handler_node.py.BROKEN

cp FIXES/junction_handler_node_FIXED.py \
   ~/warehouse_agv_sim/src/agv_control/agv_control/junction_handler_node.py
```

## Step 3: Replace `line_follower_params.yaml`

```bash
cp ~/warehouse_agv_sim/src/agv_control/config/line_follower_params.yaml \
   ~/warehouse_agv_sim/src/agv_control/config/line_follower_params.yaml.BROKEN

cp FIXES/line_follower_params_FIXED.yaml \
   ~/warehouse_agv_sim/src/agv_control/config/line_follower_params.yaml
```

## Step 4: Rebuild

```bash
cd ~/warehouse_agv_sim
colcon build --symlink-install --packages-select agv_control
source install/setup.bash
```

## Step 5: Test

```bash
# Terminal 1: World + AGV
ros2 launch agv_description spawn_agv.launch.py

# Terminal 2: Brain
ros2 launch agv_control agv_brain.launch.py

# Terminal 3: Send order
ros2 run agv_control send_order S07
```

### What you should see:

1. AGV starts moving at a NOTICEABLE speed (not crawling)
2. Line follower logs show: `[□□□■■□□□] offset=+0.000 ang_z=-0.000 lin_x=0.50`
3. When AGV reaches the S07 spur X-coordinate, junction handler logs:
   `🧭 ✅ JUNCTION TRIGGERED for S07!`
4. AGV turns left, junction handler logs:
   `🧭 ✅ Spur line reacquired after 1.3s! Turn complete.`
5. Line follower resumes on the spur

---

## If It Still Doesn't Turn — Debug Checklist

### Check 1: What does `shelf_map.py` think S07's aisle_x is?

```bash
python3 -c "from agv_control.shelf_map import SHELF_MAP; print(SHELF_MAP.get('S07', {}).get('aisle_x'))"
```

This should print a number (e.g., `3.0` or `6.0`). 

### Check 2: What is the AGV's actual X position when it passes that point?

```bash
ros2 topic echo /agv/odom --field pose.pose.position.x
```

Watch the X value as the AGV drives along the main aisle. It should increase from ~-2.0 toward +12.0.

### Check 3: Do these two match?

If `shelf_map.py` says S07 is at `aisle_x = 3.0`, but the AGV's X coordinate passes through `3.0` without the junction firing → check the junction handler logs. It should be printing debug info.

### Check 4: Is AGVState being published?

```bash
ros2 topic echo /agv/state
```

You should see:
```
state: 'GOING'
current_target: 'S07'
last_rfid: ''
```

If `current_target` is empty, the state machine isn't publishing it correctly.

---

## If It's Still Too Slow — Fine-Tuning

| What You See | Fix |
|---|---|
| AGV wobbles side-to-side but moves forward | Increase `kd` to 0.25 |
| AGV veers off the line sometimes | Decrease `linear_speed` to 0.40 |
| AGV seems smooth but too slow | Increase `linear_speed` to 0.70 |
| AGV oscillates wildly | Decrease `kp` to 0.30 |
| AGV is smooth and fast | Perfect! Don't change anything. |

Live tuning (no rebuild needed):
```bash
ros2 param set /line_follower_node linear_speed 0.60
ros2 param set /line_follower_node kp 0.40
ros2 param set /line_follower_node kd 0.20
```
