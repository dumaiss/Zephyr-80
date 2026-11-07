"""MAME arguments the runner adds to every guest-driven process (`--ioc-speed`)."""

# Scripted runs take input from the harness alone: the desktop's mouse, keyboard and pads
# must not reach the fields a probe sets.
NO_HOST_INPUT = ["-mouseprovider", "none", "-keyboardprovider", "none", "-joystickprovider", "none"]

EXTRA = list(NO_HOST_INPUT)


def ioc_speed(mode):
    """Select the IO controller's lane timing for the runs that follow ("paced" or "fast")."""
    EXTRA[:] = NO_HOST_INPUT + (["-ioc_speed", mode] if mode else [])
