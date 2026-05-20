#!/usr/bin/env python3
"""
=============================================================================
  WAREHOUSE AGV SIMULATION - Complete Single-File Implementation
=============================================================================
  A full 2D top-down animated simulation of an Autonomous Guided Vehicle (AGV)
  navigating a medium-scale warehouse using:
    - Line following with 8-pixel sensor + PID controller
    - RFID-based shelf identification (pose proximity)
    - Tree-topology track (main aisle + 5 dead-end spurs)
    - Junction handling for spur entry/exit
    - 180-degree pivot-and-retrace return strategy
    - Full state machine: IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING -> RETURNING
    - Tkinter GUI with order entry, live dashboard, mission log, and order queue

  Requirements: Python 3.8+ with tkinter (standard library only)
  Usage: python3 agv_warehouse_sim.py
=============================================================================
  B.Tech Project: Autonomous Guided Vehicle for Medium-Scale Warehouses
=============================================================================
"""

import math
import time
import tkinter as tk
from tkinter import ttk, scrolledtext
from datetime import datetime
from collections import deque

# =============================================================================
# CONFIGURATION
# =============================================================================


# --- Warehouse Layout ---
ROWS = 4                # shelves per aisle (spur)
COLS = 5                # number of aisles (spurs)
AISLE_SPACING = 3.0     # meters between aisle centers (X direction)
SHELF_SPACING = 2.0     # meters between shelves along a spur (Y direction)
HOME_X = -2.0           # HOME zone X position
HOME_Y = 0.0            # HOME zone Y position
MAIN_AISLE_Y = 0.0      # Y coordinate of the main horizontal aisle

# --- AGV Parameters ---
AGV_SPEED = 0.3             # m/s linear speed
AGV_TURN_SPEED = 0.8       # rad/s angular speed during pivot
PID_KP = 0.012              # PID proportional gain
PID_KI = 0.000              # PID integral gain
PID_KD = 0.004              # PID derivative gain
RFID_DETECTION_RADIUS = 0.3 # meters
RFID_REARM_DISTANCE = 0.6   # meters before tag can fire again
ARM_TASK_DURATION = 3.0     # seconds for arm stub task
PIVOT_TOLERANCE = 0.05      # radians (~3 degrees)
JUNCTION_TOLERANCE = 0.2    # meters for junction detection

# --- Simulation ---
SIM_DT = 0.033             # simulation timestep (~30 Hz)
CANVAS_SCALE = 45          # pixels per meter
CANVAS_OFFSET_X = 150      # pixel offset for centering
CANVAS_OFFSET_Y = 80       # pixel offset for centering

# --- States ---
IDLE = 'IDLE'
GOING = 'GOING'
AT_SHELF = 'AT_SHELF'
WAITING = 'WAITING'
PIVOTING = 'PIVOTING'
RETURNING = 'RETURNING'

STATE_COLORS = {
    IDLE: '#4CAF50',
    GOING: '#2196F3',
    AT_SHELF: '#FF9800',
    WAITING: '#9C27B0',
    PIVOTING: '#FF5722',
    RETURNING: '#00BCD4',
}



# =============================================================================
# SHELF MAP - builds the 4x5 grid of shelves with coordinates
# =============================================================================

def build_shelf_map():
    """Build shelf map: shelf_id -> {tag_x, tag_y, aisle, aisle_x, side, slot, row, col}"""
    shelves = {}
    shelf_id = 1
    for col in range(COLS):
        aisle_x = col * AISLE_SPACING
        for row in range(ROWS):
            # Alternate sides: even rows go left (-Y side), odd rows go right (+Y)
            slot_index = row
            shelf_y = 1.5 + slot_index * SHELF_SPACING

            # RFID tag is on the spur line at shelf_y
            tag_x = aisle_x
            tag_y = shelf_y

            shelves[f"S{shelf_id:02d}"] = {
                'tag_x': tag_x,
                'tag_y': tag_y,
                'aisle': col + 1,
                'aisle_x': float(aisle_x),
                'slot': slot_index + 1,
                'row': row + 1,
                'col': col + 1,
            }
            shelf_id += 1
    return shelves


SHELF_MAP = build_shelf_map()



# =============================================================================
# TRACK GEOMETRY - defines the line segments the AGV follows
# =============================================================================

def build_track_segments():
    """
    Build the tree-topology track:
      - One main horizontal aisle at Y=0, from X=HOME_X to X=(COLS-1)*AISLE_SPACING
      - 5 vertical spurs (one per aisle) going from Y=0 upward to the last shelf
    Returns list of (x1, y1, x2, y2) line segments.
    """
    segments = []
    # Main aisle: horizontal line at Y=0
    main_start_x = HOME_X
    main_end_x = (COLS - 1) * AISLE_SPACING + 0.5
    segments.append((main_start_x, MAIN_AISLE_Y, main_end_x, MAIN_AISLE_Y))

    # Spurs: vertical lines from main aisle going up
    for col in range(COLS):
        spur_x = col * AISLE_SPACING
        spur_start_y = MAIN_AISLE_Y
        spur_end_y = 1.5 + (ROWS - 1) * SHELF_SPACING + 0.5
        segments.append((spur_x, spur_start_y, spur_x, spur_end_y))

    return segments


