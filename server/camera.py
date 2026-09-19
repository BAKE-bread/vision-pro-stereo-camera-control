"""Capture both eyes and aligned metric depth in ONE acquisition."""
from dataclasses import dataclass
import time
import cv2
import numpy as np


@dataclass(frozen=True)
class DepthFrame:
    frame_id: int
    monotonic: float
    depth_m: np.ndarray
    fx: float
    fy: float
    cx: float
    cy: float


@dataclass(frozen=True)
class Frame:
    frame_id: int
    captured_at_ms: int
    monotonic: float
    left: np.ndarray
    right: np.ndarray
    depth_m: np.ndarray
    fx: float
    fy: float
    cx: float
    cy: float
    source: str

    def measurement_frame(self):
        return DepthFrame(self.frame_id, self.monotonic, self.depth_m, self.fx, self.fy, self.cx, self.cy)

    def stereo_rgb(self):
        # One track, top=left/bottom=right; never let two consumers race for a pair.
        return np.ascontiguousarray(np.vstack((self.left, self.right)))


class MockCamera:
    """Analytic ray cast: actual stereo parallax + matching axial depth, no hardware."""
    def __init__(self, width=640, height=360):
        self.width, self.height = width, height
        self.fx = self.fy = width * 0.8
        self.cx, self.cy = (width - 1) / 2, (height - 1) / 2
        y, x = np.mgrid[:height, :width]
        self.rays = np.stack(((x-self.cx)/self.fx, (y-self.cy)/self.fy, np.ones_like(x)), -1)
        self.sequence = 0

    def _eye(self, rotation, eye_x):
        rays = self.rays @ rotation.T
        origin = rotation @ np.array([eye_x, 0, 0])
        # Rear wall z=6; rays behind the camera yield invalid depth.
        depth = np.divide(6-origin[2], rays[..., 2], out=np.full(rays.shape[:2], np.inf), where=rays[..., 2] > .02)
        points = origin + np.minimum(depth, 50)[..., None] * rays
        grid = ((np.floor(points[..., 0]*2) + np.floor(points[..., 1]*2)).astype(int) % 2)
        color = np.where(grid[..., None] == 0, [45, 68, 96], [65, 95, 128]).astype(np.uint8)
        for center, radius, rgb in [([-.65, .05, 2.4], .38, [250, 160, 55]),
                                    ([.65, -.12, 3.2], .6, [60, 205, 190]),
                                    ([0, .25, .85], .16, [240, 95, 130])]:
            oc = origin - np.array(center)
            a = np.sum(rays*rays, axis=-1)
            b = 2*np.sum(rays*oc, axis=-1)
            c = np.dot(oc, oc)-radius*radius
            disc = b*b-4*a*c
            hit = (-b-np.sqrt(np.maximum(disc, 0)))/(2*a)
            mask = (disc >= 0) & (hit > .1) & (hit < depth)
            depth[mask] = hit[mask]
            color[mask] = rgb
        depth[(depth > 20) | (depth <= 0)] = np.nan
        return color, depth.astype(np.float32)

    def capture(self, yaw=0., pitch=0.):
        ya, pi = np.deg2rad([yaw, pitch])
        # yaw positive right, pitch positive up; x right / y down / z forward.
        ry = np.array([[np.cos(ya), 0, np.sin(ya)], [0, 1, 0], [-np.sin(ya), 0, np.cos(ya)]])
        rx = np.array([[1, 0, 0], [0, np.cos(pi), -np.sin(pi)], [0, np.sin(pi), np.cos(pi)]])
        left, depth = self._eye(ry @ rx, -.0315)
        right, _ = self._eye(ry @ rx, .0315)
        self.sequence += 1
        for image, label in ((left, "LEFT"), (right, "RIGHT")):
            cv2.putText(image, f"SIM {label} #{self.sequence}", (12, 26), cv2.FONT_HERSHEY_SIMPLEX, .6, (240, 240, 240), 1)
        return Frame(self.sequence, int(time.time()*1000), time.monotonic(), left, right, depth,
                     self.fx, self.fy, self.cx, self.cy, "mock")

    def close(self):
        pass


