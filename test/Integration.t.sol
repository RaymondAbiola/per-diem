// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PerDiem} from "../src/PerDiem.sol";
import {PaidService} from "../src/PaidService.sol";

/// The real pairing, exactly as it will be deployed: an agent buying metered calls
/// from a priced service, with one USDC budget covering both the fee and the gas.
/// Every other suite swaps in a throwaway target, so this is the only place the two
/// production contracts are exercised against each other.
contract IntegrationTest is Test {
    uint256 constant ARC_GAS_PRICE = 20 gwei;
    uint256 constant FEE = 0.002e18; // the deployed pricePerCall
    uint256 constant BUDGET = 1e18; // $1 per window, the deployed value

    PerDiem cap;
    PaidService svc;
    address owner = address(0xA11CE);
    address agent = address(0xB0B);

    function setUp() public {
        vm.txGasPrice(ARC_GAS_PRICE);
        vm.startPrank(owner);
        svc = new PaidService(FEE, owner);
        cap = new PerDiem(agent, BUDGET, 86_400, 0, 200 gwei);
        vm.stopPrank();
        vm.deal(address(cap), BUDGET);
        vm.deal(agent, 1e18);
    }

    function _buy(bytes32 input) internal returns (bytes memory) {
        vm.prank(agent);
        return cap.execute(address(svc), FEE, abi.encodeCall(PaidService.query, (input)));
    }

    function test_agentBuysACallThroughTheCap() public {
        _buy(keccak256("q1"));

        assertEq(svc.callsServed(), 1, "service was actually used");
        assertEq(svc.callsBy(address(cap)), 1, "the cap is the caller of record");
        assertEq(svc.revenueCollected(), FEE, "fee arrived");

        uint256 spent = cap.spentInWindow(cap.currentWindow());
        assertGt(spent, FEE, "budget was charged the fee plus the gas to deliver it");
    }

    function test_bothLegsAreChargedToOneBudget() public {
        _buy(keccak256("q1"));
        uint256 spent = cap.spentInWindow(cap.currentWindow());
        uint256 gasLeg = spent - FEE;

        assertGt(gasLeg, 0, "the execution leg is real");
        console.log("payload leg, micro-USDC:", cap.usdMicro(FEE));
        console.log("gas leg,     micro-USDC:", cap.usdMicro(gasLeg));

        // The fee was sized to sit near the gas cost so a dashboard shows both. If this
        // ratio drifts badly the demo stops demonstrating anything.
        assertLt(gasLeg, FEE * 4, "gas should not dwarf the payload");
        assertGt(gasLeg * 4, FEE, "payload should not dwarf the gas");
    }

    function test_agentIsMadeWholeOnGas() public {
        uint256 before = agent.balance;
        _buy(keccak256("q1"));
        uint256 gasLeg = cap.spentInWindow(cap.currentWindow()) - FEE;
        assertEq(agent.balance - before, gasLeg, "agent reimbursed exactly the metered gas");
    }

    /// The economic claim: once the service revenue is swept back, the only thing the
    /// owner is actually out of pocket for is gas.
    function test_ownerNetLossIsGasOnly() public {
        uint256 capBefore = address(cap).balance;

        for (uint256 i = 0; i < 5; i++) {
            _buy(keccak256(abi.encode(i)));
        }

        uint256 spent = cap.spentInWindow(cap.currentWindow());
        uint256 feesPaid = FEE * 5;
        uint256 gasPaid = spent - feesPaid;

        assertEq(capBefore - address(cap).balance, spent, "cap drained by exactly what it billed");

        uint256 ownerBefore = owner.balance;
        svc.sweep();
        assertEq(owner.balance - ownerBefore, feesPaid, "every fee comes back");

        // Net: gas is gone, fees returned.
        console.log("5 calls, gas burned, micro-USDC:", cap.usdMicro(gasPaid));
        console.log("5 calls, fees recovered, micro-USDC:", cap.usdMicro(feesPaid));
    }

    function test_capStopsTheAgentMidStream() public {
        uint256 served;
        for (uint256 i = 0; i < 2000; i++) {
            vm.prank(agent);
            (bool ok,) = address(cap).call(
                abi.encodeCall(
                    PerDiem.execute,
                    (address(svc), FEE, abi.encodeCall(PaidService.query, (keccak256(abi.encode(i)))))
                )
            );
            if (!ok) break;
            served++;
        }

        assertGt(served, 0, "it must work before it stops");
        assertLt(served, 2000, "and it must stop");
        assertEq(svc.callsServed(), served, "the service saw exactly the calls that landed");
        assertLe(cap.spentInWindow(cap.currentWindow()), BUDGET, "never over budget");
        console.log("calls bought on a $1 budget:", served);
    }

    function test_capRefillsNextWindowAndAgentResumes() public {
        vm.prank(owner);
        cap.setBudget(0.01e18, 86_400);

        while (true) {
            vm.prank(agent);
            (bool ok,) = address(cap).call(
                abi.encodeCall(
                    PerDiem.execute, (address(svc), FEE, abi.encodeCall(PaidService.query, (bytes32(0))))
                )
            );
            if (!ok) break;
        }
        uint256 stoppedAt = svc.callsServed();

        vm.warp(block.timestamp + 86_400);
        vm.prank(agent);
        cap.execute(address(svc), FEE, abi.encodeCall(PaidService.query, (bytes32(0))));

        assertEq(svc.callsServed(), stoppedAt + 1, "a fresh window lets the agent continue");
    }

    function test_underpayingTheServiceRevertsTheWholeThing() public {
        vm.prank(agent);
        vm.expectRevert();
        cap.execute(address(svc), FEE - 1, abi.encodeCall(PaidService.query, (bytes32(0))));

        assertEq(svc.callsServed(), 0, "no call served");
        assertEq(cap.spentInWindow(cap.currentWindow()), 0, "and nothing billed");
    }

    function test_serviceResultReachesTheAgent() public {
        bytes memory ret = _buy(keccak256("q1"));
        bytes32 result = abi.decode(ret, (bytes32));
        assertTrue(result != bytes32(0), "execute returns the service's return data");
    }
}