TRACK_SEGMENTS = build_track_segments()



# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

def angle_diff(a, b):
    """Smallest signed difference a - b, wrapped to [-pi, pi]."""
    d = a - b
    while d > math.pi:
        d -= 2 * math.pi
    while d < -math.pi:
        d += 2 * math.pi
    return d


def normalize_angle(a):
    """Wrap angle to [-pi, pi]."""
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


def point_to_segment_distance(px, py, x1, y1, x2, y2):
    """Distance from point (px, py) to line segment (x1,y1)-(x2,y2)."""
    dx = x2 - x1
    dy = y2 - y1
    len_sq = dx * dx + dy * dy
    if len_sq < 1e-9:
        return math.hypot(px - x1, py - y1), x1, y1
    t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / len_sq))
    proj_x = x1 + t * dx
    proj_y = y1 + t * dy
    return math.hypot(px - proj_x, py - proj_y), proj_x, proj_y


def world_to_canvas(x, y):
    """Convert world coordinates to canvas pixel coordinates."""
    cx = CANVAS_OFFSET_X + x * CANVAS_SCALE
    cy = CANVAS_OFFSET_Y + (10 - y) * CANVAS_SCALE  # flip Y for display
    return cx, cy



# =============================================================================
# AGV CLASS - Physics, sensors, and actuators
# =============================================================================

class AGV:
    """The Autonomous Guided Vehicle with differential-drive kinematics."""

    def __init__(self):
        self.x = HOME_X
        self.y = HOME_Y
        self.yaw = math.pi / 2  # facing +Y (up) initially; will be set as needed
        self.linear_vel = 0.0
        self.angular_vel = 0.0

        # PID state
        self.pid_prev_error = 0.0
        self.pid_integral = 0.0

        # 8-pixel line sensor readings
        self.sensor_readings = [0] * 8
        self.line_detected = False
        self.line_offset = 0.0

    def reset_to_home(self):
        """Reset AGV to HOME position."""
        self.x = HOME_X
        self.y = HOME_Y
        self.yaw = math.pi / 2  # facing up
        self.linear_vel = 0.0
        self.angular_vel = 0.0
        self.pid_prev_error = 0.0
        self.pid_integral = 0.0

    def update_physics(self, dt):
        """Update position based on current velocities (differential drive)."""
        self.x += self.linear_vel * math.cos(self.yaw) * dt
        self.y += self.linear_vel * math.sin(self.yaw) * dt
        self.yaw = normalize_angle(self.yaw + self.angular_vel * dt)

    def read_line_sensors(self):
        """
        Simulate 8 sensors spread across a ~0.1m width perpendicular to heading.
        Each sensor checks distance to nearest track segment.
        Sensor = 1 if within 0.06m of a line, else 0.
        """
        sensor_width = 0.12  # total width of sensor array
        num_sensors = 8
        readings = []

        # Perpendicular direction to heading
        perp_x = -math.sin(self.yaw)
        perp_y = math.cos(self.yaw)

        # Forward offset (sensors are slightly ahead of center)
        fwd_offset = 0.06
        base_x = self.x + math.cos(self.yaw) * fwd_offset
        base_y = self.y + math.sin(self.yaw) * fwd_offset

        for i in range(num_sensors):
            # Position of this sensor
            offset = (i - (num_sensors - 1) / 2.0) * (sensor_width / (num_sensors - 1))
            sx = base_x + perp_x * offset
            sy = base_y + perp_y * offset

            # Check distance to nearest track segment
            min_dist = float('inf')
            for seg in TRACK_SEGMENTS:
                dist, _, _ = point_to_segment_distance(sx, sy, *seg)
                min_dist = min(min_dist, dist)

            # Sensor fires if within threshold of a line
            readings.append(1 if min_dist < 0.06 else 0)

        self.sensor_readings = readings

        # Compute line offset
        if sum(readings) == 0:
            self.line_detected = False
            self.line_offset = 0.0
        else:
            self.line_detected = True
            indices = list(range(num_sensors))
            center_of_mass = sum(i * r for i, r in zip(indices, readings)) / sum(readings)
            center_index = (num_sensors - 1) / 2.0
            self.line_offset = (center_of_mass - center_index) / center_index  # normalized [-1, 1]

    def pid_step(self, error):
        """PID controller: returns angular velocity correction."""
        self.pid_integral += error
        self.pid_integral = max(-100, min(100, self.pid_integral))  # anti-windup
        derivative = error - self.pid_prev_error
        output = PID_KP * error + PID_KI * self.pid_integral + PID_KD * derivative
        self.pid_prev_error = error
        return -output  # negative because positive error = line to right = turn right (negative angular)



