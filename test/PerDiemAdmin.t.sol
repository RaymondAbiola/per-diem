// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PerDiem} from "../src/PerDiem.sol";

contract Work {
    uint256 public slot;

    function burn(uint256 n) external payable {
        for (uint256 i = 0; i < n; i++) {
            slot = slot + i + 1;
        }
    }

    receive() external payable {}
}

contract Refuser {
// no receive, no fallback
}

/// Covers the owner controls and guards the main suite leaves untouched.
contract PerDiemAdminTest is Test {
    uint256 constant ARC_GAS_PRICE = 20 gwei;
    uint256 constant CEILING = 200 gwei;

    PerDiem cap;
    Work work;
    address owner = address(0xA11CE);
    address agent = address(0xB0B);

    function setUp() public {
        vm.txGasPrice(ARC_GAS_PRICE);
        work = new Work();
        vm.prank(owner);
        cap = new PerDiem(agent, 5e18, 86_400, 0, CEILING);
        vm.deal(address(cap), 50e18);
        vm.deal(agent, 1e18);
    }

    // --- tailGas ---

    /// Isolating tailGas means every other variable has to be warm already: a cold
    /// SSTORE in the target or in spentInWindow swamps the difference otherwise.
    function test_tailGasIncreasesBilledCost() public {
        uint256 w = cap.currentWindow();
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agent);
            cap.execute(address(work), 0, abi.encodeCall(Work.burn, (20)));
        }

        uint256 a0 = cap.spentInWindow(w);
        vm.prank(agent);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (20)));
        uint256 costWithoutTail = cap.spentInWindow(w) - a0;

        vm.prank(owner);
        cap.calibrateTailGas(50_000);

        uint256 a1 = cap.spentInWindow(w);
        vm.prank(agent);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (20)));
        uint256 costWithTail = cap.spentInWindow(w) - a1;

        assertGt(costWithTail, costWithoutTail, "tailGas must raise what a call is billed");
        assertEq(
            costWithTail - costWithoutTail,
            50_000 * ARC_GAS_PRICE,
            "the only difference is tailGas * gasprice"
        );
    }

    function test_calibrateTailGasEmits() public {
        vm.expectEmit(false, false, false, true);
        emit PerDiem.TailGasCalibrated(31_337);
        vm.prank(owner);
        cap.calibrateTailGas(31_337);
        assertEq(cap.tailGas(), 31_337);
    }

    function test_onlyOwnerCalibrates() public {
        vm.prank(agent);
        vm.expectRevert(PerDiem.NotOwner.selector);
        cap.calibrateTailGas(1);
    }

    // --- gas price ceiling ---

    function test_gasPriceAboveCeilingReverts() public {
        vm.txGasPrice(CEILING + 1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(PerDiem.GasPriceTooHigh.selector, CEILING + 1, CEILING)
        );
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
    }

    function test_gasPriceAtCeilingIsAllowed() public {
        vm.txGasPrice(CEILING);
        vm.prank(agent);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
        assertGt(cap.spentInWindow(cap.currentWindow()), 0);
    }

    /// The ceiling is what bounds how fast the agent can drain a window.
    function test_ceilingBoundsWorstCaseBurnRate() public {
        vm.prank(owner);
        cap.setMaxGasPrice(ARC_GAS_PRICE); // pin to the floor
        vm.txGasPrice(ARC_GAS_PRICE * 10);
        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
    }

    function test_setMaxGasPriceEmitsAndOnlyOwner() public {
        vm.expectEmit(false, false, false, true);
        emit PerDiem.MaxGasPriceSet(123 gwei);
        vm.prank(owner);
        cap.setMaxGasPrice(123 gwei);
        assertEq(cap.maxGasPrice(), 123 gwei);

        vm.prank(agent);
        vm.expectRevert(PerDiem.NotOwner.selector);
        cap.setMaxGasPrice(1);
    }

    // --- agent rotation ---

    function test_setAgentMovesAuthority() public {
        address next = address(0xC0DE);
        vm.deal(next, 1e18);

        vm.expectEmit(true, false, false, false);
        emit PerDiem.AgentSet(next);
        vm.prank(owner);
        cap.setAgent(next);

        vm.prank(agent);
        vm.expectRevert(PerDiem.NotAgent.selector);
        cap.execute(address(work), 0, "");

        vm.prank(next);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
        assertGt(cap.spentInWindow(cap.currentWindow()), 0);
    }

    function test_onlyOwnerSetsAgent() public {
        vm.prank(agent);
        vm.expectRevert(PerDiem.NotOwner.selector);
        cap.setAgent(address(0xC0DE));
    }

    // --- funding and withdrawal ---

    function test_receiveEmitsFunded() public {
        vm.deal(owner, 3e18);
        vm.expectEmit(true, false, false, true);
        emit PerDiem.Funded(owner, 2e18);
        vm.prank(owner);
        (bool ok,) = address(cap).call{value: 2e18}("");
        assertTrue(ok);
    }

    function test_ownerCanWithdraw() public {
        uint256 before = owner.balance;
        vm.prank(owner);
        cap.withdraw(owner, 10e18);
        assertEq(owner.balance - before, 10e18);
    }

    function test_withdrawEmits() public {
        vm.expectEmit(true, false, false, true);
        emit PerDiem.Withdrawn(owner, 1e18);
        vm.prank(owner);
        cap.withdraw(owner, 1e18);
    }

    function test_agentCannotWithdraw() public {
        vm.prank(agent);
        vm.expectRevert(PerDiem.NotOwner.selector);
        cap.withdraw(agent, 1e18);
    }

    /// The whole point of two keys: the agent's only route to the money is execute(),
    /// and that route is capped.
    function test_agentCannotDrainBeyondTheCap() public {
        vm.prank(owner);
        cap.setBudget(0.01e18, 86_400);

        for (uint256 i = 0; i < 300; i++) {
            vm.prank(agent);
            (bool ok,) = address(cap).call(
                abi.encodeCall(PerDiem.execute, (address(work), 0, abi.encodeCall(Work.burn, (10))))
            );
            if (!ok) break;
        }
        assertLe(cap.spentInWindow(cap.currentWindow()), 0.01e18);
    }

    function test_withdrawToRefuserReverts() public {
        address refuser = address(new Refuser());
        vm.prank(owner);
        vm.expectRevert(PerDiem.ReimbursementFailed.selector);
        cap.withdraw(refuser, 1e18);
    }

    function test_constructorRejectsZeroWindow() public {
        vm.expectRevert(PerDiem.ZeroWindow.selector);
        new PerDiem(agent, 1e18, 0, 0, CEILING);
    }

    /// A contract agent with no way to receive value can never be reimbursed, so it
    /// can never use the cap at all. Worth knowing before someone wires one up.
    function test_agentThatCannotBePaidIsUnusable() public {
        address refuser = address(new Refuser());
        vm.prank(owner);
        cap.setAgent(refuser);

        vm.prank(refuser);
        vm.expectRevert(PerDiem.ReimbursementFailed.selector);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
    }

    /// An exhausted window still reports the dust that no call can fit into, which is
    /// correct: the cap never partially executes. The clamp matters when the owner
    /// tightens the budget below what has already gone out this window.
    function test_remainingLeavesDustRatherThanZero() public {
        vm.prank(owner);
        cap.setBudget(0.004e18, 86_400);

        uint256 landed;
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(agent);
            (bool ok,) = address(cap).call(
                abi.encodeCall(PerDiem.execute, (address(work), 0, abi.encodeCall(Work.burn, (5))))
            );
            if (!ok) break;
            landed++;
        }
        assertGt(landed, 0);
        uint256 dust = cap.remaining();
        assertGt(dust, 0, "budget left over, just not enough for another call");
        assertLt(dust, 0.004e18);
    }

    function test_remainingClampsToZeroIfBudgetCutBelowSpend() public {
        vm.prank(agent);
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (20)));
        uint256 spent = cap.spentInWindow(cap.currentWindow());
        assertGt(spent, 0);

        vm.prank(owner);
        cap.setBudget(spent / 2, 86_400);

        assertEq(cap.remaining(), 0, "clamps rather than underflowing");

        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(work), 0, abi.encodeCall(Work.burn, (1)));
    }
}
