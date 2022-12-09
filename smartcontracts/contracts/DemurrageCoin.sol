// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import "./ERC20Mutable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "hardhat/console.sol";

uint8 constant DECIMALS = 18;

/**
 * Inspiration: Wörgl currency (see https://twitter.com/xdamman/status/1543854893081001984)
 * Implementation choices:
 * I found this implementation of a demurrage currency (https://github.com/theecocoin/ecocoin-solidity/blob/master/contracts/ERC20Demurrageable.sol)
 * but
 * - I don't like that the demurrage fee is burnt which causes a discrepency between total supply and the amount of fiat money used to back the currency
 * - I wanted to add a transaction fee, otherwise there is an incentive for people to move their money to a new account
 */
contract DemurrageCoin is ERC20Mutable, Ownable, AccessControl {
    mapping(address => uint256) private _balances;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");

    IERC20 stableCoin;
    address feeCollector;
    uint256 blockTimestamp = block.timestamp;
    uint256 transactionFee; // transaction fee with 3 decimals (e.g. for 0.15%, transactionFee = 150)
    uint256 withdrawalFee; // fee to exchange citizen coins back to stable coin with 3 decimals precision

    /// Struct to hold the history of changes made to the demurrage rate
    struct DemurrageRate {
        uint256 startFrom; // period number where the demurrage rate starts from
        uint256 rate; /// the new rate of demurrage with 3 decimals
    }

    uint8 internal _rateDecimals; /// Number of decimals for the demurrage rate (see DemurrageRate struct)
    uint256 internal demurragePeriodLength; /// Duration of a period on which demurrage is applied, in seconds

    mapping(address => uint256) private _lastTimeAccountBalanceChanged; // keeps track of the last time the balance changed to compute demurrage fees
    mapping(uint256 => DemurrageRate) private _demurrageRateHistory;
    uint256 private _demurrageRateHistoryCount;
    uint256 firstPeriodTimestamp; // Epoch time of the first period

    event DemurrageRateUpdated(uint256 newRate, uint256 startPeriod);

    function max(uint256 a, uint256 b) public pure returns (uint256) {
        return a >= b ? a : b;
    }

    function toString(address account) internal pure returns (string memory) {
        return toString(abi.encodePacked(account));
    }

    function toString(uint256 value) internal pure returns (string memory) {
        return toString(abi.encodePacked(value));
    }

    function toString(bytes32 value) internal pure returns (string memory) {
        return toString(abi.encodePacked(value));
    }

    function toString(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }

    function substring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    ) public pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    // Returns number the days between timestamp and since
    // If timestamp is null, returns 0
    function elapsedDays(uint256 timestamp, uint256 since)
        public
        pure
        returns (uint256)
    {
        if (timestamp == 0) {
            return 0;
        }
        return
            (timestamp < since)
                ? (since - timestamp) / 1 days
                : (timestamp - since) / 1 days;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address stableCoinAddress,
        address _feeCollector,
        uint256 _withdrawalFee,
        uint256 _transactionFee,
        uint256 _demurrageRate,
        uint256 _demurragePeriodLength,
        uint256 _firstPeriodTimestamp
    ) ERC20Mutable(_name, _symbol) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, msg.sender);
        _setupRole(DAO_ROLE, _feeCollector);

        feeCollector = _feeCollector;
        withdrawalFee = _withdrawalFee;
        transactionFee = _transactionFee;

        stableCoin = IERC20(stableCoinAddress);

        _rateDecimals = 6;

        demurragePeriodLength = _demurragePeriodLength;

        if (_firstPeriodTimestamp > 0) {
            setDemurrageStartTime(_firstPeriodTimestamp);
        }
        _demurrageRateHistory[0] = DemurrageRate(
            blockTimestamp,
            _demurrageRate
        );
        _demurrageRateHistoryCount = 1;

        emit DemurrageRateUpdated(_demurrageRate, 0);
    }

    function setDemurrageStartTime(uint256 _firstPeriodTimestamp)
        public
        onlyOwner
    {
        require(
            firstPeriodTimestamp == 0,
            "demurrage start time has already been set"
        );
        firstPeriodTimestamp = _firstPeriodTimestamp;
    }

    /**
     * @dev Calculates the demurraged balance of an account and persists it.
     * This function is called automatically on demand, but it can also be called manually for maintenance.
     * @param account The account address for which to update and persist the demurrage.
     */
    function updateBalanceWithDemurrage(address account) public {
        uint256 currentBalance = super.balanceOf(account);

        console.log(
            ">>> updateBalanceWithDemurrage for account",
            substring(toString(account), 0, 6)
        );
        console.log(
            "Balance:",
            currentBalance,
            "Days since last balance change:",
            elapsedDays(_lastTimeAccountBalanceChanged[account], blockTimestamp)
        );

        // If the balance is null, there is no point in computing the new value after demurrage
        if (currentBalance == 0) {
            return;
        }

        // If the balance hasn't changed within the past demurragePeriodLength, there is no point in computing the new value after demurrage
        if (_lastTimeAccountBalanceChanged[account] < demurragePeriodLength) {
            return;
        }

        uint256 demurragedBalance = _computeBalanceWithDemurrage(
            currentBalance,
            _lastTimeAccountBalanceChanged[account]
        );
        uint256 demurrageFee = currentBalance - demurragedBalance;
        console.log(
            "Updating demurrage from, to, fee:",
            currentBalance,
            demurragedBalance,
            demurrageFee
        );

        if (account == msg.sender) {
            super.transfer(feeCollector, demurrageFee);
        } else {
            increaseAllowanceFor(account, msg.sender, demurrageFee);
            super.transferFrom(account, feeCollector, demurrageFee);
            // _setBalance(account, demurragedBalance);
        }

        _lastTimeAccountBalanceChanged[account] = blockTimestamp;
    }

    function computeFees(uint256 amount, uint256 fees)
        internal
        view
        returns (uint256)
    {
        return (fees * amount) / (10**uint256(_rateDecimals));
    }

    function _chargeFee(uint256 _fee, address to) internal returns (bool) {
        if (_fee == 0) {
            return false;
        }
        console.log(
            ">>> _chargeFee of",
            _fee / 10**16,
            "to",
            substring(toString(to), 0, 6)
        );
        if (to == msg.sender) {
            super.transfer(feeCollector, _fee);
        } else {
            super.transferFrom(to, feeCollector, _fee);
        }
        uint256 collectedFees = balanceOf(feeCollector);
        console.log("Fees collected (in cents)", collectedFees / 10**16);
        return true;
    }

    function _chargeTransactionFee(address to, uint256 transactionAmount)
        internal
    {
        uint256 _fee = computeFees(transactionAmount, transactionFee);
        _chargeFee(_fee, to);
    }

    /**
     * @dev Transfer the given number of tokens from token owner's account to the 'to' account.
     * Before doing the transfer, accounts of sender and receiver are updated with demurrage.
     * Owner's account must have sufficient balance to transfer. 0 value transfers are allowed.
     * @param to Address of token receiver.
     * @param transactionAmount Amount of tokens to transfer.
     * @return 'true' on success.
     */
    function transfer(address to, uint256 transactionAmount)
        public
        override
        returns (bool)
    {
        console.log("0. balance of sender", super.balanceOf(msg.sender));
        updateBalanceWithDemurrage(msg.sender);
        updateBalanceWithDemurrage(to);
        console.log("1. balance of sender", super.balanceOf(msg.sender));
        _chargeTransactionFee(msg.sender, transactionAmount);
        console.log("2. balance of sender", super.balanceOf(msg.sender));
        console.log("3. Sending", transactionAmount, "to", to);
        super.transfer(to, transactionAmount);
        _lastTimeAccountBalanceChanged[msg.sender] = blockTimestamp;
        _lastTimeAccountBalanceChanged[to] = blockTimestamp;
        return true;
    }

    /**
     * @dev Transfer 'value' tokens from the 'from' account to the 'to' account.
     * Before doing the transfer, accounts of sender and receiver are updated with demurrage.
     * From account must have sufficient balance to transfer.
     * Spender must have sufficient allowance to transfer.
     * 0 value transfers are allowed.
     * @param from Address to transfer tokens from.
     * @param to Address to transfer tokens to.
     * @param transactionAmount Number of tokens to transfer.
     * @return 'true' on success.
     */
    function transferFrom(
        address from,
        address to,
        uint256 transactionAmount
    ) public override returns (bool) {
        updateBalanceWithDemurrage(from);
        updateBalanceWithDemurrage(to);
        _chargeTransactionFee(from, transactionAmount);
        return super.transferFrom(from, to, transactionAmount);
    }

    /**
     * For testing purposes we allow to set the clock in the future
     */
    function setBlockTimestampInTheFuture(uint256 _timestamp) public onlyOwner {
        require(
            _timestamp > block.timestamp,
            "Timestamp must be in the future"
        );

        // We set the current time to the future
        blockTimestamp = _timestamp;

        console.log(
            ">>> setting blockTimestamp",
            elapsedDays(_timestamp, block.timestamp),
            "days in the future"
        );
    }

    function balanceOf(address addr)
        public
        view
        override
        returns (uint256 value)
    {
        // No demurrage for the feeCollector
        if (addr == feeCollector) {
            return super.balanceOf(addr);
        }

        value = _computeBalanceWithDemurrage(
            super.balanceOf(addr),
            _lastTimeAccountBalanceChanged[addr]
        );
    }

    /**
     * @dev Mint new coins.
     * Before the minting and account of receiver are updated with demurrage.
     * @param value Amount of tokens to mint.
     * @return 'true' on success.
     */

    function mint(uint256 value) public returns (bool) {
        stableCoin.transferFrom(msg.sender, address(this), value);
        console.log(
            ">>> minting",
            value / 10**18,
            "to",
            substring(toString(msg.sender), 0, 6)
        );
        updateBalanceWithDemurrage(msg.sender);
        _mint(msg.sender, value);
        _lastTimeAccountBalanceChanged[msg.sender] = blockTimestamp;
        return true;
    }

    function withdraw(uint256 value) public returns (bool) {
        updateBalanceWithDemurrage(msg.sender);

        uint256 _fee = computeFees(value, withdrawalFee);
        console.log(
            "Withdrawing",
            value / 10**18,
            "fees (in cents)",
            _fee / 10**16
        );
        uint256 balance = balanceOf(msg.sender);
        require(balance > value + _fee, "Not enough balance");

        _chargeFee(_fee, msg.sender);
        uint256 senderBalance = balanceOf(msg.sender);

        stableCoin.transfer(msg.sender, value);

        // We burn the coins
        _burn(msg.sender, value);
        return true;
    }

    /**
     * @dev Schedule a change to the demurrage rate. The change must be scheduled for a future period.
     * Scheduled changes cannot be reverted. They guarantee a given rate for the users.
     * @param newRate The new demurrage rate to be applied from the given period onwards multiplied by 1000 (e.g. 0.15% => 150).
     */
    function updateDemurrageRate(uint256 newRate, uint256 _startFrom)
        public
        onlyRole(MINTER_ROLE)
    {
        console.log(
            ">>> updateDemurrageRate",
            newRate,
            "starting in (days)",
            elapsedDays(_startFrom, blockTimestamp)
        );

        require(
            _startFrom > blockTimestamp,
            "New demurrage rate must be in the future"
        );

        _demurrageRateHistory[_demurrageRateHistoryCount] = DemurrageRate(
            _startFrom,
            newRate
        );
        _demurrageRateHistoryCount++;

        emit DemurrageRateUpdated(newRate, _startFrom);
    }

    /**
     * @dev If other ERC20 tokens are accidentally sent to this contract, the owner can
     * transfer them out.
     * @param tokenAddress Address of a token contract that corresponds to the sent tokens.
     * @param value Number of tokens to transfer.
     * @return 'true' on success.
     */
    function transferAnyERC20Token(address tokenAddress, uint256 value)
        public
        onlyOwner
        returns (bool)
    {
        return IERC20(tokenAddress).transfer(owner(), value);
    }

    /**
     * @dev Calculate the demurraged balance of an account.
     * For a given balance, it applies the demurrage rate for each outstanding period until 'now'.
     * @param value Base value for which to calculate the demurraged value.
     * @param lastTimeBalanceChanged Period number from which to start the demurrage calculation.
     * @return demurragedBalance
     */
    function _computeBalanceWithDemurrage(
        uint256 value,
        uint256 lastTimeBalanceChanged
    ) internal view returns (uint256) {
        uint256 demurragedValue = value;
        uint256 currentRatePeriodEndTimestamp;
        uint256 i;

        console.log(
            ">>> _computeBalanceWithDemurrage, _demurrageRateHistoryCount:",
            _demurrageRateHistoryCount
        );
        console.log(
            "Current balance:",
            value,
            "Last time balance changed (days ago):",
            elapsedDays(lastTimeBalanceChanged, blockTimestamp)
        );

        // Iterate over outstanding changes to the demurrage rate
        for (i = 0; i < _demurrageRateHistoryCount; i++) {
            DemurrageRate storage currentRate = _demurrageRateHistory[i];
            console.log(
                "Rate history index, rate, startFrom (days ago)",
                i,
                currentRate.rate,
                elapsedDays(currentRate.startFrom, blockTimestamp)
            );

            if (currentRate.rate == 0) {
                continue;
            }

            // Check if there will be more demurrage changes to apply
            bool moreChanges = i < _demurrageRateHistoryCount - 1 &&
                _demurrageRateHistory[i + 1].startFrom <= blockTimestamp;

            if (moreChanges) {
                currentRatePeriodEndTimestamp = _demurrageRateHistory[i + 1]
                    .startFrom;
            } else {
                currentRatePeriodEndTimestamp = blockTimestamp;
            }

            // if the current rate period ended before lastTimeBalanceChanged, we skip this loop and continue
            if (currentRatePeriodEndTimestamp < lastTimeBalanceChanged) {
                continue;
            }

            // We count the number of days since the last time the balance changed and apply the demurrage rate
            // if the last time the balance changed was before the current rate period, we only apply the new rate since the beginning of the new rate
            // e.g. if you have a balance of 1000 on Jan 1 when demurrage rate was 1% per month, and the rate changed to 2% on March 20
            // your balance hasn't changed for 2 months and 20 days so we apply the 1% rate for two months, then if your balance hasn't moved again by April 20,
            // you will pay a 2% demurrage every 30 days.
            uint256 elapsedTimeWithCurrentRate = currentRatePeriodEndTimestamp -
                max(lastTimeBalanceChanged, currentRate.startFrom);

            uint256 periods = elapsedTimeWithCurrentRate /
                demurragePeriodLength;

            console.log("Applying demurrage rate for", periods, "periods");

            // Demurrage the balance over period interval [startPeriod, currentRatePeriodEndTimestamp[
            demurragedValue =
                (demurragedValue *
                    computeDemurrageFactor(currentRate.rate, periods)) /
                (10**uint256(_rateDecimals));

            console.log("Demurraged balance:", demurragedValue);
            if (!moreChanges) {
                break;
            }
        }

        return demurragedValue;
    }

    function computeDemurrageFactor(uint256 rate, uint256 numberOfPeriods)
        public
        view
        returns (uint256)
    {
        uint256 rateMultiplier = ((10**uint256(_rateDecimals)) - rate);
        return
            rpow(rateMultiplier, numberOfPeriods, 10**uint256(_rateDecimals));
    }

    /**
     * @dev Calculates 'x' by the power of 'n' with a 'base'.
     * The base allows for calculating the power with uint using decimals.
     * Taken from https://github.com/makerdao/dsr/blob/master/src/dsr.sol
     */
    function rpow(
        uint256 x,
        uint256 n,
        uint256 base
    ) public pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 {
                    z := base
                }
                default {
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    z := base
                }
                default {
                    z := x
                }
                let half := div(base, 2) // for rounding.
                for {
                    n := div(n, 2)
                } n {
                    n := div(n, 2)
                } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) {
                        revert(0, 0)
                    }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }
}
