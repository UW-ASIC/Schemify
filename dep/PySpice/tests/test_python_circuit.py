"""
Python tests for pyspice_rs — tests the PyO3 bindings.

Run with: maturin develop && pytest tests/
"""
import pytest


def import_pyspice():
    """Import pyspice_rs, skip if not built yet."""
    try:
        import pyspice_rs
        return pyspice_rs
    except ImportError:
        pytest.skip("pyspice_rs not built — run 'maturin develop' first")


# ── Circuit Building ──


class TestCircuitCreation:
    def test_create_circuit(self):
        ps = import_pyspice()
        c = ps.Circuit("test_circuit")
        assert repr(c) == "Circuit('test_circuit')"

    def test_ground_node(self):
        ps = import_pyspice()
        c = ps.Circuit("gnd_test")
        assert c.gnd == "0"

    def test_str_output(self):
        ps = import_pyspice()
        c = ps.Circuit("netlist_test")
        netlist = str(c)
        assert ".title netlist_test" in netlist
        assert ".end" in netlist


class TestPassiveComponents:
    def test_resistor(self):
        ps = import_pyspice()
        c = ps.Circuit("r_test")
        c.R("1", "in", "out", 1000.0)
        netlist = str(c)
        assert "R1 in out 1k" in netlist

    def test_capacitor(self):
        ps = import_pyspice()
        c = ps.Circuit("c_test")
        c.C("1", "out", c.gnd, 10e-12)
        netlist = str(c)
        assert "C1 out 0 10p" in netlist

    def test_inductor(self):
        ps = import_pyspice()
        c = ps.Circuit("l_test")
        c.L("1", "in", "out", 1e-6)
        netlist = str(c)
        assert "L1 in out 1u" in netlist

    def test_mutual_inductor(self):
        ps = import_pyspice()
        c = ps.Circuit("k_test")
        c.L("1", "a", "b", 1e-6)
        c.L("2", "c", "d", 1e-6)
        c.K("1", "1", "2", 0.99)
        netlist = str(c)
        assert "K1 L1 L2 0.99" in netlist

    def test_raw_spice_resistor(self):
        ps = import_pyspice()
        c = ps.Circuit("raw_test")
        c.R("1", "in", "out", 0.0, raw_spice="9kOhm")
        netlist = str(c)
        assert "R1 in out 9kOhm" in netlist


class TestSources:
    def test_voltage_source(self):
        ps = import_pyspice()
        c = ps.Circuit("v_test")
        c.V("dd", "vdd", c.gnd, 3.3)
        netlist = str(c)
        assert "Vdd vdd 0 3.3" in netlist

    def test_current_source(self):
        ps = import_pyspice()
        c = ps.Circuit("i_test")
        c.I("bias", c.gnd, "base", 10e-6)
        netlist = str(c)
        assert "Ibias 0 base 10u" in netlist

    def test_behavioral_voltage(self):
        ps = import_pyspice()
        c = ps.Circuit("bv_test")
        c.BV("1", "out", c.gnd, "V(in)*2")
        netlist = str(c)
        assert "B1 out 0 V=V(in)*2" in netlist

    def test_behavioral_current(self):
        ps = import_pyspice()
        c = ps.Circuit("bi_test")
        c.BI("1", "out", c.gnd, "V(in)/1k")
        netlist = str(c)
        assert "B1 out 0 I=V(in)/1k" in netlist


class TestControlledSources:
    def test_vcvs(self):
        ps = import_pyspice()
        c = ps.Circuit("vcvs_test")
        c.E("1", "out_p", "out_m", "in_p", "in_m", voltage_gain=10.0)
        netlist = str(c)
        assert "E1 out_p out_m in_p in_m 10" in netlist

    def test_vccs(self):
        ps = import_pyspice()
        c = ps.Circuit("vccs_test")
        c.G("1", "out_p", "out_m", "in_p", "in_m", transconductance=1e-3)
        netlist = str(c)
        assert "G1 out_p out_m in_p in_m 0.001" in netlist

    def test_cccs(self):
        ps = import_pyspice()
        c = ps.Circuit("cccs_test")
        c.F("1", "out_p", "out_m", "Vsense", current_gain=100.0)
        netlist = str(c)
        assert "F1 out_p out_m Vsense 100" in netlist

    def test_ccvs(self):
        ps = import_pyspice()
        c = ps.Circuit("ccvs_test")
        c.H("1", "out_p", "out_m", "Vsense", transresistance=1e3)
        netlist = str(c)
        assert "H1 out_p out_m Vsense 1000" in netlist


