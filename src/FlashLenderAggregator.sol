// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";

interface IERC3156PP {

    /**
     * @dev Initiate a flash loan.
     * @param loanReceiver The receiver of the assets in the loan
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @param callback The function to call on the callback receiver.
     * @return The returned data by the receiver of the flash loan.
     */
    function flashLoan(
        address loanReceiver,
        ERC20 asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param callbackReceiver The contract receiving the callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, ERC20, uint256, uint256, bytes memory) external returns (bytes memory) callback
    ) external returns (bytes memory);

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(ERC20 asset) external view returns (uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 asset, uint256 amount) external view returns (uint256);
}

interface Chooser {
    /// @dev Return the lender that can best service the loan.
    function choose(ERC20 asset, uint256 amount, bytes memory data) external view returns (IERC3156PP best);

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(ERC20 asset) external view returns (uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 asset, uint256 amount) external view returns (uint256);
}

contract CheapestOfThreeChooser is Chooser, Owned {
    event Set(address indexed user, ERC20 indexed asset, IERC3156PP[3] lenders);

    mapping(address user => mapping(ERC20 asset => IERC3156PP[3])) public lenderSets;

    constructor (address owner) Owned(owner) {}

    /// @dev Set three lenders for the given asset, and an algorithm to choose between them.
    function set(ERC20 asset, IERC3156PP[3] memory lenders) onlyOwner external {
        lenderSets[msg.sender][asset] = lenders;
        emit Set(msg.sender, asset, lenders);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    /// @notice If no suitable lender is found, returns address(0).
    function _choose(ERC20 asset, uint256 amount) internal view returns (IERC3156PP) {
        IERC3156PP[3] memory lenders = lenderSets[msg.sender][asset];
        
        uint256 cheapestCost = type(uint256).max;
        IERC3156PP bestLender;
        for (uint256 i = 0; i < 3; i++) {
            if (address(lenders[i]) == address(0)) return lenders[i];
            if (lenders[i].maxFlashLoan(asset) < amount) continue;
            uint256 cost = lenders[i].flashFee(asset, amount);
            if (cost == 0) return lenders[i];
            if (cost < cheapestCost) {
                cheapestCost = cost;
                bestLender = lenders[i];
            }
        }
        return bestLender;
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    /// @notice If no suitable lender is found, returns address(0).
    function choose(ERC20 asset, uint256 amount, bytes memory) external view returns (IERC3156PP) {
        return _choose(asset, amount);
    }

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(ERC20 asset) external view returns (uint256) {
        IERC3156PP[3] memory lenders = lenderSets[msg.sender][asset];
        
        uint256 largestSize = 0;
        for (uint256 i = 0; i < 3; i++) {
            if (address(lenders[i]) == address(0)) return largestSize;
            uint256 size = lenders[i].maxFlashLoan(asset);
            if (size == type(uint256).max) return size;
            if (size > largestSize) largestSize = size;
        }
        return largestSize;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 asset, uint256 amount) external view returns (uint256) {
        return _choose(asset, amount).flashFee(asset, amount);
    }
}

library RevertMsgExtractor {
    /// @dev Helper function to extract a useful revert message from a failed call.
    /// If the returned data is malformed or not correctly abi encoded then this call can fail itself.
    function getRevertMsg(bytes memory returnData)
        internal pure
        returns (string memory)
    {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string)); // All that remains is the revert string
    }
}

contract FlashLenderAggregator {
    using RevertMsgExtractor for bytes;

    event ChooserSet(address indexed user, ERC20 indexed asset, Chooser chooser);
    event FlashLoan(ERC20 indexed asset, uint256 amount, uint256 fee);

    bool public inFlashLoan;

    mapping(address user => mapping(ERC20 asset => Chooser)) public choosers;
    Chooser public immutable defaultChooser;

    constructor (address owner) {
        defaultChooser = Chooser(address(new CheapestOfThreeChooser(owner)));
    }

    /// @dev Set a chooser for the given asset.
    function setChooser(ERC20 asset, Chooser chooser) external {
        choosers[msg.sender][asset] = chooser;
        emit ChooserSet(msg.sender, asset, chooser);
    }

    /// @dev Use the set lender to serve an ERC3156++ flash loan.
    function flashLoan(
        address loanReceiver,
        ERC20 asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param callbackReceiver The contract receiving the callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, ERC20, uint256, uint256, bytes memory) external returns (bytes memory) callback
    ) external returns (bytes memory) {
        require(!inFlashLoan, "No reentrancy");
        inFlashLoan = true;

        // If the user has not registered a chooser for this asset, use the default chooser.
        Chooser chooser = choosers[msg.sender][asset];
        if (address(chooser) == address(0)) chooser = defaultChooser;

        IERC3156PP lender;
        lender = chooser.choose(asset, amount, data);
        require (lender != IERC3156PP(address(0)), "No lender found");

        bytes memory result = lender.flashLoan(
            loanReceiver,
            asset,
            amount,
            abi.encode(data, callback.address, callback.selector), // abi.decode seems to struggle with function types - https://github.com/ethereum/solidity/issues/6942
            this.forwardCallback // In many cases, for the callback receiver to trust the flash loan, the callback must come from a known contract. The aggregator contract can be used as a trusted forwarder.
        );
        inFlashLoan = false;
        return result;
    }

    /// @dev Forward the callback to the callback receiver, acting as a trusted forwarder.
    function forwardCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory outerData) external returns (bytes memory) {
        require(inFlashLoan, "Unauthorized callback");

        (bytes memory innerData, address callbackReceiver, bytes4 callbackSelector) = abi.decode(outerData, (bytes, address, bytes4));
        (bool success, bytes memory result) = callbackReceiver.call(
            abi.encodeWithSelector(
                callbackSelector,
                loanReceiver,
                asset,
                amount,
                innerData
            )
        );
        require(success, result.getRevertMsg());

        emit FlashLoan(asset, amount, fee);
        return result;
    }

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(ERC20 asset) external view returns (uint256) {
        Chooser chooser = choosers[msg.sender][asset];
        if (address(chooser) == address(0)) chooser = Chooser(address(this));
        return chooser.maxFlashLoan(asset);
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 asset, uint256 amount) external view returns (uint256) {
        Chooser chooser = choosers[msg.sender][asset];
        if (address(chooser) == address(0)) chooser = Chooser(address(this));
        return chooser.flashFee(asset, amount);
    }
}
