"""colony-api — a thin REST service over the colony CLI, shaped like the Mender
Management API so the Ground Station drives BASE (runtime+services) deployments
the same way it drives Mender APP deployments.

The whole point (see ground-station/docs/design/gs-ux-design.md §6): gs-api fans
out to colony-api + Mender through one client shape, so the operator sees ONE
deployments surface for two authorities — colony=base, Mender=app.
"""

__version__ = "0.1.0"
