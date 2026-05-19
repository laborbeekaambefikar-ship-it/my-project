# 📦 Prerequisites — One-Time System Setup

> Install everything you need before building the project. Run these commands once. Total time: 10 minutes.

---

## 🖥️ What You Need

- **Ubuntu 22.04** (native install, NOT WSL — Gazebo runs poorly in WSL)
- About **8 GB free disk space**
- Internet connection
- Sudo access

That's it. No other prerequisites.

---

## 📋 Step 1 — Update System

```bash
sudo apt update && sudo apt upgrade -y
```

This takes 1–5 minutes depending on how out-of-date your system is.

---

## 📋 Step 2 — Install ROS 2 Humble (if not already installed)

If you've already done the previous project, you can **skip this step** — ROS 2 is already there. Verify with:

```bash
ros2 --version
```

If you see `ros2 cli version: humble` you're good. **Skip to Step 3.**

If you see `command not found`, install ROS 2 Humble:

```bash
# Set up locale
sudo apt install -y locales
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8

# Add ROS 2 repository
sudo apt install -y software-properties-common curl
sudo add-apt-repository universe -y
sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
    | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

# Install ROS 2 Humble
sudo apt update
sudo apt install -y ros-humble-desktop-full ros-dev-tools
```

This takes 5–10 minutes. ~2 GB download.

---

## 📋 Step 3 — Install All Project Dependencies

These are the packages we'll use across all 5 stages. Install all at once:

```bash
sudo apt install -y \
    ros-humble-gazebo-ros-pkgs \
    ros-humble-xacro \
    ros-humble-joint-state-publisher-gui \
    ros-humble-teleop-twist-keyboard \
    ros-humble-visualization-msgs \
    ros-humble-rqt-graph \
    python3-colcon-common-extensions \
    python3-tk \
    python3-numpy \
    python3-pip
```

| Package | Why we need it |
|---|---|
| `gazebo-ros-pkgs` | Gazebo simulator + ROS bridge |
| `xacro` | URDF macro processor |
| `joint-state-publisher-gui` | Manual joint testing in RViz |
| `teleop-twist-keyboard` | Drive robot manually with keyboard |
| `visualization-msgs` | Marker arrays in RViz |
| `rqt-graph` | Visualize node/topic graph |
| `colcon-common-extensions` | Build tool |
| `python3-tk` | Tkinter GUI |
| `python3-numpy` | Math in optical sensor |
| `python3-pip` | Just for safety, in case we need any pip packages |

---

## 📋 Step 4 — Auto-source ROS in Every New Terminal

So you don't have to type `source /opt/ros/humble/setup.bash` every time you open a terminal:

```bash
echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
source ~/.bashrc
```

Verify it worked. Open a NEW terminal and run:

```bash
echo $ROS_DISTRO
```

It should print `humble`. If it prints nothing, the auto-source didn't work — repeat the command above.

---

## 📋 Step 5 — Test That Everything Installed

Quick sanity check that all the tools are findable:

```bash
which ros2          # should print: /opt/ros/humble/bin/ros2
which gazebo        # should print: /usr/bin/gazebo
which xacro         # should print: /opt/ros/humble/bin/xacro
which colcon        # should print: /opt/ros/humble/bin/colcon
python3 -c "import tkinter; print('tkinter OK')"   # should print: tkinter OK
python3 -c "import numpy;   print('numpy OK')"     # should print: numpy OK
```

All 6 lines must succeed. If any fails, install just that piece:
- `ros2` missing → re-do Step 2
- `gazebo` missing → `sudo apt install -y gazebo`
- `xacro` missing → `sudo apt install -y ros-humble-xacro`
- `colcon` missing → `sudo apt install -y python3-colcon-common-extensions`
- `tkinter` missing → `sudo apt install -y python3-tk`
- `numpy` missing → `sudo apt install -y python3-numpy`

---

## 📋 Step 6 — Verify Gazebo Actually Launches

This catches GPU/display problems early:

```bash
gazebo
```

A 3D Gazebo window should open showing an empty world. If it crashes or shows a black screen for >30 seconds, something's wrong with your graphics setup. Common fixes:

- **WSL users:** stop. Gazebo Classic does not work in WSL2 reliably. Use a native Ubuntu install.
- **VirtualBox users:** enable 3D acceleration in VM settings. Allocate at least 128 MB video memory.
- **NVIDIA users:** make sure you have proprietary drivers, not nouveau. Run `nvidia-smi` to verify.

Press **Ctrl+C** in the terminal to close Gazebo.

---

## 📋 Step 7 — Confirm Working Directory

We'll create the workspace in your home folder. Make sure your home folder isn't on a tiny partition:

```bash
df -h ~
```

You need at least **5 GB free** in `~`. The build artifacts take that much.

---

## ✅ Prereqs Done

You now have:
- ✅ ROS 2 Humble installed and auto-sourced in every terminal
- ✅ Gazebo with ROS plugins
- ✅ Xacro for URDF processing
- ✅ All Python libraries (Tkinter, NumPy)
- ✅ Build tools (colcon)
- ✅ Visualization tools (RViz, rqt_graph)
- ✅ Keyboard teleop for manual driving

**Open `01_WORLD.md` to start building the project.**

---

## 🆘 Troubleshooting

| Problem | Fix |
|---|---|
| `Unable to locate package ros-humble-...` | You're not on Ubuntu 22.04 OR repo wasn't added in Step 2 |
| `gazebo: command not found` | `sudo apt install gazebo` |
| Gazebo opens then crashes immediately | Graphics driver issue. WSL doesn't work, use native Ubuntu |
| `colcon: command not found` | `sudo apt install python3-colcon-common-extensions` |
| `tkinter` import fails | `sudo apt install python3-tk` |
| `ROS_DISTRO` is empty in new terminals | The auto-source in `~/.bashrc` didn't take. Open a fresh terminal. |
