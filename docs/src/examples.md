# Example Circuits

Schemify ships with 50+ example schematics covering analog, digital, and mixed-signal circuits. Find them in the `examples/` directory.

## Analog Fundamentals

| File | Circuit | Description |
|---|---|---|
| `rc_lowpass.chn` | RC Low-Pass Filter | First-order passive filter |
| `rl_highpass.chn` | RL High-Pass Filter | Inductive high-pass |
| `rlc_bandpass.chn` | RLC Band-Pass Filter | Second-order resonant filter |
| `rc_integrator.chn` | RC Integrator | Passive integrator |
| `integrator.chn` | Op-Amp Integrator | Active integrator with feedback |
| `differentiator.chn` | Differentiator | Active differentiator |

## Amplifiers

| File | Circuit | Description |
|---|---|---|
| `common_source.chn` | Common-Source Amplifier | Basic MOSFET gain stage |
| `common_source_active_load.chn` | CS with Active Load | Enhanced gain with PMOS load |
| `common_emitter.chn` | Common-Emitter Amplifier | BJT gain stage |
| `emitter_follower.chn` | Emitter Follower | Unity-gain buffer |
| `source_follower.chn` | Source Follower | MOSFET unity-gain buffer |
| `cascode_amplifier.chn` | Cascode Amplifier | High-gain, high-bandwidth |
| `inverting_amplifier.chn` | Inverting Amp | Op-amp inverting configuration |
| `noninverting_amplifier.chn` | Non-Inverting Amp | Op-amp non-inverting configuration |
| `summing_amplifier.chn` | Summing Amplifier | Multi-input weighted summer |
| `instrumentation_amp.chn` | Instrumentation Amp | High-CMRR differential amplifier |

## Current Mirrors & References

| File | Circuit | Description |
|---|---|---|
| `mosfet_current_mirror.chn` | MOSFET Current Mirror | Basic 2-transistor mirror |
| `bjt_current_mirror.chn` | BJT Current Mirror | Bipolar current mirror |
| `cascode_current_mirror.chn` | Cascode Mirror | High-output-impedance mirror |
| `bandgap_reference.chn` | Bandgap Reference | Temperature-independent voltage reference |

## Differential Pairs & OTAs

| File | Circuit | Description |
|---|---|---|
| `mosfet_diff_pair.chn` | MOSFET Differential Pair | Basic diff pair |
| `bjt_diff_pair.chn` | BJT Differential Pair | Bipolar diff pair |
| `folded_cascode_ota.chn` | Folded Cascode OTA | Wide-swing, high-gain amplifier |
| `comparator.chn` | Comparator | Voltage comparator |

## Digital Circuits

| File | Circuit | Description |
|---|---|---|
| `cmos_inverter.chn` | CMOS Inverter | Fundamental digital gate |
| `nand_gate.chn` | NAND Gate | 2-input CMOS NAND |
| `nor_gate.chn` | NOR Gate | 2-input CMOS NOR |
| `sr_latch.chn` | SR Latch | Set-reset latch |
| `ring_oscillator.chn` | Ring Oscillator | Odd-inverter chain oscillator |

## Mixed-Signal & Data Converters

| File | Circuit | Description |
|---|---|---|
| `bus_4bit_flash_adc.chn` | 4-bit Flash ADC | Parallel comparator ADC |
| `bus_8bit_dac.chn` | 8-bit DAC | Weighted-current DAC |
| `r2r_dac.chn` | R-2R DAC | Resistor-ladder DAC |
| `bus_current_dac.chn` | Current DAC | Current-steering DAC |
| `sample_and_hold.chn` | Sample & Hold | Track-and-hold circuit |

## Bus & Digital Systems

| File | Circuit | Description |
|---|---|---|
| `bus_parallel_adder.chn` | Parallel Adder | Multi-bit ripple-carry adder |
| `bus_shift_register.chn` | Shift Register | Serial-in parallel-out |
| `bus_sram_cell_array.chn` | SRAM Cell Array | Static RAM cells |
| `bus_mux_4to1.chn` | 4:1 Multiplexer | Bus multiplexer |
| `bus_decoder_2to4.chn` | 2:4 Decoder | Address decoder |
| `bus_data_bus_driver.chn` | Data Bus Driver | Tri-state bus driver |

## Power & PLLs

| File | Circuit | Description |
|---|---|---|
| `buck_converter.chn` | Buck Converter | Switching step-down regulator |
| `ldo_regulator.chn` | LDO Regulator | Linear dropout regulator |
| `charge_pump.chn` | Charge Pump | Switched-capacitor voltage multiplier |
| `charge_pump_pll.chn` | Charge-Pump PLL | Phase-locked loop |
| `phase_detector.chn` | Phase Detector | Phase/frequency detector |

## Testbenches

Each circuit category has matching testbenches (`.chn_tb` files) pre-configured with stimulus and analysis:

| Testbench | Simulation |
|---|---|
| `tb_cmos_inverter_vtc.chn_tb` | DC sweep (voltage transfer curve) |
| `tb_cmos_inverter_transient.chn_tb` | Transient (pulse response) |
| `tb_common_source_ac.chn_tb` | AC analysis (frequency response) |
| `tb_common_source_dc.chn_tb` | DC operating point |
| `tb_common_source_sweep.chn_tb` | DC sweep |
| `tb_bandgap_temp.chn_tb` | Temperature sweep |
| `tb_buck_converter_waveform.chn_tb` | Transient (switching waveform) |
| `tb_charge_pump_waveform.chn_tb` | Transient (charge pump output) |
| `tb_cascode_spectre.chn_tb` | Spectre-dialect simulation |

## Using the Examples

Open any example in the GUI:

```sh
schemify --file examples/cmos_inverter.chn
```

Or run a testbench simulation:

```sh
schemify --file examples/tb_cmos_inverter_vtc.chn_tb run-sim
```
