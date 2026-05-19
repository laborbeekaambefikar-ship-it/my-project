"""Install script for the scoutbot_navigator ament_python package."""
from glob import glob
import os

from setuptools import setup

PACKAGE_NAME = 'scoutbot_navigator'

setup(
    name=PACKAGE_NAME,
    version='0.1.0',
    packages=[PACKAGE_NAME],
    data_files=[
        ('share/ament_index/resource_index/packages',
         ['resource/' + PACKAGE_NAME]),
        (os.path.join('share', PACKAGE_NAME), ['package.xml']),
        (os.path.join('share', PACKAGE_NAME, 'launch'),
         glob('launch/*.launch.py')),
        (os.path.join('share', PACKAGE_NAME, 'config'),
         glob('config/*.yaml')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='scoutbot maintainer',
    maintainer_email='dev@example.com',
    description='Waypoint navigator state machine for the scoutbot AGV.',
    license='Apache-2.0',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            # Format: <name-on-cli> = <module-path>:<function>
            'waypoint_navigator = scoutbot_navigator.waypoint_navigator:main',
            'nav_diagnostics    = scoutbot_navigator.diagnostic_node:main',
        ],
    },
)
