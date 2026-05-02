"""Problem definition for Gm/Id circuit optimization.

Key difference from traditional optimizer: transistor L is FIXED.
The design variables are gm/Id ratios (and non-transistor params like R, C, Ibias).
W is derived from gm/Id lookup tables, never optimized directly.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional


class SpecKind(Enum):
    MINIMIZE = auto()
    MAXIMIZE = auto()
    GREATER_EQUAL = auto()
    LESS_EQUAL = auto()
    EQUAL = auto()
    RANGE = auto()


@dataclass
class Specification:
    name: str
    kind: SpecKind
    target: float = 0.0
    target_upper: Optional[float] = None
    tolerance: float = 1e-6
    weight: float = 1.0

    def to_constraint(self, measured: float) -> float:
        """Convert measured value to constraint value (negative = satisfied)."""
        match self.kind:
            case SpecKind.GREATER_EQUAL:
                return self.target - measured
            case SpecKind.LESS_EQUAL:
                return measured - self.target
            case SpecKind.EQUAL:
                return abs(measured - self.target) - self.tolerance
            case SpecKind.RANGE:
                upper = self.target_upper if self.target_upper is not None else self.target
                if measured < self.target:
                    return self.target - measured
                if measured > upper:
                    return measured - upper
                return -1.0
            case SpecKind.MINIMIZE | SpecKind.MAXIMIZE:
                return 0.0

    @property
    def is_constraint(self) -> bool:
        return self.kind not in (SpecKind.MINIMIZE, SpecKind.MAXIMIZE)

    @property
    def is_objective(self) -> bool:
        return not self.is_constraint


@dataclass
class Transistor:
    """A MOSFET with FIXED L. Design variable is gm/Id ratio."""
    instance: str
    model: str  # e.g. "nmos_3p3" or "pmos_3p3"
    kind: str  # "nmos" or "pmos"
    L: float  # Fixed channel length (meters)
    gmid_min: float = 3.0  # V^-1, strong inversion limit
    gmid_max: float = 25.0  # V^-1, weak inversion limit
    nf_min: int = 1
    nf_max: int = 20
    nf: int = 1  # Current number of fingers
    # Derived from lookup during optimization
    W: Optional[float] = None
    Vgs: Optional[float] = None
    Id: Optional[float] = None


@dataclass
class Resistor:
    instance: str
    R_min: float = 100.0
    R_max: float = 100e3
    step: Optional[float] = None
    R: Optional[float] = None


@dataclass
class Parameter:
    """Generic tunable parameter (bias current, voltage, etc.)."""
    name: str
    instance: str
    min: float
    max: float
    step: Optional[float] = None
    value: Optional[float] = None
    unit: str = ""
    enabled: bool = True


@dataclass
class Testbench:
    path: str
    name: str
    specs: list[Specification] = field(default_factory=list)
    timeout_s: float = 60.0

    @property
    def objective_count(self) -> int:
        return sum(1 for s in self.specs if s.is_objective)

    @property
    def constraint_count(self) -> int:
        return sum(1 for s in self.specs if s.is_constraint)


@dataclass
class Problem:
    """Complete Gm/Id optimization problem.

    Design variables:
    - gm/Id ratio per transistor (W derived from lookup tables)
    - nf per transistor (integer, number of fingers)
    - R per resistor
    - Any generic Parameter entries

    Fixed:
    - L per transistor (set by user, never optimized)
    """
    transistors: list[Transistor] = field(default_factory=list)
    resistors: list[Resistor] = field(default_factory=list)
    parameters: list[Parameter] = field(default_factory=list)
    testbenches: list[Testbench] = field(default_factory=list)

    @property
    def design_variable_count(self) -> int:
        """Number of continuous design variables (gm/Id per transistor + R + generic params)."""
        n = len(self.transistors)  # one gm/Id per transistor
        n += len(self.resistors)
        n += sum(1 for p in self.parameters if p.enabled)
        return n

    @property
    def integer_variable_count(self) -> int:
        """Number of integer variables (nf per transistor)."""
        return len(self.transistors)

    @property
    def objective_count(self) -> int:
        return sum(tb.objective_count for tb in self.testbenches)

    @property
    def constraint_count(self) -> int:
        return sum(tb.constraint_count for tb in self.testbenches)

    def get_bounds(self) -> tuple[list[float], list[float]]:
        """Return (lower_bounds, upper_bounds) for all continuous design variables."""
        lbs, ubs = [], []
        for t in self.transistors:
            lbs.append(t.gmid_min)
            ubs.append(t.gmid_max)
        for r in self.resistors:
            lbs.append(r.R_min)
            ubs.append(r.R_max)
        for p in self.parameters:
            if p.enabled:
                lbs.append(p.min)
                ubs.append(p.max)
        return lbs, ubs

    def get_nf_bounds(self) -> tuple[list[int], list[int]]:
        """Return (lower, upper) bounds for integer nf variables."""
        lbs = [t.nf_min for t in self.transistors]
        ubs = [t.nf_max for t in self.transistors]
        return lbs, ubs

    def apply_design_vector(self, x: list[float], nf: Optional[list[int]] = None) -> None:
        """Apply a design vector to the problem components.

        x ordering: [gmid_0, ..., gmid_n, R_0, ..., R_m, param_0, ..., param_k]
        nf ordering: [nf_0, ..., nf_n] (one per transistor)
        """
        idx = 0
        for t in self.transistors:
            # gm/Id ratio stored; W computed later via lookup
            t.gmid_min  # just accessing to confirm it's a Transistor
            idx += 1
        for r in self.resistors:
            r.R = x[idx]
            if r.step:
                r.R = round(r.R / r.step) * r.step
            idx += 1
        for p in self.parameters:
            if p.enabled:
                p.value = x[idx]
                if p.step:
                    p.value = round(p.value / p.step) * p.step
                idx += 1
        if nf:
            for i, t in enumerate(self.transistors):
                t.nf = nf[i]

    def all_specs(self) -> list[Specification]:
        specs = []
        for tb in self.testbenches:
            specs.extend(tb.specs)
        return specs
