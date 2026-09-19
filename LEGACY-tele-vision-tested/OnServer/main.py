# main.py

import asyncio
import logging
import signal
import time
import numpy as np
from threading import Event

import os
import sys
current_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(current_dir)
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from zed_capture import ZEDCapture
from streaming_server import WebRTCServer

# --- 配置 ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
logging.getLogger("aiortc").setLevel(logging.WARNING)


# --- 异步任务定义 (capture_loop) ---
async def capture_loop(zed: ZEDCapture, server: WebRTCServer, exit_event: asyncio.Event):
    """
    异步任务：ZED相机数据采集循环（现在调用新的分发方法）。
    """
    logging.info("Capture loop started.")
    loop = asyncio.get_running_loop()
    while not exit_event.is_set():
        frame_packet = await loop.run_in_executor(None, zed.grab_frame_packet)
        if frame_packet:
            # --- 关键修改：调用新的分发函数 ---
            await server.push_frame_packet_to_all(frame_packet)
    logging.info("Capture loop has stopped.")


# --- 主程序入口 ---
async def async_main():
    loop = asyncio.get_running_loop()
    # 关键：在正在运行的循环内部创建事件
    exit_event = asyncio.Event()

    # 关键：创建绝对安全的信号处理器
    def safe_signal_handler(signum, frame):
        logging.info("Signal received, setting exit event safely...")
        loop.call_soon_threadsafe(exit_event.set)

    # 注册新的安全信号处理器
    signal.signal(signal.SIGINT, safe_signal_handler)
    signal.signal(signal.SIGTERM, safe_signal_handler)

    zed = None
    tasks = []
    try:
        zed = ZEDCapture()
        await loop.run_in_executor(None, zed.open)
        logging.info("ZED camera initialized successfully.")
        
        webrtc_server = WebRTCServer()
        tasks.append(asyncio.create_task(webrtc_server.run_server()))
        tasks.append(asyncio.create_task(capture_loop(zed, webrtc_server, exit_event)))
        
        logging.info("\n======================================================\n"
                     "SYSTEM IS RUNNING\n"
                     "All components are active. Press Ctrl+C to shut down.\n"
                     "======================================================\n")
        await exit_event.wait()
    except Exception as e:
        logging.critical(f"A critical error occurred in main setup: {e}", exc_info=True)
    finally:
        logging.info("Shutting down all tasks...")
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if zed:
            await loop.run_in_executor(None, zed.close)
        logging.info("Application has shut down cleanly.")

if __name__ == "__main__":
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        pass # 主动按Ctrl+C退出时，asyncio.run可能会抛出此异常，我们平静地忽略它