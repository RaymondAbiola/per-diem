// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PerDiem} from "../src/PerDiem.sol";

/// Burns a requested amount of gas so tests can exercise real measurement rather
/// than a trivial call.
contract Burner {
    uint256 public slot;

    function burn(uint256 iterations) external payable {
        for (uint256 i = 0; i < iterations; i++) {
            slot = slot + i + 1;
        }
    }

    function boom() external payable {
        revert("nope");
    }

    receive() external payable {}
}

/// Acts as the agent, then tries to re-enter execute from the callback the outer
/// execute triggers on it.
contract Reenterer {
    PerDiem cap;
    bool armed;

    constructor(PerDiem cap_) {
        cap = cap_;
    }

    function attack() external payable {
        armed = true;
        cap.execute(address(this), 0, "");
    }

    receive() external payable {
        if (armed) {
            armed = false;
            cap.execute(address(this), 0, "");
        }
    }
}

contract PerDiemTest is Test {
    /// Arc's protocol floor, and where mainnet actually sits.
    uint256 constant ARC_GAS_PRICE = 20 gwei;

    /// $1.00 in 18 decimal native units.
    uint256 constant ONE_DOLLAR = 1e18;

    PerDiem cap;
    Burner burner;
    address owner = address(0xA11CE);
    address agent = address(0xB0B);

    function setUp() public {
        vm.txGasPrice(ARC_GAS_PRICE);
        burner = new Burner();
        vm.prank(owner);
        // $5 per 24h window, 30k tail gas as a placeholder until mainnet calibration
        cap = new PerDiem(agent, 5 * ONE_DOLLAR, 86_400, 30_000, 200 gwei);
        vm.deal(address(cap), 100 * ONE_DOLLAR);
        vm.deal(agent, 1 * ONE_DOLLAR);
    }

    // --- the premise ---

    function test_gasCostLandsInRealDollarRange() public {
        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (50)));

        uint256 spent = cap.spentInWindow(cap.currentWindow());
        assertGt(spent, 0, "execution must cost something");

        // At 20 gwei, a call in this size class is worth fractions of a cent.
        // Assert the magnitude, not just that it is nonzero.
        assertLt(spent, 0.01e18, "a small call must cost well under a cent");
        assertGt(spent, 0.0001e18, "but more than a hundredth of a cent");

        console.log("gas cost, micro-USDC:", cap.usdMicro(spent));
    }

    function test_gasAloneCountsAsSpend() public {
        // value is zero, so anything debited is pure execution cost
        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (10)));
        assertGt(cap.spentInWindow(cap.currentWindow()), 0);
    }

    function test_biggerCallCostsStrictlyMore() public {
        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (5)));
        uint256 cheap = cap.spentInWindow(cap.currentWindow());

        vm.warp(block.timestamp + 86_400);
        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (200)));
        uint256 dear = cap.spentInWindow(cap.currentWindow());

        assertGt(dear, cheap, "more work must cost more");
    }

    // --- enforcement ---

    function test_capBindsOnValue() public {
        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(burner), 6 * ONE_DOLLAR, "");
    }

    function test_capBindsOnGasEvenWhenValueFits() public {
        vm.prank(owner);
        cap.setBudget(0.0005e18, 86_400); // budget smaller than one call's gas

        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (100)));
    }

    function test_capStopsAgentAfterRepeatedCalls() public {
        vm.prank(owner);
        cap.setBudget(0.02e18, 86_400); // room for a handful of calls

        uint256 completed;
        for (uint256 i = 0; i < 500; i++) {
            vm.prank(agent);
            (bool ok,) = address(cap).call(
                abi.encodeCall(PerDiem.execute, (address(burner), 0, abi.encodeCall(Burner.burn, (20))))
            );
            if (!ok) break;
            completed++;
        }

        assertGt(completed, 0, "some calls must land");
        assertLt(completed, 500, "the cap must eventually stop the agent");
        assertLe(cap.spentInWindow(cap.currentWindow()), 0.02e18, "never exceeds budget");
        console.log("calls before the cap bound:", completed);
    }

    function test_windowResetsBudget() public {
        vm.prank(owner);
        cap.setBudget(0.005e18, 86_400);

        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (20)));
        uint256 firstWindow = cap.currentWindow();
        assertGt(cap.spentInWindow(firstWindow), 0);

        vm.warp(block.timestamp + 86_400);
        assertTrue(cap.currentWindow() > firstWindow, "window must roll");
        assertEq(cap.spentInWindow(cap.currentWindow()), 0, "fresh window starts empty");
        assertEq(cap.remaining(), 0.005e18);
    }

    function test_spendNeverExceedsBudgetInvariant() public {
        vm.prank(owner);
        cap.setBudget(0.01e18, 86_400);

        for (uint256 i = 0; i < 200; i++) {
            vm.prank(agent);
            (bool ignored,) = address(cap).call(
                abi.encodeCall(PerDiem.execute, (address(burner), 0, abi.encodeCall(Burner.burn, (15))))
            );
            ignored;
            assertLe(cap.spentInWindow(cap.currentWindow()), 0.01e18);
        }
    }

    // --- reimbursement ---

    function test_agentIsReimbursedExactlyTheMeteredCost() public {
        uint256 before = agent.balance;

        vm.prank(agent);
        cap.execute(address(burner), 0, abi.encodeCall(Burner.burn, (40)));

        uint256 metered = cap.spentInWindow(cap.currentWindow());
        assertEq(agent.balance - before, metered, "reimbursement must equal what was debited");
    }

    function test_valueReachesTargetAndIsCharged() public {
        uint256 before = address(burner).balance;

        vm.prank(agent);
        cap.execute(address(burner), 1 * ONE_DOLLAR, abi.encodeCall(Burner.burn, (5)));

        assertEq(address(burner).balance - before, 1 * ONE_DOLLAR, "value must arrive");
        assertGt(cap.spentInWindow(cap.currentWindow()), 1 * ONE_DOLLAR, "charged value plus gas");
    }

    // --- access control and safety ---

    function test_onlyAgentCanExecute() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(PerDiem.NotAgent.selector);
        cap.execute(address(burner), 0, "");
    }

    function test_onlyOwnerCanSetBudget() public {
        vm.prank(agent);
        vm.expectRevert(PerDiem.NotOwner.selector);
        cap.setBudget(1, 1);
    }

    function test_reentrancyBlocked() public {
        Reenterer r = new Reenterer(cap);
        vm.prank(owner);
        cap.setAgent(address(r));
        vm.expectRevert();
        r.attack();
    }

    function test_failedCallRevertsWholeTx() public {
        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(burner), 0, abi.encodeCall(Burner.boom, ()));
        assertEq(cap.spentInWindow(cap.currentWindow()), 0, "nothing debited on failure");
    }

    function test_zeroWindowRejected() public {
        vm.prank(owner);
        vm.expectRevert(PerDiem.ZeroWindow.selector);
        cap.setBudget(1e18, 0);
    }

    // --- decimals ---

    function test_usdMicroCrossesTheDecimalGap() public view {
        // $1 native (18dp) is 1_000_000 micro-USDC (6dp)
        assertEq(cap.usdMicro(1e18), 1_000_000);
        // a tenth of a cent
        assertEq(cap.usdMicro(0.001e18), 1_000);
        // 420 micro-USDC, the real cost of a bare Arc transfer at 20 gwei
        assertEq(cap.usdMicro(21_000 * ARC_GAS_PRICE), 420);
    }

    function test_bareTransferCostMatchesArcDocs() public pure {
        // Arc documents roughly $0.001 for an ERC-20 transfer. Check our unit math
        // against that, in native 18dp.
        uint256 erc20TransferCost = 65_000 * ARC_GAS_PRICE;
        assertApproxEqRel(erc20TransferCost, 0.0013e18, 0.01e18);
    }
}
