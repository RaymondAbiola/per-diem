// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PaidService
/// @notice A metered service an agent pays per call, in USDC, on Arc.
///
/// This is the counterparty in the PerDiem demo. It exists so the agent is doing
/// something with a real price attached rather than burning gas for its own sake:
/// an agent buying calls on a budget, where the budget also has to cover the cost
/// of making them.
contract PaidService {
    /// Price per call in 18 decimal native units.
    uint256 public immutable pricePerCall;

    address public immutable beneficiary;

    uint256 public callsServed;
    uint256 public revenueCollected;

    mapping(address => uint256) public callsBy;

    event Served(address indexed caller, uint256 paid, uint256 nonce, bytes32 result);

    error Underpaid(uint256 sent, uint256 required);
    error SweepFailed();

    constructor(uint256 pricePerCall_, address beneficiary_) {
        pricePerCall = pricePerCall_;
        beneficiary = beneficiary_;
    }

    /// @notice Pay for one unit of work. Returns a deterministic result so a caller
    /// can verify it got served rather than taking the event on trust.
    function query(bytes32 input) external payable returns (bytes32 result) {
        if (msg.value < pricePerCall) revert Underpaid(msg.value, pricePerCall);

        callsServed += 1;
        revenueCollected += msg.value;
        callsBy[msg.sender] += 1;

        result = keccak256(abi.encodePacked(input, callsServed, block.number));
        emit Served(msg.sender, msg.value, callsServed, result);
    }

    function sweep() external {
        uint256 amount = address(this).balance;
        (bool ok,) = beneficiary.call{value: amount}("");
        if (!ok) revert SweepFailed();
    }
}