class ZEDCamera:
    def __init__(self, width=640, height=360):
        import pyzed.sl as sl
        self.sl, self.zed = sl, sl.Camera()
        params = sl.InitParameters()
        params.camera_resolution = sl.RESOLUTION.HD720
        params.camera_fps = 30
        params.depth_mode = sl.DEPTH_MODE.NEURAL
        params.coordinate_units = sl.UNIT.METER
        params.coordinate_system = sl.COORDINATE_SYSTEM.IMAGE
        params.camera_image_flip = sl.FLIP_MODE.OFF
        params.async_grab_camera_recovery = True
        params.depth_minimum_distance = .2
        params.depth_maximum_distance = 20.
        status = self.zed.open(params)
        if status != sl.ERROR_CODE.SUCCESS:
            self.zed.close()
            raise RuntimeError(f"ZED open failed: {status}")
        try:
            self.width, self.height = width, height
            self.runtime = sl.RuntimeParameters()
            self.runtime.enable_depth = True
            self.runtime.enable_fill_mode = False
            self.runtime.confidence_threshold = 50
            self.runtime.texture_confidence_threshold = 80
            self.resolution = sl.Resolution(width, height)
            self.left, self.right, self.depth = sl.Mat(), sl.Mat(), sl.Mat()
            calibration = self.zed.get_camera_information(self.resolution).camera_configuration.calibration_parameters.left_cam
            self.intrinsics = calibration.fx, calibration.fy, calibration.cx, calibration.cy
            fx, fy, cx, cy = self.intrinsics
            if not np.isfinite(self.intrinsics).all() or fx <= 0 or fy <= 0 or not (0 <= cx < width and 0 <= cy < height):
                raise RuntimeError("ZED invalid camera intrinsics")
            self.sequence = 0
            self.last_timestamp_ms = None
        except Exception:
            self.zed.close()
            raise

    def capture(self, yaw=0., pitch=0.):
        sl = self.sl
        if self.zed.grab(self.runtime) != sl.ERROR_CODE.SUCCESS:
            raise RuntimeError("ZED acquisition failed")
        captured = time.monotonic()
        for name, buffer, view in (("left", self.left, sl.VIEW.LEFT), ("right", self.right, sl.VIEW.RIGHT)):
            status = self.zed.retrieve_image(buffer, view, sl.MEM.CPU, self.resolution)
            if status != sl.ERROR_CODE.SUCCESS:
                raise RuntimeError(f"ZED {name} extraction failed: {status}")
        status = self.zed.retrieve_measure(self.depth, sl.MEASURE.DEPTH, sl.MEM.CPU, self.resolution)
        if status != sl.ERROR_CODE.SUCCESS:
            raise RuntimeError(f"ZED depth extraction failed: {status}")
        left, right, depth = self.left.get_data(), self.right.get_data(), self.depth.get_data()
        for image in (left, right):
            if image.shape != (self.height, self.width, 4) or image.dtype != np.uint8:
                raise RuntimeError("ZED invalid image shape or type")
        if depth.shape != (self.height, self.width) or depth.dtype != np.float32:
            raise RuntimeError("ZED invalid depth shape or type")
        left, right = cv2.cvtColor(left, cv2.COLOR_BGRA2RGB), cv2.cvtColor(right, cv2.COLOR_BGRA2RGB)
        depth = depth.copy()
        depth[~np.isfinite(depth) | (depth < .2) | (depth > 20)] = np.nan
        timestamp_ms = int(self.zed.get_timestamp(sl.TIME_REFERENCE.IMAGE).get_milliseconds())
        if timestamp_ms <= 0 or (self.last_timestamp_ms is not None and timestamp_ms <= self.last_timestamp_ms):
            raise RuntimeError("ZED image timestamp did not advance")
        self.last_timestamp_ms = timestamp_ms
        self.sequence += 1
        return Frame(self.sequence, timestamp_ms,
                     captured, left, right, depth, *self.intrinsics, "zed")

    def close(self):
        self.zed.close()
