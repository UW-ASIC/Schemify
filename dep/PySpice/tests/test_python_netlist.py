"""
Comprehensive netlist generation tests.

Covers: every component type, waveform sources, directives, edge cases,
unit integration, element access, subcircuit instances, ground aliasing.

Run: maturin develop && pytest tests/test_python_netlist.py -v
"""
import pytest


def ps():
    try:
        import pyspice_rs
        return pyspice_rs
    except ImportError:
        pytest.skip("pyspice_rs not built")


def unit():
    try:
        from pyspice_rs import unit
        return unit
    except ImportError:
        pytest.skip("pyspice_rs not built")


# ══════════════════════════════════════════════════════════════════════════════
# Circuit creation & basic properties
# ══════════════════════════════════════════════════════════════════════════════

class TestCircuitBasics:
    def test_empty_circuit_has_title_and_end(self):
        c = ps().Circuit("empty")
        netlist = str(c)
        assert ".title empty" in netlist
        assert ".end" in netlist

    def test_repr(self):
        c = ps().Circuit("repr_test")
        assert repr(c) == "Circuit('repr_test')"

    def test_gnd_is_zero(self):
        c = ps().Circuit("gnd")
        assert c.gnd == "0"

    def test_special_chars_in_title(self):
        c = ps().Circuit("Test: special & chars!")
        assert "Test: special & chars!" in str(c)

    def test_multiple_circuits_independent(self):
        c1 = ps().Circuit("c1")
        c2 = ps().Circuit("c2")
        c1.R("1", "a", "b", 1000.0)
        assert "R1" in str(c1)
        assert "R1" not in str(c2)


# ══════════════════════════════════════════════════════════════════════════════
# Passive components
# ══════════════════════════════════════════════════════════════════════════════

class TestPassives:
    def test_resistor_numeric(self):
        c = ps().Circuit("t")
        c.R("1", "a", "b", 4700.0)
        assert "R1 a b 4.7k" in str(c)

    def test_resistor_with_unit(self):
        u = unit()
        c = ps().Circuit("t")
        c.R("1", "a", "b", 4.7 @ u.u_kOhm)
        assert "R1 a b 4.7k" in str(c)

    def test_resistor_raw_spice(self):
        c = ps().Circuit("t")
        c.R("load", "out", c.gnd, 0.0, raw_spice="1Meg")
        assert "Rload out 0 1Meg" in str(c)

    def test_capacitor_picofarad(self):
        c = ps().Circuit("t")
        c.C("1", "a", "b", 100e-12)
        assert "C1 a b 100p" in str(c)

    def test_capacitor_with_unit(self):
        u = unit()
        c = ps().Circuit("t")
        c.C("1", "a", "b", 100 @ u.u_pF)
        assert "C1 a b 100p" in str(c)

    def test_inductor_microhenry(self):
        c = ps().Circuit("t")
        c.L("1", "a", "b", 2.2e-6)
        assert "L1 a b 2.2u" in str(c)

    def test_mutual_inductance(self):
        c = ps().Circuit("t")
        c.L("1", "a", "b", 1e-6)
        c.L("2", "c", "d", 1e-6)
        c.K("1", "1", "2", 0.95)
        netlist = str(c)
        assert "K1 L1 L2 0.95" in netlist

    def test_very_small_value(self):
        c = ps().Circuit("t")
        c.C("1", "a", "b", 1e-15)
        assert "C1 a b 1f" in str(c)

    def test_very_large_value(self):
        c = ps().Circuit("t")
        c.R("1", "a", "b", 1e6)
        netlist = str(c)
        assert "R1 a b" in netlist


# ══════════════════════════════════════════════════════════════════════════════
# Sources
# ══════════════════════════════════════════════════════════════════════════════

class TestSources:
    def test_dc_voltage(self):
        c = ps().Circuit("t")
        c.V("dd", "vdd", c.gnd, 5.0)
        assert "Vdd vdd 0 5" in str(c)

    def test_dc_voltage_with_unit(self):
        u = unit()
        c = ps().Circuit("t")
        c.V("dd", "vdd", c.gnd, 3.3 @ u.u_V)
        assert "Vdd vdd 0 3.3" in str(c)

    def test_dc_current(self):
        c = ps().Circuit("t")
        c.I("ref", c.gnd, "drain", 100e-6)
        assert "Iref 0 drain 100u" in str(c)

    def test_behavioral_voltage(self):
        c = ps().Circuit("t")
        c.BV("1", "out", c.gnd, "V(in)*2 + 0.5")
        netlist = str(c)
        assert "B1 out 0 V=V(in)*2 + 0.5" in netlist

    def test_behavioral_current(self):
        c = ps().Circuit("t")
        c.BI("1", "out", c.gnd, "V(ctrl)/1k")
        assert "B1 out 0 I=V(ctrl)/1k" in str(c)


