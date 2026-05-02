from __future__ import annotations
from abc import abstractmethod
from ccreator.core.circuit import BaseCircuit


class BaseTestbench:
    @abstractmethod
    def build(self, tb):
        ...

    @abstractmethod
    def analysis(self, tb):
        ...

    def assertions(self, result):
        pass

    def run(self, assert_on_complete: bool = False):
        from ccreator.testbench.builder import TestbenchBuilder
        tb = TestbenchBuilder(type(self).__name__)
        self.build(tb)
        self.analysis(tb)
        result = tb.run()
        if assert_on_complete:
            self.assertions(result)
        return result

    @property
    def export(self) -> 'TestbenchExportProxy':
        return TestbenchExportProxy(self)


class TestbenchExportProxy:
    def __init__(self, tb: BaseTestbench):
        self._tb = tb

    def spice(self, path: str):
        from ccreator.testbench.builder import TestbenchBuilder
        from ccreator.testbench.spice_export import export_testbench_spice
        tb = TestbenchBuilder(type(self._tb).__name__)
        self._tb.build(tb)
        self._tb.analysis(tb)
        export_testbench_spice(tb, path)
