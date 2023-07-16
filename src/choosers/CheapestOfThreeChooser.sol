// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IERC3156PP } from "../interfaces/IERC3156PP.sol";
import { IERC3156PPChooser } from "../interfaces/IERC3156PPChooser.sol";


contract CheapestOfThreeChooser is IERC3156PPChooser, Owned {
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