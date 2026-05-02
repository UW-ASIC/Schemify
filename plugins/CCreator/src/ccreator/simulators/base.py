from abc import ABC, abstractmethod
from ccreator.core.simulation_result import SimulationResult


class AbstractSimulator(ABC):
    @abstractmethod
    def ac(self, **kwargs) -> SimulationResult:
        ...

    @abstractmethod
    def tran(self, **kwargs) -> SimulationResult:
        ...
