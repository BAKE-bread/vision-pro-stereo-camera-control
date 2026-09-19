"""Exclusive, expiring control with bounded absolute angles and slew rate."""
import math
import secrets
import time


class ControlError(ValueError):
    pass


class Controller:
    def __init__(self, clock=time.monotonic, driver=None):
        self.clock, self.driver = clock, driver
        self.lease = None
        self.expires = 0.
        self.sequence = -1
        self.yaw = self.pitch = self.target_yaw = self.target_pitch = 0.
        self.updated = clock()
        self.max_speed = 35.
        self.yaw_limit, self.pitch_limit = 70., 35.
        self.bounds = {"yaw": (-70., 70.), "pitch": (-35., 35.)}

    def acquire(self):
        self.tick()
        if self.lease:
            raise ControlError("control_busy")
        self.lease, self.sequence = secrets.token_urlsafe(24), -1
        self.expires = self.clock()+1.0
        return {"lease_id": self.lease, "ttl_ms": 1000, "yaw_deg": self.yaw, "pitch_deg": self.pitch}

    def command(self, lease_id, sequence, yaw, pitch):
        self.tick()
        if not self.lease or not secrets.compare_digest(self.lease, lease_id):
            raise ControlError("lease_expired")
        if sequence <= self.sequence:
            raise ControlError("out_of_order")
        if not all(math.isfinite(x) for x in (yaw, pitch)):
            raise ControlError("non_finite_pose")
        self.sequence = sequence
        self.target_yaw = max(self.bounds["yaw"][0], min(self.bounds["yaw"][1], yaw))
        self.target_pitch = max(self.bounds["pitch"][0], min(self.bounds["pitch"][1], pitch))
        self.expires = self.clock()+1.0
        return self.state()

    def release(self, lease_id):
        if self.lease and secrets.compare_digest(self.lease, lease_id):
            self.lease = None
            self.target_yaw, self.target_pitch = self.yaw, self.pitch

    def tick(self):
        now = self.clock()
        dt, self.updated = max(0., min(.1, now-self.updated)), now
        if self.lease and now >= self.expires:
            self.release(self.lease)
        step = self.max_speed*dt
        for axis in ("yaw", "pitch"):
            value, target = getattr(self, axis), getattr(self, "target_"+axis)
            setattr(self, axis, value+max(-step, min(step, target-value)))

    def state(self):
        return {"active": self.lease is not None, "yaw_deg": self.yaw, "pitch_deg": self.pitch,
                "target_yaw_deg": self.target_yaw, "target_pitch_deg": self.target_pitch,
                "hardware": self.driver is not None}
