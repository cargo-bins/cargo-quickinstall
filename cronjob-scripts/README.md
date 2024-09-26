# Scripts

This folder contains python scripts for use in cargo-quickinstall github actions for triggering builds.

This code has some quite heavy python dependencies and strong assumptions about running on unix, so we should not use it on the github actions runners that actually do the package building.

TODO: make a build_scripts/ folder and move all of the package building scripts into there (converting to python as desired).
