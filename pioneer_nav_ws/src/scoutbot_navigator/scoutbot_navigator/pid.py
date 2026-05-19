"""
pid.py
======
A small, defensive PID controller used by the scoutbot waypoint navigator.

Design choices and why each one fixes a previous project failure:

* **Anti-windup** via integral clamping -> integral term cannot grow
  without bound when actuators saturate. Previous project had unbounded
  integral, causing oscillation after the AGV freed itself from a stall.
* **Derivative on measurement** (not on error) -> a step in the setpoint
  does not produce a derivative spike. Previous controller spiked when
  a new waypoint was loaded.
* **Output saturation + dead-band** -> the navigator never issues
  micro-jitter commands like 1e-4 rad/s. Previous robot oscillated at
  the goal because of exactly that pattern.
* **Explicit reset()** -> called on every state-machine transition so a
  rotation that ended in saturation does not poison the next state.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class PIDConfig:
    """Tunable parameters for :class:`PID`. All values come from YAML."""
    kp: float
    ki: float
    kd: float
    output_min: float
    output_max: float
    integral_clamp: float
    deadband: float


class PID:
    """One-axis PID controller with anti-windup, output saturation, and deadband.

    Example::

        cfg = PIDConfig(kp=0.8, ki=0.0, kd=0.05,
                        output_min=0.0, output_max=1.0,
                        integral_clamp=0.5, deadband=0.01)
        pid = PID(cfg)
        v_cmd = pid.update(error=distance_to_goal, dt=0.02)
    """

    def __init__(self, cfg: PIDConfig) -> None:
        self.cfg = cfg
        self._integral: float = 0.0
        self._prev_measurement: Optional[float] = None
        self._last_output: float = 0.0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def reset(self) -> None:
        """Forget all internal state. Call on every FSM transition."""
        self._integral = 0.0
        self._prev_measurement = None
        self._last_output = 0.0

    # ------------------------------------------------------------------
    # Update
    # ------------------------------------------------------------------
    def update(self, error: float, dt: float,
               measurement: Optional[float] = None) -> float:
        """Compute the PID output for one tick.

        Parameters
        ----------
        error : float
            ``setpoint - measurement``. The navigator computes this directly
            (e.g., heading_error or distance_to_goal) so we accept it raw.
        dt : float
            Time since the last call, in seconds. Must be > 0. Caller is
            responsible for using a real wall/sim clock.
        measurement : float, optional
            The raw measurement, used for derivative-on-measurement when
            provided. If ``None``, we fall back to derivative-on-error.

        Returns
        -------
        float
            The (saturated, dead-banded) command to apply to the actuator.
        """
        if dt <= 0.0:
            # Pathological dt -> hold last output, don't divide by zero.
            return self._last_output

        # ---- proportional ------------------------------------------------
        p_term = self.cfg.kp * error

        # ---- integral with anti-windup ----------------------------------
        if self.cfg.ki != 0.0:
            self._integral += error * dt
            clamp = self.cfg.integral_clamp
            if self._integral > clamp:
                self._integral = clamp
            elif self._integral < -clamp:
                self._integral = -clamp
            i_term = self.cfg.ki * self._integral
        else:
            i_term = 0.0

        # ---- derivative (on measurement preferred) ----------------------
        if self.cfg.kd != 0.0:
            if measurement is not None:
                if self._prev_measurement is None:
                    d_input = 0.0  # avoid spike on first sample
                else:
                    # Note: derivative-on-measurement uses NEGATIVE sign so
                    # that a setpoint step does not appear in the derivative.
                    d_input = -(measurement - self._prev_measurement) / dt
                self._prev_measurement = measurement
            else:
                # Fallback: derivative-on-error. Caller stores prev error in
                # ``_prev_measurement`` slot for symmetry.
                if self._prev_measurement is None:
                    d_input = 0.0
                else:
                    d_input = (error - self._prev_measurement) / dt
                self._prev_measurement = error
            d_term = self.cfg.kd * d_input
        else:
            d_term = 0.0

        # ---- combine + saturate -----------------------------------------
        raw = p_term + i_term + d_term
        out = max(self.cfg.output_min, min(self.cfg.output_max, raw))

        # ---- dead-band: kill micro-jitter -------------------------------
        if abs(out) < self.cfg.deadband:
            out = 0.0

        # ---- back-calculation anti-windup (when saturated and ki>0) -----
        # If the output is saturated AND the integral is pushing further
        # in the same direction, peel back the integral so the controller
        # can recover quickly once the error decreases.
        if self.cfg.ki != 0.0 and (out != raw):
            self._integral -= (raw - out) / max(self.cfg.ki, 1e-9)

        self._last_output = out
        return out

    @property
    def last_output(self) -> float:
        return self._last_output
