"""MAME arguments the runner adds to every guest-driven process (`--ioc-speed`)."""

EXTRA = []


def ioc_speed(mode):
    """Select the IO controller's lane timing for the runs that follow ("paced" or "fast")."""
    EXTRA[:] = ["-ioc_speed", mode] if mode else []
