// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PaidService} from "../src/PaidService.sol";

contract Refuser {
    // no receive, no fallback: cannot be paid
}

contract PaidServiceTest is Test {
    uint256 constant ARC_GAS_PRICE = 20 gwei;
    uint256 constant PRICE = 0.002e18; // $0.002, the deployed value

    PaidService svc;
    address beneficiary = address(0xBEEF);
    address caller = address(0xCA11);

    function setUp() public {
        vm.txGasPrice(ARC_GAS_PRICE);
        svc = new PaidService(PRICE, beneficiary);
        vm.deal(caller, 10e18);
    }

    function test_immutablesAreSet() public view {
        assertEq(svc.pricePerCall(), PRICE);
        assertEq(svc.beneficiary(), beneficiary);
    }

    function test_startsEmpty() public view {
        assertEq(svc.callsServed(), 0);
        assertEq(svc.revenueCollected(), 0);
        assertEq(svc.callsBy(caller), 0);
    }

    function test_exactPaymentIsServed() public {
        vm.prank(caller);
        bytes32 r = svc.query{value: PRICE}(keccak256("in"));

        assertTrue(r != bytes32(0), "must return a result");
        assertEq(svc.callsServed(), 1);
        assertEq(svc.revenueCollected(), PRICE);
        assertEq(svc.callsBy(caller), 1);
        assertEq(address(svc).balance, PRICE);
    }

    function test_underpaymentReverts() public {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PaidService.Underpaid.selector, PRICE - 1, PRICE));
        svc.query{value: PRICE - 1}(keccak256("in"));
    }

    function test_zeroPaymentReverts() public {
        vm.prank(caller);
        vm.expectRevert();
        svc.query{value: 0}(keccak256("in"));
    }

    function test_overpaymentIsAcceptedAndCounted() public {
        vm.prank(caller);
        svc.query{value: PRICE * 3}(keccak256("in"));
        assertEq(svc.revenueCollected(), PRICE * 3, "revenue tracks what was actually sent");
        assertEq(svc.callsServed(), 1, "still one call");
    }

    function test_perCallerTallyIsSeparate() public {
        address other = address(0xD00D);
        vm.deal(other, 1e18);

        vm.prank(caller);
        svc.query{value: PRICE}(keccak256("a"));
        vm.prank(caller);
        svc.query{value: PRICE}(keccak256("b"));
        vm.prank(other);
        svc.query{value: PRICE}(keccak256("c"));

        assertEq(svc.callsBy(caller), 2);
        assertEq(svc.callsBy(other), 1);
        assertEq(svc.callsServed(), 3);
        assertEq(svc.revenueCollected(), PRICE * 3);
    }

    function test_nonceIncrementsAndResultsDiffer() public {
        vm.prank(caller);
        bytes32 a = svc.query{value: PRICE}(keccak256("same"));
        // same input, next nonce: the result must still move
        vm.prank(caller);
        bytes32 b = svc.query{value: PRICE}(keccak256("same"));
        assertTrue(a != b, "result must bind the call nonce, not just the input");
    }

    function test_servedEventCarriesPaymentAndNonce() public {
        vm.expectEmit(true, false, false, false);
        emit PaidService.Served(caller, PRICE, 1, bytes32(0));
        vm.prank(caller);
        svc.query{value: PRICE}(keccak256("in"));
    }

    function test_sweepPaysBeneficiary() public {
        vm.prank(caller);
        svc.query{value: PRICE}(keccak256("in"));

        uint256 before = beneficiary.balance;
        svc.sweep();

        assertEq(beneficiary.balance - before, PRICE, "beneficiary receives the revenue");
        assertEq(address(svc).balance, 0, "contract is drained");
    }

    function test_sweepIsPermissionless() public {
        // anyone may trigger it, but the money can only go to the beneficiary
        vm.prank(caller);
        svc.query{value: PRICE}(keccak256("in"));
        vm.prank(address(0xDEAD));
        svc.sweep();
        assertEq(beneficiary.balance, PRICE);
    }

    function test_sweepOnEmptyIsHarmless() public {
        svc.sweep();
        assertEq(beneficiary.balance, 0);
    }

    function test_sweepRevertsIfBeneficiaryCannotReceive() public {
        PaidService stuck = new PaidService(PRICE, address(new Refuser()));
        vm.prank(caller);
        stuck.query{value: PRICE}(keccak256("in"));

        vm.expectRevert(PaidService.SweepFailed.selector);
        stuck.sweep();
    }

    function test_revenueAccumulatesAcrossManyCalls() public {
        for (uint256 i = 0; i < 25; i++) {
            vm.prank(caller);
            svc.query{value: PRICE}(keccak256(abi.encode(i)));
        }
        assertEq(svc.callsServed(), 25);
        assertEq(svc.revenueCollected(), PRICE * 25);
        assertEq(address(svc).balance, PRICE * 25);
    }

    /// The fee exists so the payload leg is visible next to the gas leg. If it drifts
    /// far from the cost of a call, the demo stops showing the thing it is meant to.
    function test_feeIsComparableToGasCost() public pure {
        uint256 gasCostPerCall = 91_447 * ARC_GAS_PRICE; // measured on an Arc fork
        assertApproxEqRel(PRICE, gasCostPerCall, 0.5e18, "fee should be within 50% of gas");
    }
}
