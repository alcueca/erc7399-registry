// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";


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