from __future__ import annotations
import pathlib
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ccreator.realistic._analog.circuit import RealisticAnalogCircuit


def to_spice_string(circuit: 'RealisticAnalogCircuit') -> str:
    from ccreator.realistic._analog.netlist_builder import NetlistBuilder
    name = type(circuit).__name__
    nb = NetlistBuilder(name)
    circuit.build(nb)
    pyspice_circ = nb._pyspice_circuit

    ports = getattr(circuit, 'ports', [])
    port_names = ' '.join(p.name for p in ports)

    lines = [f'.subckt {name} {port_names}']

    # Render elements from PySpice circuit
    for element in pyspice_circ.elements:
        lines.append(str(element))

    if pyspice_circ.raw_spice:
        lines.append(pyspice_circ.raw_spice.strip())

    lines.append(f'.ends {name}')
    lines.append('')
    return '\n'.join(lines)


def export_spice(circuit: 'RealisticAnalogCircuit', path: str):
    content = to_spice_string(circuit)
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
