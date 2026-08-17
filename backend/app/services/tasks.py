"""Progress tracking for operations that outlive an HTTP request.

Installing an exit node means installing Docker and pulling images on a machine we
have never touched before; on a slow VPS that is several minutes. Holding a request
open for that long fails behind every reverse proxy, so the API starts a task,
returns its id immediately, and the caller polls it.

Tasks live in memory. The panel is a single process, and a task that is lost to a
restart is meaningless anyway — the work either landed on the remote server or it
did not, and the exit node list says which.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

logger = logging.getLogger(__name__)

PENDING = "pending"
RUNNING = "running"
SUCCEEDED = "succeeded"
FAILED = "failed"

# Enough history to cover a bot polling a handful of parallel installs.
MAX_TASKS = 50
MAX_LOG_LINES = 400


@dataclass
class LogLine:
    at: datetime
    text: str


@dataclass
class Task:
    id: str
    action: str
    target: str
    status: str = PENDING
    step: str = ""
    error: str | None = None
    result: dict[str, Any] | None = None
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    finished_at: datetime | None = None
    log: list[LogLine] = field(default_factory=list)

    @property
    def done(self) -> bool:
        return self.status in (SUCCEEDED, FAILED)

    def emit(self, text: str) -> None:
        """Appends one progress line. Never let logging break the operation."""
        line = text.rstrip()
        if not line:
            return
        self.log.append(LogLine(at=datetime.now(timezone.utc), text=line[:2000]))
        if len(self.log) > MAX_LOG_LINES:
            del self.log[: len(self.log) - MAX_LOG_LINES]
        logger.info("[task %s] %s", self.id[:8], line)

    def begin(self, step: str) -> None:
        self.step = step
        self.emit(f"── {step}")


def detached(action: str, target: str) -> Task:
    """A task that carries a log but is never registered or polled.

    Reading a node's status or its logs is one SSH session that finishes inside the
    request, so there is nothing to poll — but the same provisioning code writes
    progress into a task, and that progress is still worth having in the panel log.
    """
    return Task(id=uuid.uuid4().hex, action=action, target=target)


class TaskRegistry:
    """A bounded, insertion-ordered set of the most recent tasks."""

    def __init__(self) -> None:
        self._tasks: dict[str, Task] = {}
        self._order: deque[str] = deque()
        self._running: dict[str, asyncio.Task[None]] = {}

    def get(self, task_id: str) -> Task | None:
        return self._tasks.get(task_id)

    def recent(self, limit: int = 20) -> list[Task]:
        ids = list(self._order)[-limit:]
        return [self._tasks[i] for i in reversed(ids) if i in self._tasks]

    def active_for(self, target: str) -> Task | None:
        """A task still working on the same node, so callers can refuse to race it."""
        for task_id in reversed(self._order):
            task = self._tasks.get(task_id)
            if task and task.target == target and not task.done:
                return task
        return None

    def start(self, action: str, target: str, work: Callable[[Task], Awaitable[None]]) -> Task:
        task = Task(id=uuid.uuid4().hex, action=action, target=target)
        self._tasks[task.id] = task
        self._order.append(task.id)
        self._prune()

        async def runner() -> None:
            task.status = RUNNING
            try:
                await work(task)
            except asyncio.CancelledError:
                task.status = FAILED
                task.error = "cancelled"
                task.emit("cancelled")
                raise
            except Exception as exc:  # noqa: BLE001 - the failure belongs in the task
                task.status = FAILED
                task.error = str(exc) or exc.__class__.__name__
                task.emit(f"failed: {task.error}")
                logger.exception("task %s (%s %s) failed", task.id[:8], action, target)
            else:
                if task.status == RUNNING:
                    task.status = SUCCEEDED
            finally:
                task.finished_at = datetime.now(timezone.utc)
                self._running.pop(task.id, None)

        self._running[task.id] = asyncio.create_task(runner())
        return task

    def _prune(self) -> None:
        while len(self._order) > MAX_TASKS:
            # Drop the oldest *finished* task: one somebody is still polling has to
            # stay, however old it is, and dropping it out of order would reshuffle
            # the history the caller sees.
            for index, task_id in enumerate(self._order):
                task = self._tasks.get(task_id)
                if task is None or task.done:
                    del self._order[index]
                    self._tasks.pop(task_id, None)
                    break
            else:
                return

    async def shutdown(self) -> None:
        for task in list(self._running.values()):
            task.cancel()
        for task in list(self._running.values()):
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass


tasks = TaskRegistry()