# =============================================================================
# MISSION CONTROLLER - State machine + all subsystems
# =============================================================================

class MissionController:
    """
    Orchestrates the full AGV mission lifecycle:
      IDLE -> GOING -> AT_SHELF -> WAITING -> PIVOTING -> RETURNING -> IDLE

    Integrates: line follower, RFID reader, junction handler, pivot controller, arm stub.
    """

    def __init__(self, agv: AGV, log_callback=None):
        self.agv = agv
        self.log_callback = log_callback

        # State
        self.state = IDLE
        self.target_shelf = None
        self.target_aisle_x = None
        self.last_rfid = ''

        # Order queue
        self.order_queue = deque()

        # Line follower
        self.line_follow_enabled = False
        self.line_lost_count = 0
        self.MAX_LOST_FRAMES = 20

        # Junction handler
        self.junction_turn_attempted = False
        self.junction_turning = False
        self.junction_turn_start = 0.0
        self.junction_turn_direction = 0  # +1 = left (CCW), -1 = right (CW)
        self.junction_turn_duration = 1.4  # seconds

        # Pivot controller
        self.pivot_target_yaw = None
        self.pivoting = False

        # Arm stub
        self.arm_working = False
        self.arm_start_time = 0.0

        # RFID state
        self.rfid_armed = {sid: True for sid in SHELF_MAP}
        self.rfid_armed['HOME'] = True

        # Navigation waypoints for going/returning
        self.waypoints = []
        self.current_waypoint_idx = 0
        self.nav_phase = 'idle'  # 'to_aisle', 'up_spur', 'idle'

        # Timing
        self.sim_time = 0.0

    def log(self, msg):
        """Send a log message to the GUI."""
        if self.log_callback:
            self.log_callback(msg)

    def set_state(self, new_state):
        """Transition to a new state."""
        if new_state != self.state:
            self.log(f"State: {self.state} -> {new_state}")
            self.state = new_state

    def send_order(self, shelf_id, sku='SKU-0000'):
        """Accept a new order. If busy, queue it."""
        if shelf_id not in SHELF_MAP:
            self.log(f"ERROR: Unknown shelf {shelf_id}")
            return

        if self.state != IDLE:
            self.order_queue.append((shelf_id, sku))
            self.log(f"AGV busy. Queued: {shelf_id} ({sku})")
            return

        self._start_mission(shelf_id, sku)

    def _start_mission(self, shelf_id, sku):
        """Begin a mission to the specified shelf."""
        self.target_shelf = shelf_id
        shelf_data = SHELF_MAP[shelf_id]
        self.target_aisle_x = shelf_data['aisle_x']

        self.log(f"Order: {shelf_id} (aisle {shelf_data['aisle']}, slot {shelf_data['slot']}, sku={sku})")

        # Plan waypoints: HOME -> along main aisle -> turn into spur -> up to shelf
        self._plan_waypoints_going(shelf_data)

        self.set_state(GOING)
        self.line_follow_enabled = True
        self.junction_turn_attempted = False
        self.agv.pid_prev_error = 0.0
        self.agv.pid_integral = 0.0

        # Set AGV heading toward +X along main aisle
        self.agv.yaw = 0.0  # facing +X (right along main aisle)
        self.nav_phase = 'to_aisle'

    def _plan_waypoints_going(self, shelf_data):
        """Plan navigation waypoints for GOING phase."""
        self.waypoints = []
        # Waypoint 1: travel along main aisle to the target aisle X
        self.waypoints.append(('main_aisle', shelf_data['aisle_x'], MAIN_AISLE_Y))
        # Waypoint 2: travel up the spur to the shelf
        self.waypoints.append(('spur', shelf_data['tag_x'], shelf_data['tag_y']))
        self.current_waypoint_idx = 0

    def _plan_waypoints_returning(self):
        """Plan navigation waypoints for RETURNING phase."""
        self.waypoints = []
        # Waypoint 1: travel down spur back to main aisle
        self.waypoints.append(('spur_back', self.target_aisle_x, MAIN_AISLE_Y))
        # Waypoint 2: travel along main aisle back to HOME
        self.waypoints.append(('main_aisle_back', HOME_X, HOME_Y))
        self.current_waypoint_idx = 0


    def update(self, dt):
        """Main simulation tick - called every frame."""
        self.sim_time += dt

        if self.state == IDLE:
            self.agv.linear_vel = 0.0
            self.agv.angular_vel = 0.0
            return

        elif self.state == GOING:
            self._update_going(dt)

        elif self.state == AT_SHELF:
            self.agv.linear_vel = 0.0
            self.agv.angular_vel = 0.0
            # Trigger arm
            self.arm_working = True
            self.arm_start_time = self.sim_time
            self.log("Arm task started (3s)...")
            self.set_state(WAITING)

        elif self.state == WAITING:
            self.agv.linear_vel = 0.0
            self.agv.angular_vel = 0.0
            self._update_arm(dt)

        elif self.state == PIVOTING:
            self._update_pivot(dt)

        elif self.state == RETURNING:
            self._update_returning(dt)

        # Update physics
        self.agv.update_physics(dt)

    def _update_going(self, dt):
        """Navigate from HOME to target shelf using waypoint-based navigation."""
        if self.current_waypoint_idx >= len(self.waypoints):
            # Should not happen, but safety
            return

        wp_type, wp_x, wp_y = self.waypoints[self.current_waypoint_idx]
        dist_to_wp = math.hypot(self.agv.x - wp_x, self.agv.y - wp_y)

        # Check RFID at target
        if self.target_shelf:
            shelf_data = SHELF_MAP[self.target_shelf]
            dist_to_tag = math.hypot(self.agv.x - shelf_data['tag_x'],
                                     self.agv.y - shelf_data['tag_y'])
            if dist_to_tag < RFID_DETECTION_RADIUS:
                self.last_rfid = self.target_shelf
                self.log(f"RFID detected: {self.target_shelf} (dist={dist_to_tag:.2f}m)")
                self.agv.linear_vel = 0.0
                self.agv.angular_vel = 0.0
                self.set_state(AT_SHELF)
                return

        # Navigate toward current waypoint
        if dist_to_wp < JUNCTION_TOLERANCE:
            # Reached this waypoint
            self.current_waypoint_idx += 1
            if self.current_waypoint_idx < len(self.waypoints):
                # Turn toward next waypoint
                next_wp = self.waypoints[self.current_waypoint_idx]
                target_angle = math.atan2(next_wp[2] - self.agv.y, next_wp[1] - self.agv.x)
                self.agv.yaw = target_angle  # snap turn at junction
                self.log(f"Junction: turning into spur (aisle {SHELF_MAP[self.target_shelf]['aisle']})")
            return

        # Steer toward waypoint using simple pursuit
        target_angle = math.atan2(wp_y - self.agv.y, wp_x - self.agv.x)
        angle_err = angle_diff(target_angle, self.agv.yaw)

        # PID-like steering
        self.agv.angular_vel = 3.0 * angle_err  # proportional steering
        self.agv.angular_vel = max(-AGV_TURN_SPEED, min(AGV_TURN_SPEED, self.agv.angular_vel))
        self.agv.linear_vel = AGV_SPEED * max(0.3, 1.0 - abs(angle_err) / math.pi)


    def _update_arm(self, dt):
        """Arm stub: wait for ARM_TASK_DURATION seconds."""
        elapsed = self.sim_time - self.arm_start_time
        if elapsed >= ARM_TASK_DURATION:
            self.arm_working = False
            self.log("Arm task complete. Initiating pivot...")
            self._start_pivot()

    def _start_pivot(self):
        """Begin 180-degree in-place rotation."""
        self.pivot_target_yaw = normalize_angle(self.agv.yaw + math.pi)
        self.pivoting = True
        self.set_state(PIVOTING)

    def _update_pivot(self, dt):
        """Rotate in place until target yaw is reached."""
        if not self.pivoting:
            return

        err = angle_diff(self.pivot_target_yaw, self.agv.yaw)

        if abs(err) < PIVOT_TOLERANCE:
            # Pivot done
            self.agv.angular_vel = 0.0
            self.agv.linear_vel = 0.0
            self.pivoting = False
            self.log("Pivot complete (180 deg). Returning home...")
            self._start_returning()
            return

        self.agv.linear_vel = 0.0
        self.agv.angular_vel = AGV_TURN_SPEED * (1.0 if err > 0 else -1.0)

    def _start_returning(self):
        """Begin return journey."""
        self._plan_waypoints_returning()
        self.set_state(RETURNING)
        self.junction_turn_attempted = False
        self.agv.pid_prev_error = 0.0
        self.agv.pid_integral = 0.0

    def _update_returning(self, dt):
        """Navigate from shelf back to HOME using waypoints."""
        if self.current_waypoint_idx >= len(self.waypoints):
            return

        wp_type, wp_x, wp_y = self.waypoints[self.current_waypoint_idx]
        dist_to_wp = math.hypot(self.agv.x - wp_x, self.agv.y - wp_y)

        # Check if we're back at HOME
        dist_to_home = math.hypot(self.agv.x - HOME_X, self.agv.y - HOME_Y)
        if dist_to_home < RFID_DETECTION_RADIUS:
            self.last_rfid = 'HOME'
            self.log("HOME reached! Mission complete.")
            self.agv.linear_vel = 0.0
            self.agv.angular_vel = 0.0
            self.target_shelf = None
            self.set_state(IDLE)
            # Check queue
            self._check_queue()
            return

        # Navigate toward current waypoint
        if dist_to_wp < JUNCTION_TOLERANCE:
            self.current_waypoint_idx += 1
            if self.current_waypoint_idx < len(self.waypoints):
                next_wp = self.waypoints[self.current_waypoint_idx]
                target_angle = math.atan2(next_wp[2] - self.agv.y, next_wp[1] - self.agv.x)
                self.agv.yaw = target_angle
                self.log("Junction: returning to main aisle")
            return

        # Steer toward waypoint
        target_angle = math.atan2(wp_y - self.agv.y, wp_x - self.agv.x)
        angle_err = angle_diff(target_angle, self.agv.yaw)

        self.agv.angular_vel = 3.0 * angle_err
        self.agv.angular_vel = max(-AGV_TURN_SPEED, min(AGV_TURN_SPEED, self.agv.angular_vel))
        self.agv.linear_vel = AGV_SPEED * max(0.3, 1.0 - abs(angle_err) / math.pi)

    def _check_queue(self):
        """If there are queued orders, dispatch the next one."""
        if self.order_queue:
            next_shelf, next_sku = self.order_queue.popleft()
            self.log(f"Auto-dispatch from queue: {next_shelf}")
            self._start_mission(next_shelf, next_sku)



