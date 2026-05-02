"""ngspice netlist parser.

Handles:
  - Line continuation (+)
  - * comment lines and $ / ; inline comments
  - All standard element types: R C L D M Q J V I E G F H B X
  - .subckt/.ends, .model, .param, .global
  - .op .dc .ac .tran .noise .tf analyses
  - .measure/.meas
  - .control/.endc raw capture
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


@dataclass
class Param:
    key: str
    val: str


@dataclass
class Element:
    prefix: str  # lowercase single char: 'r', 'c', 'm', etc.
    name: str  # e.g. "M1", "R3"
    nodes: list[str]  # ordered net names
    value: Optional[str] = None  # R/C/L/V value string; None for M/Q/D
    model: Optional[str] = None  # model name for M/Q/D/J; subckt name for X
    params: list[Param] = field(default_factory=list)


@dataclass
class Model:
    name: str
    kind: str  # "nmos", "pmos", "npn", "pnp", "d", etc.


class AnalysisKind(Enum):
    OP = "op"
    DC = "dc"
    AC = "ac"
    TRAN = "tran"
    NOISE = "noise"
    TF = "tf"


@dataclass
class Analysis:
    kind: AnalysisKind
    raw: str  # raw tail of the dot line (e.g. "dec 10 1 1Meg")


@dataclass
class Measure:
    name: str
    expr: str


@dataclass
class Subckt:
    name: str
    ports: list[str]
    elements: list[Element]
    params: list[Param] = field(default_factory=list)


@dataclass
class Netlist:
    title: str = ""
    subckts: list[Subckt] = field(default_factory=list)
    top_elements: list[Element] = field(default_factory=list)
    models: list[Model] = field(default_factory=list)
    params: list[Param] = field(default_factory=list)
    globals: list[str] = field(default_factory=list)
    analyses: list[Analysis] = field(default_factory=list)
    measures: list[Measure] = field(default_factory=list)
    control_block: Optional[str] = None


def _trim_comment(line: str) -> str:
    for i, c in enumerate(line):
        if c in ("$", ";"):
            return line[:i].rstrip()
    return line


def _tokenize(line: str) -> list[str]:
    return line.split()


def _parse_params(tokens: list[str], start: int) -> list[Param]:
    result = []
    for tok in tokens[start:]:
        eq = tok.find("=")
        if eq < 0:
            continue
        k, v = tok[:eq], tok[eq + 1 :]
        if k:
            result.append(Param(key=k, val=v))
    return result


def _parse_element(line: str) -> Optional[Element]:
    if not line:
        return None
    prefix = line[0].lower()
    toks = _tokenize(line)
    if len(toks) < 2:
        return None
    name = toks[0]

    if prefix in ("r", "c", "l"):
        if len(toks) < 4:
            return None
        return Element(
            prefix=prefix,
            name=name,
            nodes=toks[1:3],
            value=toks[3],
            params=_parse_params(toks, 4),
        )

    if prefix == "d":
        if len(toks) < 4:
            return None
        return Element(
            prefix="d",
            name=name,
            nodes=toks[1:3],
            model=toks[3],
            params=_parse_params(toks, 4),
        )

    if prefix == "m":
        # M name D G S B model [params]
        if len(toks) < 7:
            return None
        return Element(
            prefix="m",
            name=name,
            nodes=toks[1:5],
            model=toks[5],
            params=_parse_params(toks, 6),
        )

    if prefix == "q":
        # Q name C B E [S] model [params]
        if len(toks) < 5:
            return None
        node_end = 1
        while node_end < len(toks):
            if "=" in toks[node_end]:
                break
            node_end += 1
        if node_end < 3:
            return None
        model_idx = node_end - 1
        return Element(
            prefix="q",
            name=name,
            nodes=toks[1:model_idx],
            model=toks[model_idx],
            params=_parse_params(toks, node_end),
        )

    if prefix == "j":
        # J name D G S model [params]
        if len(toks) < 5:
            return None
        return Element(
            prefix="j",
            name=name,
            nodes=toks[1:4],
            model=toks[4],
            params=_parse_params(toks, 5),
        )

    if prefix in ("v", "i"):
        if len(toks) < 3:
            return None
        return Element(
            prefix=prefix,
            name=name,
            nodes=toks[1:3],
            value=toks[3] if len(toks) > 3 else None,
        )

    if prefix in ("e", "g"):
        # E/G: name n+ n- nc+ nc- gain
        if len(toks) < 6:
            return None
        return Element(
            prefix=prefix,
            name=name,
            nodes=toks[1:5],
            value=toks[5],
        )

    if prefix in ("f", "h"):
        # F/H: name n+ n- vname gain
        if len(toks) < 5:
            return None
        return Element(
            prefix=prefix,
            name=name,
            nodes=toks[1:3],
            value=toks[4],
            model=toks[3],  # vname
        )

    if prefix == "b":
        # B: name n+ n- V={expr}|I={expr}
        if len(toks) < 4:
            return None
        return Element(
            prefix="b",
            name=name,
            nodes=toks[1:3],
            value=toks[3],
        )

    if prefix == "x":
        # X name node... subckt_name [key=val...]
        if len(toks) < 3:
            return None
        param_start = len(toks)
        for i, tok in enumerate(toks[1:], 1):
            if "=" in tok:
                param_start = i
                break
        subckt_idx = param_start - 1
        if subckt_idx < 1:
            return None
        return Element(
            prefix="x",
            name=name,
            nodes=toks[1:subckt_idx],
            model=toks[subckt_idx],
            params=_parse_params(toks, param_start),
        )

    return None


def _raw_tail(line: str, cmd_len: int) -> str:
    if len(line) <= cmd_len:
        return ""
    return line[cmd_len:].strip()


def _parse_measure(toks: list[str]) -> Optional[Measure]:
    if not toks:
        return None
    first_lo = toks[0][0].lower()
    name_idx = 0
    if first_lo in ("t", "a", "d") and len(toks[0]) <= 5:
        name_idx = 1
    if name_idx >= len(toks):
        return None
    name = toks[name_idx]
    expr = " ".join(toks[name_idx + 1 :])
    return Measure(name=name, expr=expr)


def parse(source: str) -> Netlist:
    """Parse an ngspice netlist string into a Netlist object."""
    # Step 1: join continuation lines, strip comments
    logical: list[str] = []
    pending = ""
    first = True

    for raw in source.split("\n"):
        line = raw.rstrip("\r \t")
        line = _trim_comment(line)

        if first:
            first = False
            if line and line[0] == "*":
                logical.append(line[1:].strip())
                continue
            lo_line = line.lower()
            if lo_line.startswith(".title"):
                logical.append(line[6:].strip())
                continue
            logical.append("")
            # fall through to process this line

        trimmed = line.strip()
        if not trimmed or trimmed[0] == "*":
            continue

        if trimmed[0] == "+":
            rest = trimmed[1:].strip()
            if rest:
                pending += " " + rest
        else:
            if pending:
                logical.append(pending)
            pending = trimmed

    if pending:
        logical.append(pending)

    # Step 2: parse logical lines
    title = logical[0] if logical else ""

    netlist = Netlist(title=title)
    in_subckt = False
    in_control = False
    sc_name = ""
    sc_ports: list[str] = []
    sc_elems: list[Element] = []
    sc_params: list[Param] = []
    control_lines: list[str] = []

    for line in logical[1:]:
        lo0 = line[0].lower()

        # .control block
        if in_control:
            if line.lower().startswith(".endc"):
                in_control = False
            else:
                control_lines.append(line)
            continue

        if lo0 == ".":
            toks = _tokenize(line)
            cmd = toks[0].lower()

            if cmd == ".subckt":
                if len(toks) >= 2:
                    in_subckt = True
                    sc_name = toks[1]
                    sc_ports = []
                    sc_elems = []
                    sc_params = []
                    for tok in toks[2:]:
                        if "=" in tok:
                            eq = tok.index("=")
                            sc_params.append(Param(key=tok[:eq], val=tok[eq + 1 :]))
                        else:
                            sc_ports.append(tok)

            elif cmd == ".ends":
                if in_subckt:
                    netlist.subckts.append(
                        Subckt(
                            name=sc_name,
                            ports=sc_ports,
                            elements=sc_elems,
                            params=sc_params,
                        )
                    )
                    in_subckt = False

            elif cmd == ".model":
                if len(toks) >= 3:
                    netlist.models.append(Model(name=toks[1], kind=toks[2]))

            elif cmd == ".param":
                netlist.params.extend(_parse_params(toks, 1))

            elif cmd == ".global":
                netlist.globals.extend(toks[1:])

            elif cmd == ".op":
                netlist.analyses.append(Analysis(kind=AnalysisKind.OP, raw=""))

            elif cmd == ".dc":
                netlist.analyses.append(
                    Analysis(kind=AnalysisKind.DC, raw=_raw_tail(line, 3))
                )

            elif cmd == ".ac":
                netlist.analyses.append(
                    Analysis(kind=AnalysisKind.AC, raw=_raw_tail(line, 3))
                )

            elif cmd == ".tran":
                netlist.analyses.append(
                    Analysis(kind=AnalysisKind.TRAN, raw=_raw_tail(line, 5))
                )

            elif cmd == ".noise":
                netlist.analyses.append(
                    Analysis(kind=AnalysisKind.NOISE, raw=_raw_tail(line, 6))
                )

            elif cmd == ".tf":
                netlist.analyses.append(
                    Analysis(kind=AnalysisKind.TF, raw=_raw_tail(line, 3))
                )

            elif cmd in (".measure", ".meas"):
                m = _parse_measure(toks[1:])
                if m:
                    netlist.measures.append(m)

            elif cmd == ".control":
                in_control = True

            elif cmd == ".end":
                break

        else:
            elem = _parse_element(line)
            if elem:
                if in_subckt:
                    sc_elems.append(elem)
                else:
                    netlist.top_elements.append(elem)

    if control_lines:
        netlist.control_block = "\n".join(control_lines) + "\n"

    return netlist
