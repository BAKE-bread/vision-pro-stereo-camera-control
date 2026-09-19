"""Protocol 2.0 adapter for explicitly calibrated XM430-W350 / XL430-W250.

All register addresses and units follow the ROBOTIS control tables. No EEPROM
settings are changed. Both axes must pass read-only preflight before any write.
"""
import json
import math


SUPPORTED_MODELS = {1020: "XM430-W350", 1060: "XL430-W250"}


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"invalid {label}")
    return value


class DynamixelGimbal:
    def __init__(self, path):
        from dynamixel_sdk import PortHandler, PacketHandler, COMM_SUCCESS
        self.success = COMM_SUCCESS
        with open(path, encoding="utf-8") as f:
            self.config = json.load(f)
        if self.config.get("confirmed_position_mode") is not True:
            raise ValueError("Verify and confirm single-turn position mode in calibration first")
        self.axes = [self.config[axis] for axis in ("yaw", "pitch")]
        for axis in self.axes:
            integer(axis["id"], 0, 252, "servo ID")  # Never address broadcast/reserved IDs.
            integer(axis["model_number"], 0, 65535, "model number")
            if axis["model_number"] not in SUPPORTED_MODELS:
                raise ValueError("unsupported servo model")
            for field in ("min_tick", "center_tick", "max_tick"):
                integer(axis[field], 0, 4095, field)
            if not axis["min_tick"] < axis["center_tick"] < axis["max_tick"]:
                raise ValueError("invalid servo calibration limits")
            if (type(axis["sign"]) is not int or axis["sign"] not in (-1, 1)
                    or type(axis["ticks_per_degree"]) not in (int, float)
                    or not math.isfinite(axis["ticks_per_degree"]) or axis["ticks_per_degree"] <= 0):
                raise ValueError("invalid servo calibration scale")
            integer(axis["profile_velocity"], 1, 32767, "profile velocity")
            integer(axis["profile_acceleration"], 1, 32767, "profile acceleration")
        if len({axis["id"] for axis in self.axes}) != 2:
            raise ValueError("yaw and pitch require distinct servo IDs")
        integer(self.config["baud"], 1, 4_500_000, "baud rate")
        if not isinstance(self.config["port"], str) or not self.config["port"].strip():
            raise ValueError("invalid serial port")
        # 25 * 20 ms: the actuator stops if the process or serial bus disappears.
        self.watchdog = 25
        self.port, self.packet = PortHandler(self.config["port"]), PacketHandler(2.0)
        self.enabled = []
        self.initial = []
        try:
            if not self.port.openPort() or not self.port.setBaudRate(self.config["baud"]):
                raise RuntimeError("Cannot open calibrated gimbal serial port")
            for axis in self.axes:
                self._preflight(axis)
            for axis in self.axes:
                servo = axis["id"]
                self._write(4, servo, 108, axis["profile_acceleration"])
                self._write(4, servo, 112, axis["profile_velocity"])
                self._write(1, servo, 98, self.watchdog)
                # Re-read immediately before arming, after all read-only checks.
                tick = self._position(axis)
                self._write(4, servo, 116, tick)
                # The write may succeed even when its response is lost. Track the
                # attempt BEFORE sending, so rollback still tries torque-off.
                self.enabled.append(servo)
                self._write(1, servo, 64, 1)
                if self._read(1, servo, 64) != 1:
                    raise RuntimeError("Servo did not enable torque")
                actual = self._position(axis)
                if abs(actual - tick) > 2:
                    raise RuntimeError("Servo moved while enabling torque")
                self.initial.append((actual-axis["center_tick"])/(axis["sign"]*axis["ticks_per_degree"]))
        except Exception:
            try:
                self.close()
            except Exception:
                pass  # Preserve the initialization fault, not a cleanup fault.
            raise

    def _check(self, status, error):
        if status != self.success or error:
            raise RuntimeError(f"Dynamixel communication failure ({status}, {error})")

    def _read(self, size, servo, address):
        value, status, error = getattr(self.packet, f"read{size}ByteTxRx")(self.port, servo, address)
        self._check(status, error)
        return value

    def _write(self, size, servo, address, value):
        self._check(*getattr(self.packet, f"write{size}ByteTxRx")(self.port, servo, address, value))

    def _position(self, axis):
        tick = self._read(4, axis["id"], 132)
        # Torque-off position is signed/multi-turn. Reject out-of-range values;
        # never modulo-wrap them into an apparently valid single-turn command.
        if not axis["min_tick"] <= tick <= axis["max_tick"]:
            raise RuntimeError("Current servo position outside calibrated limits")
        return tick

    def _preflight(self, axis):
        servo = axis["id"]
        if self._read(2, servo, 0) != axis["model_number"]:
            raise RuntimeError("Servo model does not match calibration")
        if self._read(1, servo, 6) < 45:
            raise RuntimeError("Servo firmware 45 or later is required")
        # Drive mode 0 excludes reverse, time-based profiles and implicit torque
        # enable on goal updates. Zero homing offset avoids reset discontinuities.
        expected = {10: 0, 11: 3, 12: 255, 20: 0, 64: 0, 68: 2, 70: 0}
        for address, value in expected.items():
            if self._read(4 if address == 20 else 1, servo, address) != value:
                raise RuntimeError(f"Unsupported servo setting at register {address}; see hardware guide")
        if self._read(1, servo, 98) == 255:
            raise RuntimeError("Servo bus watchdog is latched; explicit device recovery required")
        low, high = self._read(4, servo, 52), self._read(4, servo, 48)
        if not 0 <= low <= axis["min_tick"] < axis["max_tick"] <= high <= 4095:
            raise RuntimeError("Calibration exceeds servo position limits")
        if axis["profile_velocity"] > self._read(4, servo, 44):
            raise RuntimeError("Profile velocity exceeds servo velocity limit")
        self._position(axis)

    def configuration(self):
        bounds = {}
        for name, axis in zip(("yaw", "pitch"), self.axes):
            bounds[name] = tuple(sorted((tick-axis["center_tick"])/(axis["sign"]*axis["ticks_per_degree"])
                                        for tick in (axis["min_tick"], axis["max_tick"])))
        return tuple(self.initial), bounds

    def move(self, yaw, pitch):
        if not all(math.isfinite(angle) for angle in (yaw, pitch)):
            raise ValueError("invalid angle")
        for axis in self.axes:
            servo = axis["id"]
            if (self._read(1, servo, 64) != 1 or self._read(1, servo, 70) != 0
                    or self._read(1, servo, 98) != self.watchdog):
                raise RuntimeError("Servo torque, hardware error or bus watchdog fault")
            self._position(axis)
        for axis, angle in zip(self.axes, (yaw, pitch)):
            tick = round(axis["center_tick"]+axis["sign"]*axis["ticks_per_degree"]*angle)
            tick = max(axis["min_tick"], min(axis["max_tick"], tick))
            self._write(4, axis["id"], 116, tick)

    def close(self):
        failure = None
        try:
            for servo_id in self.enabled:
                try:
                    self._write(1, servo_id, 64, 0)
                except Exception as error:
                    failure = failure or error
        finally:
            self.enabled = []
            self.port.closePort()
        if failure:
            raise failure