# =============================================================================
# GUI APPLICATION
# =============================================================================

class AGVSimulationApp:
    """Complete Tkinter GUI with animated warehouse canvas and control panel."""

    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Warehouse AGV Simulation - Complete Demo")
        self.root.geometry("1200x820")
        self.root.configure(bg='#1a1a2e')

        # Create AGV and controller
        self.agv = AGV()
        self.controller = MissionController(self.agv, log_callback=self._log)

        # Build the UI
        self._build_ui()

        # Start simulation loop
        self.running = True
        self.last_time = time.time()
        self._sim_loop()

    def _build_ui(self):
        """Build the complete UI layout."""
        # Main container with two columns
        main_frame = tk.Frame(self.root, bg='#1a1a2e')
        main_frame.pack(fill='both', expand=True, padx=5, pady=5)

        # LEFT: Canvas for warehouse visualization
        left_frame = tk.Frame(main_frame, bg='#1a1a2e')
        left_frame.pack(side='left', fill='both', expand=True)

        canvas_label = tk.Label(left_frame, text="WAREHOUSE TOP VIEW",
                                font=('Consolas', 12, 'bold'), bg='#1a1a2e', fg='#00ff88')
        canvas_label.pack(pady=(5, 2))

        self.canvas = tk.Canvas(left_frame, width=700, height=520,
                                bg='#0d1117', highlightthickness=1,
                                highlightbackground='#30363d')
        self.canvas.pack(padx=5, pady=5)

        # Sensor display below canvas
        sensor_frame = tk.Frame(left_frame, bg='#1a1a2e')
        sensor_frame.pack(fill='x', padx=10)

        tk.Label(sensor_frame, text="8-Pixel Line Sensors:",
                 font=('Consolas', 10), bg='#1a1a2e', fg='#888').pack(side='left')
        self.sensor_display = tk.Label(sensor_frame, text="[0 0 0 0 0 0 0 0]",
                                       font=('Consolas', 12, 'bold'), bg='#1a1a2e', fg='#00ffff')
        self.sensor_display.pack(side='left', padx=10)

        # RIGHT: Control panel
        right_frame = tk.Frame(main_frame, bg='#16213e', width=450)
        right_frame.pack(side='right', fill='y', padx=5)
        right_frame.pack_propagate(False)

        self._build_control_panel(right_frame)

    def _build_control_panel(self, parent):
        """Build the right-side control panel."""
        # --- Title ---
        tk.Label(parent, text="AGV CONTROL CENTER",
                 font=('Arial', 13, 'bold'), bg='#16213e', fg='white').pack(pady=10)

        # --- Order Panel ---
        order_frame = tk.LabelFrame(parent, text=" Send Order ",
                                    font=('Arial', 10, 'bold'),
                                    bg='#1a1a2e', fg='#4CAF50', padx=10, pady=8)
        order_frame.pack(fill='x', padx=10, pady=5)

        row1 = tk.Frame(order_frame, bg='#1a1a2e')
        row1.pack(fill='x', pady=3)

        tk.Label(row1, text='Shelf:', bg='#1a1a2e', fg='white',
                 font=('Arial', 10)).pack(side='left', padx=5)
        self.shelf_var = tk.StringVar(value='S01')
        shelf_combo = ttk.Combobox(row1, textvariable=self.shelf_var, width=6,
                                   values=sorted(SHELF_MAP.keys()), state='readonly')
        shelf_combo.pack(side='left', padx=5)

        tk.Label(row1, text='SKU:', bg='#1a1a2e', fg='white',
                 font=('Arial', 10)).pack(side='left', padx=5)
        self.sku_var = tk.StringVar(value='SKU-1042')
        tk.Entry(row1, textvariable=self.sku_var, width=12,
                 bg='#0d1117', fg='white', insertbackground='white').pack(side='left', padx=5)

        row2 = tk.Frame(order_frame, bg='#1a1a2e')
        row2.pack(fill='x', pady=5)

        send_btn = tk.Button(row2, text='SEND ORDER', command=self._on_send,
                             bg='#4CAF50', fg='white', font=('Arial', 9, 'bold'),
                             width=12, relief='raised', cursor='hand2')
        send_btn.pack(side='left', padx=5)

        queue_btn = tk.Button(row2, text='+ QUEUE', command=self._on_queue,
                              bg='#2196F3', fg='white', font=('Arial', 9, 'bold'),
                              width=10, relief='raised', cursor='hand2')
        queue_btn.pack(side='left', padx=5)

        reset_btn = tk.Button(row2, text='RESET', command=self._on_reset,
                              bg='#f44336', fg='white', font=('Arial', 9, 'bold'),
                              width=8, relief='raised', cursor='hand2')
        reset_btn.pack(side='left', padx=5)


        # --- Dashboard ---
        dash_frame = tk.LabelFrame(parent, text=" Live Dashboard ",
                                   font=('Arial', 10, 'bold'),
                                   bg='#1a1a2e', fg='#00BCD4', padx=10, pady=8)
        dash_frame.pack(fill='x', padx=10, pady=5)

        # State
        state_row = tk.Frame(dash_frame, bg='#1a1a2e')
        state_row.pack(fill='x', pady=2)
        tk.Label(state_row, text='State:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.state_label = tk.Label(state_row, text='IDLE', bg='#4CAF50', fg='white',
                                    font=('Consolas', 11, 'bold'), width=14, relief='raised')
        self.state_label.pack(side='left', padx=8)

        # Target
        target_row = tk.Frame(dash_frame, bg='#1a1a2e')
        target_row.pack(fill='x', pady=2)
        tk.Label(target_row, text='Target:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.target_label = tk.Label(target_row, text='---', bg='#0d1117', fg='yellow',
                                     font=('Consolas', 11, 'bold'), width=14)
        self.target_label.pack(side='left', padx=8)

        # Last RFID
        rfid_row = tk.Frame(dash_frame, bg='#1a1a2e')
        rfid_row.pack(fill='x', pady=2)
        tk.Label(rfid_row, text='Last RFID:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.rfid_label = tk.Label(rfid_row, text='---', bg='#0d1117', fg='#00ffff',
                                   font=('Consolas', 11), width=14)
        self.rfid_label.pack(side='left', padx=8)

        # Position
        pos_row = tk.Frame(dash_frame, bg='#1a1a2e')
        pos_row.pack(fill='x', pady=2)
        tk.Label(pos_row, text='Position:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.pos_label = tk.Label(pos_row, text='(0.00, 0.00)', bg='#0d1117', fg='#88ff88',
                                  font=('Consolas', 11), width=14)
        self.pos_label.pack(side='left', padx=8)

        # Heading
        hdg_row = tk.Frame(dash_frame, bg='#1a1a2e')
        hdg_row.pack(fill='x', pady=2)
        tk.Label(hdg_row, text='Heading:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.hdg_label = tk.Label(hdg_row, text='90.0 deg', bg='#0d1117', fg='#ffaa00',
                                  font=('Consolas', 11), width=14)
        self.hdg_label.pack(side='left', padx=8)

        # Queue
        queue_row = tk.Frame(dash_frame, bg='#1a1a2e')
        queue_row.pack(fill='x', pady=2)
        tk.Label(queue_row, text='Queue:', bg='#1a1a2e', fg='#aaa',
                 font=('Arial', 10, 'bold'), width=10, anchor='e').pack(side='left')
        self.queue_label = tk.Label(queue_row, text='(empty)', bg='#0d1117', fg='orange',
                                    font=('Consolas', 10), width=22, anchor='w')
        self.queue_label.pack(side='left', padx=8)


        # --- Mission Log ---
        log_frame = tk.LabelFrame(parent, text=" Mission Log ",
                                  font=('Arial', 10, 'bold'),
                                  bg='#1a1a2e', fg='#FF9800', padx=5, pady=5)
        log_frame.pack(fill='both', expand=True, padx=10, pady=5)

        self.log_text = scrolledtext.ScrolledText(log_frame, height=12, bg='#0a0a0a',
                                                   fg='#00ff00', font=('Consolas', 9),
                                                   wrap='word', state='disabled')
        self.log_text.pack(fill='both', expand=True)
        self._log("Warehouse AGV Simulation initialized.")
        self._log(f"  {len(SHELF_MAP)} shelves available (S01-S{len(SHELF_MAP):02d})")
        self._log(f"  Track: tree topology (1 main aisle + {COLS} spurs)")
        self._log("  Ready for orders.")

    # =========================================================================
    # ACTIONS
    # =========================================================================

    def _on_send(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get() or 'SKU-0000'
        self.controller.send_order(shelf, sku)

    def _on_queue(self):
        shelf = self.shelf_var.get()
        sku = self.sku_var.get() or 'SKU-0000'
        self.controller.order_queue.append((shelf, sku))
        self._log(f"Queued: {shelf} ({sku})")

    def _on_reset(self):
        """Emergency reset."""
        self.controller.state = IDLE
        self.controller.target_shelf = None
        self.controller.pivoting = False
        self.controller.arm_working = False
        self.controller.order_queue.clear()
        self.agv.reset_to_home()
        self._log("RESET: AGV returned to HOME.")


    # =========================================================================
    # LOGGING
    # =========================================================================

    def _log(self, msg):
        ts = datetime.now().strftime('%H:%M:%S')
        self.log_text.configure(state='normal')
        self.log_text.insert('end', f'[{ts}] {msg}\n')
        self.log_text.see('end')
        self.log_text.configure(state='disabled')

    # =========================================================================
    # SIMULATION LOOP
    # =========================================================================

    def _sim_loop(self):
        """Main simulation loop called by Tkinter's after()."""
        if not self.running:
            return

        now = time.time()
        dt = min(now - self.last_time, 0.1)  # cap dt
        self.last_time = now

        # Update simulation
        self.controller.update(dt)
        self.agv.read_line_sensors()

        # Update display
        self._update_dashboard()
        self._draw_warehouse()

        # Schedule next frame
        self.root.after(33, self._sim_loop)  # ~30 FPS

    def _update_dashboard(self):
        """Update dashboard labels."""
        state = self.controller.state
        self.state_label.config(text=state, bg=STATE_COLORS.get(state, '#666'))
        self.target_label.config(text=self.controller.target_shelf or '---')
        self.rfid_label.config(text=self.controller.last_rfid or '---')
        self.pos_label.config(text=f"({self.agv.x:+.2f}, {self.agv.y:+.2f})")
        self.hdg_label.config(text=f"{math.degrees(self.agv.yaw):+.1f} deg")

        # Queue display
        if self.controller.order_queue:
            q_text = ' > '.join([s for s, _ in self.controller.order_queue])
            self.queue_label.config(text=q_text)
        else:
            self.queue_label.config(text='(empty)')

        # Sensor display
        readings = self.agv.sensor_readings
        sensor_str = ' '.join([str(r) for r in readings])
        self.sensor_display.config(text=f"[{sensor_str}]")
        # Color based on line detection
        if self.agv.line_detected:
            self.sensor_display.config(fg='#00ff00')
        else:
            self.sensor_display.config(fg='#ff4444')


    # =========================================================================
    # WAREHOUSE RENDERING
    # =========================================================================

    def _draw_warehouse(self):
        """Draw the complete warehouse on the canvas."""
        self.canvas.delete('all')

        # --- Draw floor grid (subtle) ---
        for i in range(0, 700, 50):
            self.canvas.create_line(i, 0, i, 520, fill='#161b22', width=1)
        for i in range(0, 520, 50):
            self.canvas.create_line(0, i, 700, i, fill='#161b22', width=1)

        # --- Draw track lines (black tape) ---
        for seg in TRACK_SEGMENTS:
            x1, y1 = world_to_canvas(seg[0], seg[1])
            x2, y2 = world_to_canvas(seg[2], seg[3])
            self.canvas.create_line(x1, y1, x2, y2, fill='#333333', width=4)
            # White edges for visibility
            self.canvas.create_line(x1, y1, x2, y2, fill='#1a1a1a', width=6)
            self.canvas.create_line(x1, y1, x2, y2, fill='#444444', width=3)

        # --- Draw HOME zone ---
        hx, hy = world_to_canvas(HOME_X, HOME_Y)
        self.canvas.create_oval(hx - 14, hy - 14, hx + 14, hy + 14,
                                fill='#1b5e20', outline='#4CAF50', width=2)
        self.canvas.create_text(hx, hy, text='H', fill='white',
                                font=('Arial', 9, 'bold'))

        # --- Draw shelves and RFID tags ---
        for shelf_id, data in SHELF_MAP.items():
            sx, sy = world_to_canvas(data['tag_x'], data['tag_y'])

            # Shelf rack (rectangle offset from track)
            rack_offset = 18
            self.canvas.create_rectangle(sx - 12 + rack_offset, sy - 8,
                                         sx + 12 + rack_offset, sy + 8,
                                         fill='#3e2723', outline='#8d6e63', width=1)

            # Also on the other side
            self.canvas.create_rectangle(sx - 12 - rack_offset, sy - 8,
                                         sx + 12 - rack_offset, sy + 8,
                                         fill='#3e2723', outline='#8d6e63', width=1)

            # RFID tag (blue dot on track)
            self.canvas.create_oval(sx - 4, sy - 4, sx + 4, sy + 4,
                                    fill='#1565C0', outline='#42A5F5', width=1)

            # Shelf label
            self.canvas.create_text(sx + rack_offset, sy,
                                    text=shelf_id, fill='#bcaaa4',
                                    font=('Consolas', 7))

        # --- Draw target highlight ---
        if self.controller.target_shelf and self.controller.target_shelf in SHELF_MAP:
            td = SHELF_MAP[self.controller.target_shelf]
            tx, ty = world_to_canvas(td['tag_x'], td['tag_y'])
            self.canvas.create_oval(tx - 18, ty - 18, tx + 18, ty + 18,
                                    outline='#ffeb3b', width=2, dash=(4, 2))
            self.canvas.create_text(tx, ty - 24, text='TARGET',
                                    fill='#ffeb3b', font=('Arial', 7, 'bold'))

        # --- Draw AGV ---
        self._draw_agv()

        # --- Legend ---
        self._draw_legend()


    def _draw_agv(self):
        """Draw the AGV as a directional triangle with sensor indicators."""
        ax, ay = world_to_canvas(self.agv.x, self.agv.y)

        # AGV body (rotated triangle)
        size = 10
        angle = self.agv.yaw
        # Note: canvas Y is inverted, so negate the Y component
        points = []
        for a_offset in [0, 2.4, -2.4]:  # front, back-left, back-right
            if a_offset == 0:
                r = size * 1.4
            else:
                r = size
            px = ax + r * math.cos(-(angle + a_offset))  # negate for canvas
            py = ay + r * math.sin(-(angle + a_offset))
            points.extend([px, py])

        # Color based on state
        agv_color = STATE_COLORS.get(self.controller.state, '#ffffff')
        self.canvas.create_polygon(points, fill=agv_color, outline='white', width=2)

        # Draw direction indicator
        front_x = ax + size * 1.6 * math.cos(-angle)
        front_y = ay + size * 1.6 * math.sin(-angle)
        self.canvas.create_line(ax, ay, front_x, front_y, fill='white', width=2, arrow='last')

        # Draw sensor dots
        perp_angle = angle + math.pi / 2
        sensor_spread = 8  # pixels
        fwd_px = ax + 14 * math.cos(-angle)
        fwd_py = ay + 14 * math.sin(-angle)

        for i, reading in enumerate(self.agv.sensor_readings):
            offset = (i - 3.5) * (sensor_spread / 3.5)
            sx = fwd_px + offset * math.cos(-perp_angle)
            sy = fwd_py + offset * math.sin(-perp_angle)
            color = '#ff0000' if reading == 1 else '#00ff00'
            self.canvas.create_oval(sx - 2, sy - 2, sx + 2, sy + 2, fill=color, outline='')

        # Trail dot (breadcrumb)
        self.canvas.create_oval(ax - 1, ay - 1, ax + 1, ay + 1,
                                fill='#ffffff', outline='')

    def _draw_legend(self):
        """Draw a small legend in the top-right corner."""
        x0, y0 = 560, 10
        items = [
            ('#4CAF50', 'HOME zone'),
            ('#1565C0', 'RFID tag'),
            ('#8d6e63', 'Shelf rack'),
            ('#444444', 'Track line'),
            ('#ffeb3b', 'Target'),
        ]
        for i, (color, text) in enumerate(items):
            y = y0 + i * 16
            self.canvas.create_rectangle(x0, y, x0 + 10, y + 10, fill=color, outline='')
            self.canvas.create_text(x0 + 15, y + 5, text=text, fill='#888',
                                    font=('Consolas', 8), anchor='w')

    # =========================================================================
    # RUN
    # =========================================================================

    def run(self):
        """Start the Tkinter main loop."""
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        self.running = False
        self.root.destroy()



# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if __name__ == '__main__':
    print("""
    ╔══════════════════════════════════════════════════════════════╗
    ║   WAREHOUSE AGV SIMULATION - Complete Single-File Demo      ║
    ╠══════════════════════════════════════════════════════════════╣
    ║                                                              ║
    ║  Features:                                                   ║
    ║    - 4x5 warehouse with 20 shelves                          ║
    ║    - Tree-topology track (main aisle + 5 spurs)             ║
    ║    - 8-pixel line sensor with PID controller                ║
    ║    - RFID-based shelf detection                             ║
    ║    - Junction handling for spur entry/exit                  ║
    ║    - 180-degree pivot-and-retrace return                    ║
    ║    - Full state machine (IDLE->GOING->AT_SHELF->            ║
    ║      WAITING->PIVOTING->RETURNING->IDLE)                    ║
    ║    - Tkinter GUI with dashboard + mission log              ║
    ║    - Order queue for batch missions                         ║
    ║                                                              ║
    ║  Usage:                                                      ║
    ║    1. Select a shelf (S01-S20) from the dropdown            ║
    ║    2. Click SEND ORDER to dispatch AGV                      ║
    ║    3. Watch the AGV navigate in real-time                   ║
    ║    4. Use + QUEUE to batch multiple orders                  ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    app = AGVSimulationApp()
    app.run()
