"""One serial owner per SDK device, including creation and final close."""
import asyncio
from concurrent.futures import ThreadPoolExecutor


class DeviceWorker:
    def __init__(self, factory, name):
        self._factory = factory
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix=name)
        self._device = None
        self._closing = False
        self._close_future = None

    async def start(self):
        if self._closing:
            raise RuntimeError("device_closing")

        def create():
            self._device = self._factory()

        await self._submit(create)

    async def _submit(self, operation):
        future = asyncio.get_running_loop().run_in_executor(self._executor, operation)
        try:
            return await asyncio.shield(future)
        except asyncio.CancelledError:
            # Observe failures from an operation whose waiter was cancelled.
            future.add_done_callback(lambda done: None if done.cancelled() else done.exception())
            raise

    async def call(self, method, *args):
        if self._closing:
            raise RuntimeError("device_closing")

        def invoke():
            return getattr(self._device, method)(*args)

        # Cancelling the awaiting coroutine cannot interrupt an SDK call. The
        # serial queue keeps close behind that call even after cancellation.
        return await self._submit(invoke)

    async def close(self):
        if self._close_future is None:
            self._closing = True

            def finish():
                if self._device is not None:
                    self._device.close()
                    self._device = None

            self._close_future = asyncio.get_running_loop().run_in_executor(self._executor, finish)
        try:
            await asyncio.shield(self._close_future)
        except asyncio.CancelledError:
            await self._close_future
            raise
        finally:
            self._executor.shutdown(wait=False)
