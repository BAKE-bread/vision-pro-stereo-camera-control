import base64
import time
import cv2
import numpy as np
from .camera import Frame

MAX_AGE_S = .75


def ensure_fresh(frame: Frame, now=None):
    if frame is None or (time.monotonic() if now is None else now) - frame.monotonic > MAX_AGE_S:
        raise ValueError("stale_frame")


def measure(frame: Frame, u: float, v: float):
    ensure_fresh(frame)
    if not np.isfinite([u, v]).all() or not (0 <= u <= 1 and 0 <= v <= 1):
        raise ValueError("invalid_coordinates")
    h, w = frame.depth_m.shape
    x, y = round(u*(w-1)), round(v*(h-1))
    z = float(frame.depth_m[y, x])
    result = {"frame_id": frame.frame_id, "u": u, "v": v, "valid": False,
              "axial_m": None, "range_m": None, "point_m": None}
    if not np.isfinite(z) or z <= 0:
        return result
    point = [(x-frame.cx)*z/frame.fx, (y-frame.cy)*z/frame.fy, z]
    result.update(valid=True, axial_m=round(z, 4), range_m=round(float(np.linalg.norm(point)), 4), point_m=point)
    return result


def snapshot(frame: Frame, near_threshold=1.0):
    ensure_fresh(frame)
    depth = cv2.resize(frame.depth_m, (80, 45), interpolation=cv2.INTER_NEAREST)
    valid = np.isfinite(depth) & (depth > 0)
    center = depth[15:30, 26:54]
    center_values = center[np.isfinite(center) & (center > 0)]
    # Percentile avoids claiming a single noisy pixel is a reliable obstacle.
    near = float(np.percentile(center_values, 10)) if center_values.size >= center.size*.3 else None
    ok, encoded = cv2.imencode(".jpg", cv2.cvtColor(frame.left, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 75])
    if not ok:
        raise RuntimeError("JPEG encoding failed")
    return {"protocol": 1, "frame_id": frame.frame_id, "captured_at_ms": frame.captured_at_ms,
            "source": frame.source, "age_ms": round((time.monotonic()-frame.monotonic)*1000),
            "width": frame.left.shape[1], "height": frame.left.shape[0],
            "preview_jpeg": base64.b64encode(encoded).decode("ascii"),
            "depth_width": 80, "depth_height": 45, "unit": "m", "alignment": "left",
            "depth_m": [round(float(z), 3) if good else None for z, good in zip(depth.flat, valid.flat)],
            "valid_fraction": float(valid.mean()), "near_m": near,
            "near_warning": near is not None and near < near_threshold,
            "intrinsics": {k: float(getattr(frame, k)) for k in ("fx", "fy", "cx", "cy")}}
