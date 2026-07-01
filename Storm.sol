// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * STORM Token
 * ------------------------------------------------------------------
 * - MAX_SUPPLY hard-capped at 1,000,000,000 STORM. Half (500,000,000)
 *   is minted to the owner at deploy; the remainder can only be minted
 *   later via mint(), and only up to the cap.
 * - Buy/sell tax (default 5%: 2% burned, 3% to treasury)
 * - Tax only applies on transfers to/from registered AMM pairs
 *   (i.e. actual buys/sells), wallet-to-wallet transfers are free
 * - Anti-whale max-tx / max-wallet limits, floor-protected against
 *   being tightened into a freeze
 * - Same-block anti-bot guard against snipers/sandwich bots
 * - Ownable, with a timelock required on every sensitive owner action
 *   (2 day delay by default) so holders always get advance warning
 *   before a parameter change takes effect. renounceOwnership() is the
 *   one exception and stays immediate, since giving up power needs no
 *   delay.
 *
 * Requires OpenZeppelin Contracts v5.x:
 *   npm install @openzeppelin/contracts
 * ------------------------------------------------------------------
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Storm is ERC20, ERC20Burnable, Ownable {
    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------

    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18; // hard cap, 1B STORM
    uint256 public constant INITIAL_MINT = MAX_SUPPLY / 2;         // 500M minted at deploy

    // Tax expressed in basis points (1% = 100 bps), max enforced at 10% (1000 bps)
    uint256 public burnFeeBps = 200;     // 2%
    uint256 public treasuryFeeBps = 300; // 3%
    uint256 public constant MAX_TOTAL_FEE_BPS = 1000; // 10% hard cap

    address public treasuryWallet;

    // Any address marked as a pair (e.g. Uniswap V2/V3 pool) triggers tax
    // on transfers to/from it. Add your LP pair address after creating it.
    mapping(address => bool) public isAmmPair;

    // Addresses exempt from tax entirely (owner, treasury, contract itself, etc.)
    mapping(address => bool) public isExcludedFromFee;

    // ------------------------------------------------------------------
    // Anti-whale limits
    // ------------------------------------------------------------------

    // Max tokens that can move in a single transfer, and max tokens any
    // one wallet can hold. Both start at 1% of MAX_SUPPLY, a common
    // early-launch setting, and can be raised (never lowered below the
    // floor) by the owner.
    uint256 public maxTxAmount = MAX_SUPPLY / 100;     // 1% of max supply
    uint256 public maxWalletAmount = MAX_SUPPLY / 100; // 1% of max supply

    // Hard floor so limits can never be tightened into a de facto freeze —
    // protects holders from a rug via a sudden near-zero limit.
    uint256 public constant MIN_LIMIT_BPS = 50; // 0.5% of MAX_SUPPLY

    bool public limitsEnabled = true;

    // Addresses exempt from max-tx / max-wallet checks (owner, treasury,
    // AMM pair itself, LP/router contracts, etc.)
    mapping(address => bool) public isExcludedFromLimits;

    // ------------------------------------------------------------------
    // Same-block anti-bot guard
    // ------------------------------------------------------------------

    // Blocks a wallet from buying and selling (or buying twice) within the
    // same block — the classic pattern for sniper/sandwich bots at launch.
    // Tracks the last block a given trader touched the AMM pair, in either
    // direction, and reverts a second trade in that same block.
    bool public sameBlockGuardEnabled = true;
    mapping(address => uint256) public lastTradeBlock;
    mapping(address => bool) public isExcludedFromAntiBot;

    // ------------------------------------------------------------------
    // Timelock
    // ------------------------------------------------------------------

    // Every sensitive owner action must be queued and then wait out this
    // delay before it can be executed. This gives holders visibility and
    // advance warning (via the ActionQueued event) before any parameter
    // that affects them takes effect. Applies to everything owner-gated
    // except renounceOwnership, which only ever gives up power and so
    // needs no delay.
    uint256 public constant TIMELOCK_DELAY = 2 days;

    // actionId => timestamp the action was queued at (0 = not queued)
    mapping(bytes32 => uint256) public queuedAt;

    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCancelled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    /// @notice Queue a sensitive owner action. The exact same call to the
    /// target function (with identical parameters) must be repeated after
    /// TIMELOCK_DELAY has passed in order to execute it.
    function queueAction(bytes32 actionId) external onlyOwner {
        require(queuedAt[actionId] == 0, "already queued");
        queuedAt[actionId] = block.timestamp;
        emit ActionQueued(actionId, block.timestamp + TIMELOCK_DELAY);
    }

    /// @notice Cancel a previously queued action before it executes.
    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedAt[actionId] != 0, "not queued");
        delete queuedAt[actionId];
        emit ActionCancelled(actionId);
    }

    /// @dev Consumes a queued action: requires it was queued, requires the
    /// delay has elapsed, then clears it so it can't be replayed.
    modifier timelocked(bytes32 actionId) {
        uint256 queuedTime = queuedAt[actionId];
        require(queuedTime != 0, "action not queued");
        require(block.timestamp >= queuedTime + TIMELOCK_DELAY, "timelock not expired");
        delete queuedAt[actionId];
        _;
        emit ActionExecuted(actionId);
    }

    // ---- Helper functions to compute actionIds off-chain / in a frontend ----

    function mintActionId(address to, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode("mint", to, amount));
    }

    function setFeesActionId(uint256 _burnFeeBps, uint256 _treasuryFeeBps) public pure returns (bytes32) {
        return keccak256(abi.encode("setFees", _burnFeeBps, _treasuryFeeBps));
    }

    function setTreasuryWalletActionId(address newTreasury) public pure returns (bytes32) {
        return keccak256(abi.encode("setTreasuryWallet", newTreasury));
    }

    function setAmmPairActionId(address pair, bool isPair) public pure returns (bytes32) {
        return keccak256(abi.encode("setAmmPair", pair, isPair));
    }

    function setExcludedFromFeeActionId(address account, bool excluded) public pure returns (bytes32) {
        return keccak256(abi.encode("setExcludedFromFee", account, excluded));
    }

    function setLimitsActionId(uint256 newMaxTx, uint256 newMaxWallet) public pure returns (bytes32) {
        return keccak256(abi.encode("setLimits", newMaxTx, newMaxWallet));
    }

    function setLimitsEnabledActionId(bool enabled) public pure returns (bytes32) {
        return keccak256(abi.encode("setLimitsEnabled", enabled));
    }

    function setExcludedFromLimitsActionId(address account, bool excluded) public pure returns (bytes32) {
        return keccak256(abi.encode("setExcludedFromLimits", account, excluded));
    }

    function setSameBlockGuardEnabledActionId(bool enabled) public pure returns (bytes32) {
        return keccak256(abi.encode("setSameBlockGuardEnabled", enabled));
    }

    function setExcludedFromAntiBotActionId(address account, bool excluded) public pure returns (bytes32) {
        return keccak256(abi.encode("setExcludedFromAntiBot", account, excluded));
    }

    function transferOwnershipActionId(address newOwner) public pure returns (bytes32) {
        return keccak256(abi.encode("transferOwnership", newOwner));
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event AmmPairUpdated(address indexed pair, bool isPair);
    event ExcludedFromFee(address indexed account, bool excluded);
    event FeesUpdated(uint256 burnFeeBps, uint256 treasuryFeeBps);
    event TreasuryWalletUpdated(address indexed newTreasury);
    event LimitsUpdated(uint256 maxTxAmount, uint256 maxWalletAmount);
    event LimitsEnabledUpdated(bool enabled);
    event ExcludedFromLimits(address indexed account, bool excluded);
    event SameBlockGuardUpdated(bool enabled);
    event ExcludedFromAntiBot(address indexed account, bool excluded);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(address _treasuryWallet, address _initialOwner)
        ERC20("Storm", "STORM")
        Ownable(_initialOwner)
    {
        require(_treasuryWallet != address(0), "treasury cannot be zero address");

        treasuryWallet = _treasuryWallet;

        // Mint half of MAX_SUPPLY at deploy; the rest can only be minted
        // later via the timelocked mint() function, and never past the cap.
        _mint(_initialOwner, INITIAL_MINT);

        // Exempt key addresses from tax by default
        isExcludedFromFee[_initialOwner] = true;
        isExcludedFromFee[_treasuryWallet] = true;
        isExcludedFromFee[address(this)] = true;

        // Exempt key addresses from anti-whale limits by default
        isExcludedFromLimits[_initialOwner] = true;
        isExcludedFromLimits[_treasuryWallet] = true;
        isExcludedFromLimits[address(this)] = true;

        // Exempt key addresses from the anti-bot guard by default
        isExcludedFromAntiBot[_initialOwner] = true;
        isExcludedFromAntiBot[_treasuryWallet] = true;
        isExcludedFromAntiBot[address(this)] = true;
    }

    // ------------------------------------------------------------------
    // Owner controls (all timelocked except renounceOwnership)
    // ------------------------------------------------------------------

    /// @notice Mint additional tokens, up to MAX_SUPPLY. Requires the exact
    /// same call to have been queued via queueAction(mintActionId(to, amount))
    /// at least TIMELOCK_DELAY earlier.
    function mint(address to, uint256 amount) external onlyOwner timelocked(mintActionId(to, amount)) {
        require(totalSupply() + amount <= MAX_SUPPLY, "exceeds MAX_SUPPLY");
        _mint(to, amount);
    }

    /// @notice Register or unregister a DEX pair address so transfers to/from it are taxed.
    /// Pairs are also auto-excluded from maxWalletAmount, since a liquidity pool
    /// legitimately needs to hold more than any single-wallet cap would allow.
    function setAmmPair(address pair, bool isPair)
        external
        onlyOwner
        timelocked(setAmmPairActionId(pair, isPair))
    {
        require(pair != address(0), "pair cannot be zero address");
        isAmmPair[pair] = isPair;
        isExcludedFromLimits[pair] = isPair;
        emit AmmPairUpdated(pair, isPair);
    }

    /// @notice Exclude or include an address from/in tax.
    function setExcludedFromFee(address account, bool excluded)
        external
        onlyOwner
        timelocked(setExcludedFromFeeActionId(account, excluded))
    {
        isExcludedFromFee[account] = excluded;
        emit ExcludedFromFee(account, excluded);
    }

    /// @notice Update burn/treasury tax rates. Total capped at MAX_TOTAL_FEE_BPS.
    function setFees(uint256 _burnFeeBps, uint256 _treasuryFeeBps)
        external
        onlyOwner
        timelocked(setFeesActionId(_burnFeeBps, _treasuryFeeBps))
    {
        require(_burnFeeBps + _treasuryFeeBps <= MAX_TOTAL_FEE_BPS, "total fee too high");
        burnFeeBps = _burnFeeBps;
        treasuryFeeBps = _treasuryFeeBps;
        emit FeesUpdated(_burnFeeBps, _treasuryFeeBps);
    }

    /// @notice Update the treasury wallet that receives the treasury-side tax.
    function setTreasuryWallet(address newTreasury)
        external
        onlyOwner
        timelocked(setTreasuryWalletActionId(newTreasury))
    {
        require(newTreasury != address(0), "treasury cannot be zero address");
        treasuryWallet = newTreasury;
        emit TreasuryWalletUpdated(newTreasury);
    }

    /// @notice Update max-tx and max-wallet amounts. Both must stay at or above
    /// MIN_LIMIT_BPS of MAX_SUPPLY — limits can be raised freely but never
    /// tightened into a freeze. Pass type(uint256).max for either to disable it.
    function setLimits(uint256 newMaxTx, uint256 newMaxWallet)
        external
        onlyOwner
        timelocked(setLimitsActionId(newMaxTx, newMaxWallet))
    {
        uint256 floor = (MAX_SUPPLY * MIN_LIMIT_BPS) / 10_000;
        require(newMaxTx >= floor, "maxTx below floor");
        require(newMaxWallet >= floor, "maxWallet below floor");
        maxTxAmount = newMaxTx;
        maxWalletAmount = newMaxWallet;
        emit LimitsUpdated(newMaxTx, newMaxWallet);
    }

    /// @notice Permanently or temporarily toggle anti-whale limit enforcement.
    /// Typical use: disable once the token has matured past its launch window.
    function setLimitsEnabled(bool enabled)
        external
        onlyOwner
        timelocked(setLimitsEnabledActionId(enabled))
    {
        limitsEnabled = enabled;
        emit LimitsEnabledUpdated(enabled);
    }

    /// @notice Exclude or include an address from/in max-tx / max-wallet checks.
    function setExcludedFromLimits(address account, bool excluded)
        external
        onlyOwner
        timelocked(setExcludedFromLimitsActionId(account, excluded))
    {
        isExcludedFromLimits[account] = excluded;
        emit ExcludedFromLimits(account, excluded);
    }

    /// @notice Toggle the same-block anti-bot guard on/off. Typical use: disable
    /// once the token is past its launch window and sniper bots aren't a concern.
    function setSameBlockGuardEnabled(bool enabled)
        external
        onlyOwner
        timelocked(setSameBlockGuardEnabledActionId(enabled))
    {
        sameBlockGuardEnabled = enabled;
        emit SameBlockGuardUpdated(enabled);
    }

    /// @notice Exclude or include an address from/in the same-block anti-bot guard.
    /// Useful for exempting routers, aggregators, or other contracts that
    /// legitimately need to interact with the pair multiple times per block.
    function setExcludedFromAntiBot(address account, bool excluded)
        external
        onlyOwner
        timelocked(setExcludedFromAntiBotActionId(account, excluded))
    {
        isExcludedFromAntiBot[account] = excluded;
        emit ExcludedFromAntiBot(account, excluded);
    }

    /// @notice Transfer ownership, timelocked like every other sensitive action.
    /// Overrides Ownable.transferOwnership to add the delay.
    function transferOwnership(address newOwner)
        public
        override
        onlyOwner
        timelocked(transferOwnershipActionId(newOwner))
    {
        _transferOwnership(newOwner);
    }

    // Note: renounceOwnership() is intentionally left as-is (immediate, no
    // timelock) — giving up ownership only ever reduces the contract's power
    // over holders, so there's no reason to delay it.

    // ------------------------------------------------------------------
    // Transfer logic with tax
    // ------------------------------------------------------------------

    /// @dev Overrides ERC20._update (OZ v5 hook) to apply buy/sell tax.
    function _update(address from, address to, uint256 amount) internal override {
        // Mint (from == 0) and burn (to == 0) bypass tax logic entirely
        bool isMintOrBurn = from == address(0) || to == address(0);

        // ---- Anti-whale checks (skip on mint/burn and for excluded addresses) ----
        if (limitsEnabled && !isMintOrBurn) {
            if (!isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
                require(amount <= maxTxAmount, "transfer exceeds maxTxAmount");
            }
            // Max-wallet only makes sense for the receiving wallet, and only
            // when that wallet isn't itself a pair/router (pairs legitimately
            // hold large balances as liquidity).
            if (!isExcludedFromLimits[to]) {
                require(
                    balanceOf(to) + amount <= maxWalletAmount,
                    "transfer exceeds maxWalletAmount"
                );
            }
        }

        bool isTaxableTransfer =
            !isMintOrBurn &&
            (isAmmPair[from] || isAmmPair[to]) &&
            !isExcludedFromFee[from] &&
            !isExcludedFromFee[to];

        // ---- Same-block anti-bot guard ----
        // Applies to any trade touching a registered AMM pair (buy or sell).
        // The non-pair side is the "trader" whose block is tracked; a second
        // trade from that same address in the same block reverts.
        if (sameBlockGuardEnabled && !isMintOrBurn && (isAmmPair[from] || isAmmPair[to])) {
            address trader = isAmmPair[from] ? to : from;
            if (!isExcludedFromAntiBot[trader]) {
                require(lastTradeBlock[trader] != block.number, "one trade per block");
                lastTradeBlock[trader] = block.number;
            }
        }

        if (!isTaxableTransfer) {
            super._update(from, to, amount);
            return;
        }

        uint256 burnAmount = (amount * burnFeeBps) / 10_000;
        uint256 treasuryAmount = (amount * treasuryFeeBps) / 10_000;
        uint256 sendAmount = amount - burnAmount - treasuryAmount;

        if (burnAmount > 0) {
            super._update(from, address(0), burnAmount);
        }
        if (treasuryAmount > 0) {
            super._update(from, treasuryWallet, treasuryAmount);
        }
        super._update(from, to, sendAmount);
    }
}
