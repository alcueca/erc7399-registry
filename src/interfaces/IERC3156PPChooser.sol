// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { IERC3156PP } from "./IERC3156PP.sol";

interface IERC3156PPChooser {
    /// @dev Return the lender that can best service the loan.
    function choose(address user, ERC20 asset, uint256 amount, bytes memory data) external view returns (IERC3156PP best);

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(address user, ERC20 asset) external view returns (IERC3156PP, uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address user, ERC20 asset, uint256 amount) external view returns (IERC3156PP, uint256);
}