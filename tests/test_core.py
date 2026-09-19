from dataclasses import replace
import numpy as np
import pytest
from server.camera import MockCamera
from server.control import Controller, ControlError
from server.depth import measure, snapshot


def test_stereo_pair_and_depth_change_with_viewpoint():
    camera = MockCamera(160, 90)
    a, b = camera.capture(), camera.capture(25, 5)
    packed = a.stereo_rgb()
    assert np.array_equal(packed[:90], a.left)
    assert np.array_equal(packed[90:], a.right)
    assert not np.array_equal(a.left, a.right)
    assert not np.array_equal(a.depth_m, b.depth_m)
    assert np.isfinite(a.depth_m).mean() > .9


def test_center_and_edge_measurements_are_metric():
    frame = MockCamera(160, 90).capture()
    depth = np.full((90, 160), 2., np.float32)
    frame = replace(frame, depth_m=depth)
    center, edge = measure(frame, .5, .5), measure(frame, 1, 1)
    assert center['axial_m'] == 2
    assert center['range_m'] == pytest.approx(2, abs=.001)
    assert edge['range_m'] > edge['axial_m']
    assert len(snapshot(frame)['depth_m']) == 80*45


@pytest.mark.parametrize('value', [float('nan'), float('inf'), -1., 0.])
def test_invalid_depth_is_never_a_distance(value):
    frame = MockCamera(160, 90).capture()
    frame.depth_m[:] = value
    assert measure(frame, .5, .5)['valid'] is False
    snap = snapshot(frame)
    assert snap['near_m'] is None
    assert all(v is None for v in snap['depth_m'])


def test_stale_and_out_of_bounds_rejected():
    frame = MockCamera(160, 90).capture()
    with pytest.raises(ValueError, match='stale'):
        measure(replace(frame, monotonic=0), .5, .5)
    for u, v in [(-.1, .5), (.5, 1.1), (float('nan'), .5)]:
        with pytest.raises(ValueError):
            measure(frame, u, v)


def test_lease_exclusion_rate_limit_and_watchdog():
    now = [0.]
    controller = Controller(clock=lambda: now[0])
    lease = controller.acquire()['lease_id']
    with pytest.raises(ControlError, match='busy'):
        controller.acquire()
    controller.command(lease, 0, 900, -900)
    now[0] = .1
    controller.tick()
    assert controller.yaw == pytest.approx(3.5)
    assert controller.target_yaw == 70
    assert controller.target_pitch == -35
    with pytest.raises(ControlError, match='out_of_order'):
        controller.command(lease, 0, 0, 0)
    now[0] = 2
    controller.tick()
    assert not controller.state()['active']
    assert controller.target_yaw == controller.yaw == pytest.approx(3.5)
    with pytest.raises(ControlError, match='expired'):
        controller.command(lease, 1, 20, 0)


def test_bad_pose_does_not_extend_lease_or_move():
    controller = Controller()
    lease = controller.acquire()['lease_id']
    expiry = controller.expires
    with pytest.raises(ControlError):
        controller.command(lease, 0, float('nan'), 0)
    assert controller.expires == expiry
    assert controller.target_yaw == 0
    controller.release('not-the-owner')
    assert controller.lease == lease


def test_near_warning_can_be_demonstrated_by_looking_down():
    camera = MockCamera(160, 90)
    frame = camera.capture(0, -17)
    summary = snapshot(frame)
    assert summary['near_warning'] is True
    assert .5 < summary['near_m'] < 1


def test_asymmetric_hardware_limits():
    c = Controller()
    c.bounds['yaw'] = (-10, 20)
    lease = c.acquire()['lease_id']
    c.command(lease, 0, 70, 0)
    assert c.target_yaw == 20
    c.command(lease, 1, -70, 0)
    assert c.target_yaw == -10
