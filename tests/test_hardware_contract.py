"""Hardware protocol fault injection; no camera, serial port or actuator required."""
import json
import sys
from types import SimpleNamespace

import pytest

from server.gimbal import DynamixelGimbal
from server.config import Settings


class ServoBus:
    """Registers from the XM430-W350/XL430-W250 official Protocol 2 table."""
    def __init__(self):
        base = {0: 1020, 6: 45, 10: 0, 11: 3, 12: 255, 20: 0,
                44: 265, 48: 4095, 52: 0, 64: 0, 68: 2, 70: 0,
                98: 0, 108: 0, 112: 0, 116: 0, 132: 2048}
        self.registers = {11: dict(base), 10: dict(base)}
        self.writes = []
        self.reads = []
        self.fail_write = None
        self.fail_read = None
        self.enable_jump = False
        self.closed = False

    def openPort(self):
        return True

    def setBaudRate(self, baud):
        return baud == 57600

    def closePort(self):
        self.closed = True

    def read(self, size, port, servo, address):
        assert port is self
        expected_size = 2 if address == 0 else 4 if address in (20, 44, 48, 52, 132) else 1
        assert size == expected_size
        self.reads.append((servo, address))
        value = self.registers[servo][address]
        return value, (-1 if self.fail_read == (servo, address) else 0), 0

    def write(self, size, port, servo, address, value):
        assert port is self
        assert size == (1 if address in (64, 98) else 4)
        self.writes.append((servo, address, value))
        # Apply BEFORE returning an error: a missing ACK does not undo a write.
        self.registers[servo][address] = value
        if address == 64 and value == 1 and self.enable_jump:
            self.registers[servo][132] += 10
        return (-1 if self.fail_write == (servo, address, value) else 0), 0

    def read1ByteTxRx(self, *args): return self.read(1, *args)
    def read2ByteTxRx(self, *args): return self.read(2, *args)
    def read4ByteTxRx(self, *args): return self.read(4, *args)
    def write1ByteTxRx(self, *args): return self.write(1, *args)
    def write4ByteTxRx(self, *args): return self.write(4, *args)


@pytest.fixture
def hardware(monkeypatch, tmp_path):
    bus = ServoBus()
    def packet(version):
        assert version == 2.0
        return bus
    monkeypatch.setitem(sys.modules, 'dynamixel_sdk', SimpleNamespace(
        COMM_SUCCESS=0, PortHandler=lambda name: bus, PacketHandler=packet))
    config = json.loads(open('server/calibration.example.json', encoding='utf-8').read())
    config['confirmed_position_mode'] = True
    path = tmp_path / 'calibration.json'
    def create():
        path.write_text(json.dumps(config))
        return DynamixelGimbal(path)
    return bus, config, create


@pytest.mark.parametrize('address,value', [(0, 999), (6, 44), (10, 1), (10, 4), (10, 8),
    (11, 4), (12, 11), (20, 1024), (20, 0xffffffff), (64, 1), (68, 1), (70, 4),
    (98, 255), (48, 2100), (52, 2000), (44, 10), (132, 0xffffffff), (132, 6144)])
def test_bad_second_axis_is_rejected_before_any_write(hardware, address, value):
    bus, _, create = hardware
    bus.registers[10][address] = value
    with pytest.raises(RuntimeError): create()
    assert bus.writes == []
    assert bus.closed


def test_read_error_does_not_use_returned_register_value(hardware):
    bus, _, create = hardware
    bus.fail_read = (10, 132)
    with pytest.raises(RuntimeError, match='communication failure'): create()
    assert not bus.writes and bus.closed


@pytest.mark.parametrize('axis_id', [10, 11])
def test_enable_applied_but_ack_lost_still_disables_all_attempted_axes(hardware, axis_id):
    bus, _, create = hardware
    bus.fail_write = (axis_id, 64, 1)
    with pytest.raises(RuntimeError, match='communication failure'): create()
    assert bus.registers[11][64] == bus.registers[10][64] == 0
    assert (axis_id, 64, 0) in bus.writes
    assert bus.closed


def test_enable_position_discontinuity_aborts_and_disables(hardware):
    bus, _, create = hardware
    bus.enable_jump = True
    with pytest.raises(RuntimeError, match='moved'): create()
    assert bus.registers[11][64] == bus.registers[10][64] == 0


