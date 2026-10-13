"""Operating-mode state machine.

SAFE  - people are expected; collect statistics, never raise alerts.
GUARD - people are NOT expected; a person present continuously for longer than
        `intrusion_seconds` raises exactly one intrusion trigger per episode.

The manager only consumes detection confidences (not images), so it is easy to
unit test and to drive from other sources (e.g. a network stream or an API).
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional, Sequence


class Mode(Enum):
    SAFE = "SAFE"
    GUARD = "GUARD"


@dataclass
class SafeStats:
    """Running statistics collected while in SAFE mode."""

    frames: int = 0
    frames_with_people: int = 0
    peak_count: int = 0
    _conf_sum: float = 0.0
    _conf_n: int = 0

    def record(self, confidences: Sequence[float]) -> None:
        self.frames += 1
        if confidences:
            self.frames_with_people += 1
            self.peak_count = max(self.peak_count, len(confidences))
            self._conf_sum += sum(confidences)
            self._conf_n += len(confidences)

    @property
    def occupancy_ratio(self) -> float:
        return self.frames_with_people / self.frames if self.frames else 0.0

    @property
    def mean_confidence(self) -> float:
        return self._conf_sum / self._conf_n if self._conf_n else 0.0


@dataclass(frozen=True)
class FrameState:
    """Per-frame result handed back to the application."""

    mode: Mode
    person_count: int
    avg_confidence: float
    max_confidence: float
    presence_seconds: float      # continuous presence time (GUARD mode only)
    intrusion_triggered: bool    # True only on the frame the threshold is crossed


class ModeManager:
    def __init__(
        self,
        intrusion_seconds: float = 3.0,
        grace_seconds: float = 0.7,
        initial_mode: Mode = Mode.SAFE,
        on_mode_change: Optional[Callable[[Mode, Mode], None]] = None,
    ) -> None:
        """
        intrusion_seconds: continuous presence required to trigger an alert.
        grace_seconds:     how long a person may vanish (missed detections,
                           motion blur) before the continuous timer resets.
        """
        self.intrusion_seconds = intrusion_seconds
        self.grace_seconds = grace_seconds
        self._on_mode_change = on_mode_change
        self._mode = initial_mode
        self.safe_stats = SafeStats()
        self._reset_presence()

    # ------------------------------------------------------------------ mode
    @property
    def mode(self) -> Mode:
        return self._mode

    def set_mode(self, new_mode: Mode) -> None:
        if new_mode == self._mode:
            return
        old, self._mode = self._mode, new_mode
        self._reset_presence()
        if new_mode is Mode.SAFE:
            self.safe_stats = SafeStats()
        if self._on_mode_change:
            self._on_mode_change(old, new_mode)

    # ---------------------------------------------------------------- update
    def update(self, confidences: Sequence[float], now: Optional[float] = None) -> FrameState:
        now = time.time() if now is None else now
        count = len(confidences)
        avg_conf = sum(confidences) / count if count else 0.0
        max_conf = max(confidences) if count else 0.0

        presence = 0.0
        triggered = False

        if self._mode is Mode.SAFE:
            self.safe_stats.record(confidences)
        else:
            presence, triggered = self._update_guard(count, now)

        return FrameState(self._mode, count, avg_conf, max_conf, presence, triggered)

    # --------------------------------------------------------------- helpers
    def _update_guard(self, count: int, now: float):
        if count > 0:
            if self._presence_start is None:
                self._presence_start = now
            self._last_seen = now
        elif self._presence_start is not None:
            # Person gone: only reset once the grace window has expired.
            if now - self._last_seen > self.grace_seconds:
                self._reset_presence()
                return 0.0, False

        if self._presence_start is None:
            return 0.0, False

        presence = now - self._presence_start
        triggered = False
        if presence > self.intrusion_seconds and not self._alert_latched:
            self._alert_latched = True  # one alert per continuous episode
            triggered = True
        return presence, triggered

    def _reset_presence(self) -> None:
        self._presence_start: Optional[float] = None
        self._last_seen: float = 0.0
        self._alert_latched = False
