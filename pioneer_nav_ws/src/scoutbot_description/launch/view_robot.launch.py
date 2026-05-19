"""
view_robot.launch.py
====================
Stand-alone visualization of the scoutbot URDF in RViz, *without* Gazebo.

Use this to verify the geometry, joint axes, and TF tree before integrating
with the simulator. Manual joint movement is provided by joint_state_publisher_gui.

  ros2 launch scoutbot_description view_robot.launch.py
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import (
    Command, FindExecutable, LaunchConfiguration, PathJoinSubstitution
)
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description() -> LaunchDescription:
    # ---- Launch arguments -----------------------------------------------------
    use_gui = DeclareLaunchArgument(
        'use_gui', default_value='true',
        description='If true, run joint_state_publisher_gui for manual joint tweaking.'
    )

    # ---- Resolve URDF path ----------------------------------------------------
    urdf_path = PathJoinSubstitution([
        FindPackageShare('scoutbot_description'),
        'urdf', 'scoutbot.urdf.xacro',
    ])

    # ---- Process xacro -> URDF string at launch time --------------------------
    robot_description = {
        'robot_description': Command([
            FindExecutable(name='xacro'), ' ', urdf_path,
        ]),
    }

    # ---- Nodes ----------------------------------------------------------------
    rsp = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        name='robot_state_publisher',
        output='screen',
        parameters=[robot_description],
    )

    jsp_gui = Node(
        package='joint_state_publisher_gui',
        executable='joint_state_publisher_gui',
        name='joint_state_publisher_gui',
        output='screen',
        condition=IfCondition(LaunchConfiguration('use_gui')),
    )

    rviz_config = PathJoinSubstitution([
        FindPackageShare('scoutbot_description'),
        'rviz', 'scoutbot_view.rviz',
    ])

    rviz = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        output='screen',
        arguments=['-d', rviz_config],
    )

    return LaunchDescription([use_gui, rsp, jsp_gui, rviz])
