#!/usr/bin/env python3
"""Report the agent's float drift in gas units.

Reads lines of "gasUsed effectiveGasPrice billedGas" and compares what the contract
reimbursed against what the transaction actually cost. Gas units, not dollars: Arc's
fee market moves and tailGas is denominated in gas, so a dollar figure would mix the
metering error up with the gas price.

usage: analyze_drift.py <log> <tailGas> <windowSeconds> <serviceCallsDelta>
"""

import sys

GREEN = "\033[32m"
YELLOW = "\033[33m"
RESET = "\033[0m"

# A warm call is this consistent on Arc, so anything under it is noise not bias.
TOLERANCE_GAS = 50


def main() -> int:
    log, tail, window, served = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

    rows = []
    with open(log) as fh:
        for line in fh:
            if line.strip():
                rows.append(tuple(int(x) for x in line.split()))

    if not rows:
        print("  no calls landed")
        return 1

    print(f"  calls landed        {len(rows)}")
    verdict = "match" if served == len(rows) else "MISMATCH"
    print(f"  service recorded    {served}  {verdict}")

    prices = {eff for _, eff, _ in rows}
    print(f"  gas price range     {min(prices) / 1e9:.2f} to {max(prices) / 1e9:.2f} gwei")
    print()

    header = "#".ljust(5) + "gasUsed".rjust(9) + "billed".rjust(9) + "drift".rjust(9)
    print("  " + header)

    drifts = []
    for i, (gas_used, _eff, billed) in enumerate(rows, 1):
        drift = billed - gas_used
        drifts.append(drift)
        if i <= 3 or i == len(rows):
            print(f"  {str(i).ljust(5)}{gas_used:>9,}{billed:>9,}{drift:>+9,}")
        elif i == 4:
            print("  " + "...".ljust(5))

    warm = drifts[1:] or drifts
    mean = sum(warm) // len(warm)

    print()
    print(f"  cold call drift     {drifts[0]:+,} gas")
    print(f"  warm call drift     min {min(warm):+,}  max {max(warm):+,}  mean {mean:+,} gas")
    print()

    if abs(mean) <= TOLERANCE_GAS:
        print(f"  {GREEN}FLOAT HELD{RESET}  mean warm drift {mean:+,} gas.")
        print("  The agent neither subsidises the gas nor profits from it.")
    elif mean > 0:
        print(f"  {YELLOW}OVER-REIMBURSING{RESET} {mean:,} gas/call. Set tailGas to {tail - mean:,}.")
    else:
        print(f"  {YELLOW}UNDER-REIMBURSING{RESET} {-mean:,} gas/call. Set tailGas to {tail - mean:,}.")

    if drifts[0] < 0:
        print()
        print(
            f"  the cold call costs the agent {-drifts[0]:,} gas, "
            f"once per {window // 3600}h window"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
