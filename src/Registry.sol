// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

interface IERC3156PP {

    /**
     * @dev Initiate a flash loan.
     * @param loanReceiver The receiver of the tokens in the loan
     * @param asset The loan currency.
     * @param amount The amount of tokens lent.
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
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(ERC20 token) external view returns (uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 token, uint256 amount) external view returns (uint256);
}

interface Chooser {
    /// @dev Return the best of the lender for the given asset and amount.
    function choose(IERC3156PP[3] calldata, ERC20 asset, uint256 amount, bytes memory data) external returns (IERC3156PP);
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

contract Registry is Chooser {
    using RevertMsgExtractor for bytes;

    event FlashLoan(ERC20 indexed asset, uint256 amount, uint256 fee);
    event Set(address indexed user, ERC20 indexed asset, IERC3156PP[3] lenders, Chooser chooser);

    struct LenderSet {
        IERC3156PP[3] lenders;
        Chooser chooser;
        bool exists;
    }

    bool public inFlashLoan;

    mapping(address user => mapping(ERC20 asset => LenderSet)) public lenderSets;
    mapping(ERC20 asset => IERC3156PP) public lastLenders;

    /// @dev Set three lenders for the given asset, and an algorithm to choose between them.
    function set(ERC20 asset, IERC3156PP[3] memory lenders_, Chooser chooser_) external {
        lenderSets[msg.sender][asset] = LenderSet(lenders_, chooser_, true);

        emit Set(msg.sender, asset, lenders_, chooser_);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    /// This is a default Chooser, but users can implement their own.
    function choose(IERC3156PP[3] calldata lenders, ERC20 asset, uint256 amount, bytes memory data) external view returns (IERC3156PP best) {
        return _choose(lenders, asset, amount, data);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    function _choose(IERC3156PP[3] calldata lenders, ERC20 asset, uint256 amount, bytes memory) internal view returns (IERC3156PP best) {
        uint256 cheapest = type(uint256).max;
        for (uint256 i = 0; i < 3; i++) {
            if (lenders[i] != IERC3156PP(address(0)) && lenders[i].maxFlashLoan(asset) >= amount) {
                uint256 cost = lenders[i].flashFee(asset, amount);
                if (cost < cheapest) {
                    cost = cheapest;
                    best = lenders[i];
                }
            }
        }
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

        LenderSet storage lenderSet = lenderSets[msg.sender][asset];
        IERC3156PP lender;
        // If the user has registered a lender set for the asset, try to choose one.
        if (lenderSet.exists) {
            lender = lenderSet.chooser.choose(lenderSet.lenders, asset, amount, data);
            if (lender != IERC3156PP(address(0))) lastLenders[asset] = lender;
        }
        // If not possible, use the last lender for that asset from other users.
        else lender = lastLenders[asset];

        require (lender != IERC3156PP(address(0)), "No lender found");

        bytes memory result = lender.flashLoan(
            loanReceiver,
            asset,
            amount,
            abi.encode(data, callback.address, callback.selector), // abi.decode seems to struggle with function types
            this.forwardCallback // In many cases, for the callback receiver to trust the flash loan, the callback must come from a known contract. The aggregator contract can be used as a trusted forwarder.
        );
        inFlashLoan = false;
        return result;
    }

    /// @dev Forward the callback to the callback receiver, acting as a trusted forwarder.
    function forwardCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory outerData) external returns (bytes memory) {
        require(inFlashLoan, "Unauthorized callback");
        (bytes memory innerData, address callbackReceiver, bytes4 callbackSelector) = abi.decode(outerData, (bytes, address, bytes4));

        emit FlashLoan(asset, amount, fee);
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

        return result;
    }
}
