"""Run all project testbenches and report results."""
import traceback

tests = [
    ("Comparator DC",        "from project.sar_adc import ComparatorDCTB as T"),
    ("Comparator Transient", "from project.sar_adc import ComparatorTransientTB as T"),
    ("CapDAC Static",        "from project.sar_adc import CapDAC4BitStaticTB as T"),
    ("SAR ADC Ramp",         "from project.sar_adc import SARADC4BitRampTB as T"),
    ("SAR ADC Dynamic",      "from project.sar_adc import SARADC4BitDynamicTB as T"),
    ("ChargeDAC Static",     "from project.charge_dac import ChargeDACStaticTB as T"),
    ("ChargeDAC Dynamic",    "from project.charge_dac import ChargeDACDynamicTB as T"),
    ("ChargeDAC AllCodes",   "from project.charge_dac import ChargeDACAllCodesTB as T"),
    ("MAC Cell",             "from project.charge_imc import ChargeMACCellTB as T"),
    ("IMC Identity",         "from project.charge_imc import ChargeIMC4x4IdentityTB as T"),
    ("IMC MVM",              "from project.charge_imc import ChargeIMC4x4MVMTB as T"),
    ("IMC Linearity",        "from project.charge_imc import ChargeIMC4x4LinearityTB as T"),
    ("System DAC-ADC",       "from project.system_tb import SystemDACtoADCTB as T"),
    ("System Full Pipe",     "from project.system_tb import SystemFullPipeTB as T"),
    ("GEMM Tile FP4",        "from project.gemm_tb import GEMMTileFP4TB as T"),
    ("Sample-Hold Bank",     "from project.gemm_tb import SampleHoldBankTB as T"),
    ("GEMM Store Pipe",      "from project.gemm_tb import GEMMStorePipeTB as T"),
    ("GEMM Full 4x4",        "from project.gemm_tb import GEMMFullTB as T"),
]

SEP = "=" * 60
results = []

for name, import_stmt in tests:
    print(f"\n{SEP}")
    print(f"  {name}")
    print(SEP)
    try:
        ns = {}
        exec(import_stmt, ns)
        tb = ns["T"]()
        result = tb.run()
        if hasattr(tb, "characterize"):
            specs = tb.characterize(result)
            for k, v in specs.items():
                if isinstance(v, list) and len(v) > 8:
                    print(f"  {k}: [{v[0]:.4g}, ..., {v[-1]:.4g}] ({len(v)} items)")
                elif isinstance(v, float):
                    print(f"  {k}: {v:.6g}")
                else:
                    print(f"  {k}: {v}")
        tb.assertions(result)
        print("  >>> PASS")
        results.append((name, "PASS"))
    except Exception as e:
        print(f"  >>> FAIL: {e}")
        traceback.print_exc()
        results.append((name, f"FAIL: {e}"))

print(f"\n\n{SEP}")
print("  SUMMARY")
print(SEP)
for name, status in results:
    print(f"  {name:25s} {status}")
passed = sum(1 for _, s in results if s == "PASS")
print(f"\n  {passed}/{len(results)} passed")
