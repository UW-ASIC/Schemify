from dataclasses import dataclass, field
from typing import Literal


@dataclass
class Port:
    name: str
    direction: Literal['input', 'output', 'inout']
    kind: Literal['voltage', 'current', 'logic', 'analog']
    width: int = 1