# ══════════════════════════════════════════════════════════════════════════════
# Controlled sources
# ══════════════════════════════════════════════════════════════════════════════

class TestControlledSources:
    def test_vcvs(self):
        c = ps().Circuit("t")
        c.E("1", "op", "om", "ip", "im", voltage_gain=100.0)
        assert "E1 op om ip im 100" in str(c)

    def test_vccs(self):
        c = ps().Circuit("t")
        c.G("m1", "op", "om", "ip", "im", transconductance=0.01)
        assert "Gm1 op om ip im 0.01" in str(c)

    def test_cccs(self):
        c = ps().Circuit("t")
        c.F("1", "op", "om", "Vsense", current_gain=50.0)
        assert "F1 op om Vsense 50" in str(c)

    def test_ccvs(self):
        c = ps().Circuit("t")
        c.H("1", "op", "om", "Vsense", transresistance=500.0)
        assert "H1 op om Vsense 500" in str(c)


# ══════════════════════════════════════════════════════════════════════════════
# Semiconductors
# ══════════════════════════════════════════════════════════════════════════════

class TestSemiconductors:
    def test_diode(self):
        c = ps().Circuit("t")
        c.D("1", "anode", "cathode", model="1N4148")
        assert "D1 anode cathode 1N4148" in str(c)

    def test_bjt_npn(self):
        c = ps().Circuit("t")
        c.Q("1", "c", "b", "e", model="2N2222")
        assert "Q1 c b e 2N2222" in str(c)

    def test_bjt_alias(self):
        c = ps().Circuit("t")
        c.BJT("1", "c", "b", "e", model="BC547")
        assert "Q1 c b e BC547" in str(c)

    def test_mosfet(self):
        c = ps().Circuit("t")
        c.M("1", "d", "g", "s", "b", model="nmos3p3")
        assert "M1 d g s b nmos3p3" in str(c)

    def test_mosfet_alias(self):
        c = ps().Circuit("t")
        c.MOSFET("1", "d", "g", "s", "b", model="pmos")
        assert "M1 d g s b pmos" in str(c)

    def test_jfet(self):
        c = ps().Circuit("t")
        c.J("1", "d", "g", "s", model="njf_mod")
        assert "J1 d g s njf_mod" in str(c)

    def test_mesfet(self):
        c = ps().Circuit("t")
        c.Z("1", "d", "g", "s", model="mes_mod")
        assert "Z1 d g s mes_mod" in str(c)


# ══════════════════════════════════════════════════════════════════════════════
# Switches and transmission lines
# ══════════════════════════════════════════════════════════════════════════════

class TestSwitchesAndTLines:
    def test_voltage_switch(self):
        c = ps().Circuit("t")
        c.S("1", "out", c.gnd, "cp", "cm", model="sw1")
        assert "S1 out 0 cp cm sw1" in str(c)

    def test_current_switch(self):
        c = ps().Circuit("t")
        c.W("1", "out", c.gnd, "Vctrl", model="csw1")
        assert "W1 out 0 Vctrl csw1" in str(c)

    def test_transmission_line(self):
        c = ps().Circuit("t")
        c.T("1", "ip", "im", "op", "om", Z0=50.0, TD=1e-9)
        netlist = str(c)
        assert "T1 ip im op om" in netlist
        assert "Z0=50" in netlist
        assert "TD=" in netlist


# ══════════════════════════════════════════════════════════════════════════════
# Waveform sources
# ══════════════════════════════════════════════════════════════════════════════

