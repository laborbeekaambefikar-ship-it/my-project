cmake_minimum_required(VERSION 3.8)
project(scoutbot_description)

# ============================================================================
# scoutbot_description
# Pure data package: URDF/xacro, RViz config, and a stand-alone view launcher.
# No compiled code. Files are installed to share/ so other packages can locate
# them via ament_index.
# ============================================================================

find_package(ament_cmake REQUIRED)

install(
  DIRECTORY urdf launch rviz meshes
  DESTINATION share/${PROJECT_NAME}
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()