class TestSemiconductors:
    def test_diode(self):
        ps = import_pyspice()
        c = ps.Circuit("d_test")
        c.D("1", "anode", "cathode", model="1N4148")
        netlist = str(c)
        assert "D1 anode cathode 1N4148" in netlist

    def test_bjt(self):
        ps = import_pyspice()
        c = ps.Circuit("q_test")
        c.Q("1", "collector", "base", c.gnd, model="2n2222a")
        netlist = str(c)
        assert "Q1 collector base 0 2n2222a" in netlist

    def test_bjt_alias(self):
        ps = import_pyspice()
        c = ps.Circuit("bjt_test")
        c.BJT("1", "collector", "base", c.gnd, model="2n2222a")
        netlist = str(c)
        assert "Q1 collector base 0 2n2222a" in netlist

    def test_mosfet(self):
        ps = import_pyspice()
        c = ps.Circuit("m_test")
        c.M("1", "drain", "gate", "source", "bulk", model="nmos_3p3")
        netlist = str(c)
        assert "M1 drain gate source bulk nmos_3p3" in netlist

    def test_mosfet_alias(self):
        ps = import_pyspice()
        c = ps.Circuit("mosfet_test")
        c.MOSFET("1", "drain", "gate", "source", "bulk", model="nmos_3p3")
        netlist = str(c)
        assert "M1 drain gate source bulk nmos_3p3" in netlist

    def test_jfet(self):
        ps = import_pyspice()
        c = ps.Circuit("j_test")
        c.J("1", "drain", "gate", "source", model="njf")
        netlist = str(c)
        assert "J1 drain gate source njf" in netlist

    def test_mesfet(self):
        ps = import_pyspice()
        c = ps.Circuit("z_test")
        c.Z("1", "drain", "gate", "source", model="mes")
        netlist = str(c)
        assert "Z1 drain gate source mes" in netlist


class TestSwitchesAndTLines:
    def test_voltage_switch(self):
        ps = import_pyspice()
        c = ps.Circuit("sw_test")
        c.S("1", "out", c.gnd, "ctrl_p", "ctrl_m", model="sw1")
        netlist = str(c)
        assert "S1 out 0 ctrl_p ctrl_m sw1" in netlist

    def test_current_switch(self):
        ps = import_pyspice()
        c = ps.Circuit("csw_test")
        c.W("1", "out", c.gnd, "Vctrl", model="csw1")
        netlist = str(c)
        assert "W1 out 0 Vctrl csw1" in netlist

    def test_transmission_line(self):
        ps = import_pyspice()
        c = ps.Circuit("tl_test")
        c.T("1", "in_p", "in_m", "out_p", "out_m", Z0=50.0, TD=1e-9)
        netlist = str(c)
        assert "T1 in_p in_m out_p out_m" in netlist
        assert "Z0=50" in netlist


class TestDirectives:
    def test_model(self):
        ps = import_pyspice()
        c = ps.Circuit("model_test")
        c.model("nmos_3p3", "NMOS", LEVEL=1, VTO=0.7, KP=110e-6)
        netlist = str(c)
        assert ".model nmos_3p3 NMOS" in netlist
        assert "LEVEL=1" in netlist

    def test_include(self):
        ps = import_pyspice()
        c = ps.Circuit("inc_test")
        c.include("/path/to/model.lib")
        netlist = str(c)
        assert ".include /path/to/model.lib" in netlist

    def test_lib(self):
        ps = import_pyspice()
        c = ps.Circuit("lib_test")
        c.lib("/path/to/pdk.lib", "tt")
        netlist = str(c)
        assert ".lib /path/to/pdk.lib tt" in netlist

    def test_parameter(self):
        ps = import_pyspice()
        c = ps.Circuit("param_test")
        c.parameter("vdd_val", "3.3")
        netlist = str(c)
        assert ".param vdd_val=3.3" in netlist

    def test_subcircuit_instance(self):
        ps = import_pyspice()
        c = ps.Circuit("x_test")
        c.X("1", "MyBuf", "in", "out", "vdd", "gnd")
        netlist = str(c)
        # "gnd" -> "0" via Node::from
        assert "X1 in out vdd 0 MyBuf" in netlist


