// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IERC3156PP } from "./interfaces/IERC3156PP.sol";
import { IERC3156PPChooser } from "./interfaces/IERC3156PPChooser.sol";
import { CheapestOfThreeChooser } from "./choosers/CheapestOfThreeChooser.sol";
import { RevertMsgExtractor } from "./utils/RevertMsgExtractor.sol";


contract FlashLenderAggregator {
    using RevertMsgExtractor for bytes;

    event ChooserSet(address indexed user, ERC20 indexed asset, IERC3156PPChooser chooser);
    event FlashLoan(ERC20 indexed asset, uint256 amount, uint256 fee);

    bool public inFlashLoan;

    mapping(address user => mapping(ERC20 asset => IERC3156PPChooser)) public choosers;
    IERC3156PPChooser public immutable defaultChooser;

    constructor (address owner) {
        defaultChooser = IERC3156PPChooser(address(new CheapestOfThreeChooser(owner)));
    }

    /// @dev Set a chooser for the given asset.
    function setChooser(ERC20 asset, IERC3156PPChooser chooser) external {
        choosers[msg.sender][asset] = chooser;
        emit ChooserSet(msg.sender, asset, chooser);
    }

    /// @dev Use the aggregator to serve an ERC3156++ flash loan.
    /// @dev Forward the callback to the callback receiver. The borrower only needs to trust the aggregator and its governance, instead of the underlying lenders.
    /// @param loanReceiver The address receiving the flash loan
    /// @param asset The asset to be loaned
    /// @param amount The amount to loaned
    /// @param data The ABI encoded user data
    /// @param callback The address and signature of the callback function
    /// @return result ABI encoded result of the callback
    function flashLoan(
        address loanReceiver,
        ERC20 asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param fee The fee to be paid
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, ERC20, uint256, uint256, bytes memory) external returns (bytes memory) callback
    ) external returns (bytes memory) {
        require(!inFlashLoan, "No reentrancy");
        inFlashLoan = true;

        // If the user has not registered a chooser for this asset, use the default chooser.
        IERC3156PPChooser chooser = choosers[msg.sender][asset];
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

    /// @dev Forward the callback to the callback receiver. The borrower only needs to trust the aggregator and its governance, instead of the underlying lenders.
    /// @param loanReceiver The address receiving the flash loan
    /// @param asset The asset to be loaned
    /// @param amount The amount to loaned
    /// @param fee The fee to be paid
    /// @param data The ABI encoded original user data and user callback
    /// @return result ABI encoded result of the user callback
    function forwardCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory data) external returns (bytes memory) {
        require(inFlashLoan, "Unauthorized callback");

        (bytes memory innerData, address callbackReceiver, bytes4 callbackSelector) = abi.decode(data, (bytes, address, bytes4));
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
        IERC3156PPChooser chooser = choosers[msg.sender][asset];
        if (address(chooser) == address(0)) chooser = IERC3156PPChooser(address(this));
        return chooser.maxFlashLoan(asset);
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(ERC20 asset, uint256 amount) external view returns (uint256) {
        IERC3156PPChooser chooser = choosers[msg.sender][asset];
        if (address(chooser) == address(0)) chooser = IERC3156PPChooser(address(this));
        return chooser.flashFee(asset, amount);
    }
}