@pytest.mark.parametrize('model', [1020, 1060])
def test_supported_models_hold_current_position_before_arming_and_clamp_moves(hardware, model):
    bus, config, create = hardware
    for name, servo in [('yaw', 11), ('pitch', 10)]:
        config[name]['model_number'] = model
        bus.registers[servo][0] = model
    driver = create()
    assert driver.configuration()[0] == (0, 0)
    for servo in (11, 10):
        arming = bus.writes.index((servo, 64, 1))
        assert (servo, 116, 2048) in bus.writes[:arming]
        assert (servo, 98, 25) in bus.writes[:arming]
        assert (servo, 108, 5) in bus.writes[:arming]
        assert (servo, 112, 20) in bus.writes[:arming]
    driver.move(999, -999)
    assert bus.registers[11][116] == config['yaw']['max_tick']
    assert bus.registers[10][116] == config['pitch']['min_tick']
    driver.close()
    assert bus.registers[11][64] == bus.registers[10][64] == 0
    assert bus.closed


@pytest.mark.parametrize('address,value', [(64, 0), (70, 4), (98, 255), (98, 0), (132, 800)])
def test_runtime_fault_on_second_axis_prevents_both_goal_writes(hardware, address, value):
    bus, _, create = hardware
    driver = create()
    before = list(bus.writes)
    bus.registers[10][address] = value
    with pytest.raises(RuntimeError): driver.move(10, 5)
    assert bus.writes == before
    driver.close()


@pytest.mark.parametrize('field,value', [('id', 254), ('id', True), ('min_tick', 1.5),
    ('profile_velocity', 0), ('profile_acceleration', 0), ('model_number', 999)])
def test_invalid_calibration_never_opens_or_writes_bus(hardware, field, value):
    bus, config, create = hardware
    config['pitch'][field] = value
    with pytest.raises(ValueError): create()
    assert not bus.reads and not bus.writes


def test_mock_source_cannot_activate_a_physical_gimbal():
    with pytest.raises(ValueError, match='mock never actuates'):
        Settings(source='mock', calibration='any.json', enable_hardware=True).validate()


@pytest.mark.parametrize('fault', [None, 'open', 'calibration'])
def test_zed_initialization_uses_rectified_scaled_metric_contract_and_closes_on_failure(monkeypatch, fault):
    from server.camera import ZEDCamera
    class InitParameters:
        __slots__ = ('camera_resolution', 'camera_fps', 'depth_mode', 'coordinate_units',
                     'coordinate_system', 'camera_image_flip', 'async_grab_camera_recovery',
                     'depth_minimum_distance', 'depth_maximum_distance')
    class RuntimeParameters:
        __slots__ = ('enable_depth', 'enable_fill_mode', 'confidence_threshold', 'texture_confidence_threshold')
    class Resolution:
        def __init__(self, width, height): self.width, self.height = width, height
    class Camera:
        closed = False
        def open(self, params):
            assert params.camera_resolution == 'HD720' and params.camera_fps == 30
            assert params.coordinate_units == 'METER' and params.coordinate_system == 'IMAGE'
            assert params.camera_image_flip == 'OFF' and params.async_grab_camera_recovery is True
            assert params.depth_mode == 'NEURAL'
            assert (params.depth_minimum_distance, params.depth_maximum_distance) == (.2, 20.)
            return 1 if fault == 'open' else 0
        def get_camera_information(self, resolution):
            assert (resolution.width, resolution.height) == (640, 360)
            intrinsics = SimpleNamespace(fx=0 if fault == 'calibration' else 500, fy=500, cx=320, cy=180)
            return SimpleNamespace(camera_configuration=SimpleNamespace(
                calibration_parameters=SimpleNamespace(left_cam=intrinsics)))
        def close(self): self.closed = True
    camera = Camera()
    sl = SimpleNamespace(Camera=lambda: camera, InitParameters=InitParameters, RuntimeParameters=RuntimeParameters,
        Resolution=Resolution, Mat=object, ERROR_CODE=SimpleNamespace(SUCCESS=0), RESOLUTION=SimpleNamespace(HD720='HD720'),
        COORDINATE_SYSTEM=SimpleNamespace(IMAGE='IMAGE'), FLIP_MODE=SimpleNamespace(OFF='OFF'),
        UNIT=SimpleNamespace(METER='METER'), DEPTH_MODE=SimpleNamespace(NEURAL='NEURAL'))
    monkeypatch.setitem(sys.modules, 'pyzed', SimpleNamespace(sl=sl))
    monkeypatch.setitem(sys.modules, 'pyzed.sl', sl)
    if fault:
        with pytest.raises(RuntimeError, match='ZED'): ZEDCamera()
        assert camera.closed
    else:
        driver = ZEDCamera()
        assert driver.intrinsics == (500, 500, 320, 180)
        assert driver.runtime.enable_depth and not driver.runtime.enable_fill_mode
        assert (driver.runtime.confidence_threshold, driver.runtime.texture_confidence_threshold) == (50, 80)
        driver.close()
        assert camera.closed
