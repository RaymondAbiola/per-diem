// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PerDiem
/// @notice A dollar-denominated spending cap that counts execution cost as spend.
///
/// On any other EVM chain this contract cannot exist. Gas is paid in a volatile
/// native token, so a contract has no trustless way to price its own execution in
/// dollars and has to defer to an oracle. On Arc the gas token is USDC, so
/// gasUsed * tx.gasprice is already a dollar amount, and one USDC budget can cover
/// both the value a call moves and the cost of making it.
///
/// Accounting is in 18 decimal native units, which is how Arc denominates msg.value
/// and tx.gasprice. The ERC-20 view of the same balance uses 6 decimals. Divide by
/// 1e12 to cross between them, or read usdMicro().
contract PerDiem {
    uint256 private constant NATIVE_TO_USDC = 1e12;

    /// Intrinsic cost of a transaction, charged before any contract code runs.
    uint256 private constant INTRINSIC_GAS = 21_000;

    /// EIP-2028 prices a zero calldata byte at 4 and a nonzero one at 16. We charge
    /// every byte at the zero rate, so this is a floor and can only under-reimburse.
    /// That also closes the padding arbitrage from the safe side: an agent can no
    /// longer be paid 16 for a byte that cost it 4.
    ///
    /// Walking the bytes to price them exactly cost 94,679 gas against a worst case
    /// error of 792, measured on an Arc mainnet fork. Paying 120x the error to correct
    /// it is not a trade worth making.
    uint256 private constant CALLDATA_GAS_FLOOR = 4;

    address public owner;
    address public agent;

    /// Budget per window, in 18 decimal native units.
    uint256 public budgetPerWindow;

    /// Tumbling window length in seconds. Windows do not slide; the counter resets
    /// at each boundary.
    uint64 public windowLength;

    /// Gas consumed after the last measurement point in execute: the storage write,
    /// the reimbursement transfer and the event. Calibrated on mainnet, not assumed.
    uint256 public tailGas;

    /// Reimbursement is priced at tx.gasprice, which the agent chooses. It cannot
    /// profit from a high price since it paid that price, but it can burn the budget
    /// fast. This bounds how fast.
    uint256 public maxGasPrice;

    mapping(uint256 => uint256) public spentInWindow;

    uint256 private _locked = 1;

    event Spent(
        address indexed target,
        uint256 value,
        uint256 gasCost,
        uint256 windowSpent,
        uint256 windowRemaining
    );
    event AgentSet(address indexed agent);
    event BudgetSet(uint256 budgetPerWindow, uint64 windowLength);
    event TailGasCalibrated(uint256 tailGas);
    event MaxGasPriceSet(uint256 maxGasPrice);
    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error NotOwner();
    error NotAgent();
    error Reentrant();
    error CapExceeded(uint256 attempted, uint256 remaining);
    error CallFailed(bytes ret);
    error ReimbursementFailed();
    error ZeroWindow();
    error GasPriceTooHigh(uint256 offered, uint256 max);

    constructor(
        address agent_,
        uint256 budgetPerWindow_,
        uint64 windowLength_,
        uint256 tailGas_,
        uint256 maxGasPrice_
    ) {
        if (windowLength_ == 0) revert ZeroWindow();
        owner = msg.sender;
        agent = agent_;
        budgetPerWindow = budgetPerWindow_;
        windowLength = windowLength_;
        tailGas = tailGas_;
        maxGasPrice = maxGasPrice_;
        emit AgentSet(agent_);
        emit BudgetSet(budgetPerWindow_, windowLength_);
        emit TailGasCalibrated(tailGas_);
        emit MaxGasPriceSet(maxGasPrice_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Make a call on the agent's behalf, charging value and execution cost
    /// to the same window budget.
    /// @dev The budget check lands after the call, which is sound because a revert
    /// unwinds the value transfer with it. A failed check costs the agent the gas of
    /// the attempt with no reimbursement.
    function execute(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory ret)
    {
        uint256 gasAtEntry = gasleft();
        if (msg.sender != agent) revert NotAgent();
        if (tx.gasprice > maxGasPrice) revert GasPriceTooHigh(tx.gasprice, maxGasPrice);
        if (_locked != 1) revert Reentrant();
        _locked = 2;

        uint256 window = currentWindow();
        uint256 already = spentInWindow[window];

        // Cheap guard on the value leg before anything moves.
        if (already + value > budgetPerWindow) {
            revert CapExceeded(already + value, budgetPerWindow - already);
        }

        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);

        uint256 gasCost = _gasCost(gasAtEntry);
        uint256 total = value + gasCost;
        if (already + total > budgetPerWindow) {
            revert CapExceeded(already + total, budgetPerWindow - already);
        }

        uint256 spent = already + total;
        spentInWindow[window] = spent;

        // Reimburse the gas the agent fronted, so both legs leave one pot. This is
        // what makes the measurement load bearing: over-measure and the contract
        // bleeds, under-measure and the agent's float drains.
        (bool paid,) = msg.sender.call{value: gasCost}("");
        if (!paid) revert ReimbursementFailed();

        emit Spent(target, value, gasCost, spent, budgetPerWindow - spent);
        _locked = 1;
    }

    /// @dev Cost in 18 decimal native units of the transaction so far, plus the parts
    /// that cannot be observed from in here. The intrinsic charge and the calldata
    /// cost are both incurred before this contract gets control, and tailGas covers
    /// the work left after this point. Pricing every calldata byte at the nonzero rate
    /// overstates the real cost slightly, which makes the cap bind marginally early.
    /// For a spend limit that is the safe direction to be wrong in.
    function _gasCost(uint256 gasAtEntry) internal view returns (uint256) {
        uint256 measured = gasAtEntry - gasleft();
        uint256 unobservable =
            INTRINSIC_GAS + CALLDATA_GAS_FLOOR * msg.data.length + tailGas;
        return (measured + unobservable) * tx.gasprice;
    }

    function currentWindow() public view returns (uint256) {
        return block.timestamp / windowLength;
    }

    function remaining() external view returns (uint256) {
        uint256 spent = spentInWindow[currentWindow()];
        return spent >= budgetPerWindow ? 0 : budgetPerWindow - spent;
    }

    /// @notice The 6 decimal USDC view of an 18 decimal native amount.
    function usdMicro(uint256 nativeAmount) external pure returns (uint256) {
        return nativeAmount / NATIVE_TO_USDC;
    }

    function setAgent(address agent_) external onlyOwner {
        agent = agent_;
        emit AgentSet(agent_);
    }

    function setBudget(uint256 budgetPerWindow_, uint64 windowLength_) external onlyOwner {
        if (windowLength_ == 0) revert ZeroWindow();
        budgetPerWindow = budgetPerWindow_;
        windowLength = windowLength_;
        emit BudgetSet(budgetPerWindow_, windowLength_);
    }

    function setMaxGasPrice(uint256 maxGasPrice_) external onlyOwner {
        maxGasPrice = maxGasPrice_;
        emit MaxGasPriceSet(maxGasPrice_);
    }

    function calibrateTailGas(uint256 tailGas_) external onlyOwner {
        tailGas = tailGas_;
        emit TailGasCalibrated(tailGas_);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ReimbursementFailed();
        emit Withdrawn(to, amount);
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }
}