class TestWaveformSources:
    def test_sinusoidal_voltage_default(self):
        c = ps().Circuit("t")
        c.SinusoidalVoltageSource("1", "in", c.gnd)
        netlist = str(c)
        assert "V1 in 0" in netlist
        assert "SIN(" in netlist

    def test_sinusoidal_voltage_custom(self):
        c = ps().Circuit("t")
        c.SinusoidalVoltageSource("1", "in", c.gnd,
                                   dc_offset=1.0, offset=0.5,
                                   amplitude=2.0, frequency=5000.0)
        netlist = str(c)
        assert "SIN(" in netlist

    def test_pulse_voltage(self):
        c = ps().Circuit("t")
        c.PulseVoltageSource("clk", "clk", c.gnd,
                              initial_value=0.0, pulsed_value=1.8,
                              pulse_width=5e-9, period=10e-9,
                              rise_time=0.1e-9, fall_time=0.1e-9)
        netlist = str(c)
        assert "Vclk clk 0" in netlist
        assert "PULSE(" in netlist

    def test_pwl_voltage(self):
        c = ps().Circuit("t")
        c.PieceWiseLinearVoltageSource("1", "in", c.gnd,
                                        values=[(0, 0), (1e-6, 1.0), (2e-6, 0.5), (3e-6, 0)])
        netlist = str(c)
        assert "PWL(" in netlist

    def test_sinusoidal_current(self):
        c = ps().Circuit("t")
        c.SinusoidalCurrentSource("1", "in", c.gnd,
                                   dc_offset=0.0, offset=0.0,
                                   amplitude=1e-3, frequency=10e3)
        netlist = str(c)
        assert "I1 in 0" in netlist
        assert "SIN(" in netlist

    def test_pulse_current(self):
        c = ps().Circuit("t")
        c.PulseCurrentSource("1", "in", c.gnd,
                              initial_value=0.0, pulsed_value=1e-3,
                              pulse_width=1e-6, period=2e-6)
        netlist = str(c)
        assert "I1 in 0" in netlist
        assert "PULSE(" in netlist


# ══════════════════════════════════════════════════════════════════════════════
# Directives
# ══════════════════════════════════════════════════════════════════════════════

class TestDirectives:
    def test_model_with_params(self):
        c = ps().Circuit("t")
        c.model("nmos1", "NMOS", LEVEL=1, VTO=0.7, KP=110e-6)
        netlist = str(c)
        assert ".model nmos1 NMOS" in netlist
        assert "LEVEL=1" in netlist
        assert "VTO=0.7" in netlist

    def test_model_no_params(self):
        c = ps().Circuit("t")
        c.model("simple_d", "D")
        assert ".model simple_d D" in str(c)

    def test_include(self):
        c = ps().Circuit("t")
        c.include("/pdk/sky130/models.spice")
        assert ".include /pdk/sky130/models.spice" in str(c)

    def test_lib(self):
        c = ps().Circuit("t")
        c.lib("/pdk/models.lib", "tt")
        assert ".lib /pdk/models.lib tt" in str(c)

    def test_parameter(self):
        c = ps().Circuit("t")
        c.parameter("width", "1u")
        assert ".param width=1u" in str(c)

    def test_multiple_parameters(self):
        c = ps().Circuit("t")
        c.parameter("vdd", "3.3")
        c.parameter("length", "100n")
        netlist = str(c)
        assert ".param vdd=3.3" in netlist
        assert ".param length=100n" in netlist

    def test_subcircuit_instance(self):
        c = ps().Circuit("t")
        c.X("1", "NAND2", "a", "b", "out", "vdd", "gnd")
        netlist = str(c)
        assert "X1" in netlist
        assert "NAND2" in netlist

    def test_subcircuit_gnd_conversion(self):
        """Nodes named 'gnd' should become '0'."""
        c = ps().Circuit("t")
        c.X("1", "Buf", "in", "out", "gnd")
        assert "0" in str(c)


# ══════════════════════════════════════════════════════════════════════════════
# Element access
# ══════════════════════════════════════════════════════════════════════════════

class TestElementAccess:
    def test_getitem_exists(self):
        c = ps().Circuit("t")
        c.R("1", "a", "b", 1e3)
        result = c["1"]
        assert "R1" in result

    def test_getitem_not_found_raises(self):
        c = ps().Circuit("t")
        with pytest.raises(KeyError):
            c["nonexistent"]

    def test_element_method(self):
        c = ps().Circuit("t")
        c.V("dd", "vdd", c.gnd, 3.3)
        result = c.element("dd")
        assert "Vdd" in result

    def test_access_after_multiple_adds(self):
        c = ps().Circuit("t")
        c.R("1", "a", "b", 1e3)
        c.C("2", "b", c.gnd, 1e-12)
        c.V("dd", "vdd", c.gnd, 5.0)
        assert "R1" in c["1"]
        assert "C2" in c["2"]
        assert "Vdd" in c["dd"]


