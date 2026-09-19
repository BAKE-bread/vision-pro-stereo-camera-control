import base64
import json
import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from server.app import create_app
from server.config import Settings


@pytest.fixture
def client():
    with TestClient(create_app(Settings(width=160, height=90, api_token='test-secret'))) as client:
        yield client


HEADERS = {'Authorization': 'Bearer test-secret'}


def test_auth_snapshot_and_paired_measure(client):
    assert client.get('/api/capabilities').status_code == 401
    cap = client.get('/api/capabilities', headers=HEADERS).json()
    assert cap['protocol'] == 1 and cap['stereo_layout'] == 'top-bottom'
    snapshot = client.get('/api/snapshot', headers=HEADERS).json()
    jpeg = np.frombuffer(base64.b64decode(snapshot['preview_jpeg']), dtype=np.uint8)
    assert cv2.imdecode(jpeg, cv2.IMREAD_COLOR).shape == (90, 160, 3)
    r = client.post('/api/depth/measure', headers=HEADERS, json={'frame_id': snapshot['frame_id'], 'u': .5, 'v': .5})
    assert r.status_code == 200 and r.json()['valid']
    assert client.post('/api/depth/measure', headers=HEADERS, json={'frame_id': 9999999, 'u': 0, 'v': 0}).status_code == 409
    assert client.post('/api/depth/measure', headers=HEADERS, json={'frame_id': 1, 'u': 1.1, 'v': 0}).status_code == 422
    assert client.post('/api/session', headers=HEADERS).status_code == 503


def test_websocket_exclusive_and_release_on_disconnect(client):
    with client.websocket_connect('/api/control') as ws:
        ws.send_json({'token': 'test-secret'})
        assert ws.receive_json()['type'] == 'lease'
        with client.websocket_connect('/api/control') as other:
            other.send_json({'token': 'test-secret'})
            assert other.receive_json()['error'] == 'control_busy'
        ws.send_json({'sequence': 0, 'yaw_deg': 30, 'pitch_deg': 5})
        assert ws.receive_json()['target_yaw_deg'] == 30
        ws.send_json({'sequence': 0, 'yaw_deg': 0, 'pitch_deg': 0})
        assert ws.receive_json()['error'] == 'out_of_order'
    assert client.get('/api/status', headers=HEADERS).json()['control']['active'] is False
    with client.websocket_connect('/api/control') as ws:
        ws.send_json({'token': 'test-secret'})
        assert ws.receive_json()['type'] == 'lease'
        ws.send_json({'type': 'release'})


def test_bad_control_payload_releases_lease(client):
    with client.websocket_connect('/api/control') as ws:
        ws.send_json({'token': 'test-secret'})
        ws.receive_json()
        ws.send_json({'sequence': -1, 'yaw_deg': 0, 'pitch_deg': 0})
        assert ws.receive_json()['error'] == 'invalid_or_stale_data'
    assert client.get('/api/status', headers=HEADERS).json()['control']['active'] is False


def test_hardware_requires_opt_in():
    with pytest.raises(ValueError, match='ENABLE_HARDWARE'):
        Settings(source='zed').validate()
    with pytest.raises(ValueError, match='LIVEKIT'):
        Settings(livekit_url='ws://localhost:7880').validate()


def test_wrong_token_and_cross_origin_control_are_denied(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect('/api/control') as ws:
            ws.send_json({'token': 'wrong'})
            ws.receive_json()
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect('/api/control', headers={'origin': 'https://unrelated.example'}):
            pass


def test_driver_fault_prevents_new_control(client):
    client.app.state.runtime.control_error = 'serial port disconnected'
    with client.websocket_connect('/api/control') as ws:
        ws.send_json({'token': 'test-secret'})
        assert ws.receive_json()['error'] == 'camera_unavailable'


def test_binary_json_control_matches_native_client_and_releases(client):
    with client.websocket_connect('/api/control') as ws:
        ws.send_bytes(json.dumps({'token': 'test-secret'}).encode('utf-8'))
        assert ws.receive_json()['type'] == 'lease'
        ws.send_bytes(json.dumps({'sequence': 0, 'yaw_deg': 10, 'pitch_deg': 0}).encode('utf-8'))
        ack = ws.receive_json()
        assert ack['type'] == 'ack' and ack['active']
    assert not client.get('/api/status', headers=HEADERS).json()['control']['active']


@pytest.mark.parametrize('payload', [b'[]', b'{broken', b'\xff'])
def test_malformed_binary_control_is_rejected_without_server_crash(client, payload):
    with client.websocket_connect('/api/control') as ws:
        ws.send_json({'token': 'test-secret'})
        assert ws.receive_json()['type'] == 'lease'
        ws.send_bytes(payload)
        assert ws.receive_json()['error'] == 'invalid_or_stale_data'
    assert not client.get('/api/status', headers=HEADERS).json()['control']['active']