class TestElementAccess:
    def test_getitem(self):
        ps = import_pyspice()
        c = ps.Circuit("access_test")
        c.R("1", "a", "b", 1000.0)
        result = c["1"]
        assert "R1" in result
        assert "a" in result
        assert "b" in result

    def test_getitem_not_found(self):
        ps = import_pyspice()
        c = ps.Circuit("access_test2")
        with pytest.raises(KeyError):
            _ = c["nonexistent"]

    def test_element_method(self):
        ps = import_pyspice()
        c = ps.Circuit("element_test")
        c.R("1", "a", "b", 1000.0)
        result = c.element("1")
        assert "R1" in result


class TestWaveformSources:
    def test_sinusoidal_voltage(self):
        ps = import_pyspice()
        c = ps.Circuit("sin_test")
        c.SinusoidalVoltageSource("1", "in", c.gnd,
                                  dc_offset=0.0, offset=0.0,
                                  amplitude=1.0, frequency=1000.0)
        netlist = str(c)
        assert "V1 in 0" in netlist
        assert "SIN(" in netlist

    def test_pulse_voltage(self):
        ps = import_pyspice()
        c = ps.Circuit("pulse_test")
        c.PulseVoltageSource("1", "clk", c.gnd,
                             initial_value=0.0, pulsed_value=3.3,
                             pulse_width=50e-9, period=100e-9,
                             rise_time=1e-9, fall_time=1e-9)
        netlist = str(c)
        assert "PULSE(" in netlist

    def test_pwl_voltage(self):
        ps = import_pyspice()
        c = ps.Circuit("pwl_test")
        c.PieceWiseLinearVoltageSource("1", "in", c.gnd,
                                       values=[(0.0, 0.0), (1e-6, 1.0), (2e-6, 0.0)])
        netlist = str(c)
        assert "PWL(" in netlist

    def test_sinusoidal_current(self):
        ps = import_pyspice()
        c = ps.Circuit("sin_i_test")
        c.SinusoidalCurrentSource("1", "in", c.gnd,
                                  dc_offset=0.0, offset=0.0,
                                  amplitude=1e-3, frequency=1000.0)
        netlist = str(c)
        assert "I1 in 0" in netlist
        assert "SIN(" in netlist


class TestSimulator:
    def test_create_simulator(self):
        ps = import_pyspice()
        c = ps.Circuit("sim_test")
        c.V("dd", "vdd", c.gnd, 3.3)
        sim = c.simulator()
        assert repr(sim) == "CircuitSimulator"

    def test_create_simulator_with_backend(self):
        ps = import_pyspice()
        c = ps.Circuit("sim_backend_test")
        c.V("dd", "vdd", c.gnd, 3.3)
        sim = c.simulator(simulator="ngspice-subprocess")
        assert repr(sim) == "CircuitSimulator"


class TestFullCircuit:
    """Test the complete circuit from TODO.md"""

    def test_folded_cascode(self):
        ps = import_pyspice()
        c = ps.Circuit("folded_cascode")
        M1 = c.MOSFET("1", "drain_1", "gate_1", "source_1", "bulk", model="nmos_3p3")
        M2 = c.MOSFET("2", "drain_2", "gate_2", "source_2", "bulk", model="pmos_3p3")
        R1 = c.R("1", "vdd", "drain_1", 1000.0)
        C1 = c.C("1", "out", c.gnd, 10e-12)
        V1 = c.V("dd", "vdd", c.gnd, 3.3)

        netlist = str(c)
        assert "M1 drain_1 gate_1 source_1 bulk nmos_3p3" in netlist
        assert "M2 drain_2 gate_2 source_2 bulk pmos_3p3" in netlist
        assert "R1 vdd drain_1 1k" in netlist
        assert "C1 out 0 10p" in netlist
        assert "Vdd vdd 0 3.3" in netlist