# ══════════════════════════════════════════════════════════════════════════════
# Ground node aliasing
# ══════════════════════════════════════════════════════════════════════════════

class TestGroundAliasing:
    def test_gnd_string_becomes_zero(self):
        c = ps().Circuit("t")
        c.R("1", "a", "gnd", 1e3)
        assert "R1 a 0" in str(c)

    def test_zero_stays_zero(self):
        c = ps().Circuit("t")
        c.R("1", "a", "0", 1e3)
        assert "R1 a 0" in str(c)

    def test_circuit_gnd_property(self):
        c = ps().Circuit("t")
        c.R("1", "a", c.gnd, 1e3)
        assert "R1 a 0" in str(c)


# ══════════════════════════════════════════════════════════════════════════════
# Complex realistic circuits
# ══════════════════════════════════════════════════════════════════════════════

class TestRealisticCircuits:
    def test_voltage_divider(self):
        c = ps().Circuit("vdiv")
        c.V("dd", "vdd", c.gnd, 3.3)
        c.R("1", "vdd", "out", 10e3)
        c.R("2", "out", c.gnd, 10e3)
        netlist = str(c)
        assert "Vdd vdd 0 3.3" in netlist
        assert "R1 vdd out 10k" in netlist
        assert "R2 out 0 10k" in netlist

    def test_diff_pair(self):
        c = ps().Circuit("dp")
        c.V("dd", "vdd", c.gnd, 3.3)
        c.R("d1", "vdd", "vo_m", 5e3)
        c.R("d2", "vdd", "vo_p", 5e3)
        c.MOSFET("1", "vo_m", "vi_m", "tail", c.gnd, model="nmos")
        c.MOSFET("2", "vo_p", "vi_p", "tail", c.gnd, model="nmos")
        c.I("ss", c.gnd, "tail", 200e-6)
        netlist = str(c)
        assert "M1" in netlist
        assert "M2" in netlist
        assert "Iss" in netlist

    def test_bridge_rectifier(self):
        c = ps().Circuit("br")
        c.model("D1N", "D", IS=2.52e-9)
        c.SinusoidalVoltageSource("in", "ac_p", "ac_m",
                                   amplitude=12.0, frequency=60.0)
        c.D("1", "ac_p", "out_p", model="D1N")
        c.D("2", "out_m", "ac_p", model="D1N")
        c.D("3", "ac_m", "out_p", model="D1N")
        c.D("4", "out_m", "ac_m", model="D1N")
        c.C("1", "out_p", "out_m", 100e-6)
        c.R("load", "out_p", "out_m", 1e3)
        c.V("ref", "out_m", c.gnd, 0.0)
        netlist = str(c)
        assert "D1" in netlist
        assert "D2" in netlist
        assert "D3" in netlist
        assert "D4" in netlist
        assert ".model D1N D" in netlist

    def test_ring_oscillator_netlist(self):
        c = ps().Circuit("ro")
        c.V("dd", "vdd", c.gnd, 1.8)
        c.model("nm", "NMOS", LEVEL=1, VTO=0.4)
        c.model("pm", "PMOS", LEVEL=1, VTO=-0.4)
        for i in range(1, 4):
            prev = f"n{(i-2)%3+1}" if i > 1 else "n3"
            out = f"n{i}"
            c.MOSFET(f"{i}n", out, prev, c.gnd, c.gnd, model="nm")
            c.MOSFET(f"{i}p", out, prev, "vdd", "vdd", model="pm")
        netlist = str(c)
        for i in range(1, 4):
            assert f"M{i}n" in netlist
            assert f"M{i}p" in netlist

    def test_many_components(self):
        """Stress test: 100 resistors in series."""
        c = ps().Circuit("stress")
        c.V("in", "n0", c.gnd, 10.0)
        for i in range(100):
            c.R(str(i+1), f"n{i}", f"n{i+1}", 100.0)
        c.R("load", "n100", c.gnd, 1e3)
        netlist = str(c)
        assert "R1 n0 n1 100" in netlist
        assert "R100 n99 n100 100" in netlist
        assert "Rload n100 0" in netlist
