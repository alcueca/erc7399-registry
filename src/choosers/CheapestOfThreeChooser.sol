// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { IERC3156PP } from "../interfaces/IERC3156PP.sol";
import { IERC3156PPChooser } from "../interfaces/IERC3156PPChooser.sol";


contract CheapestOfThreeChooser is IERC3156PPChooser, Owned {
    event LendersSet(address indexed user, ERC20 indexed asset, IERC3156PP[3] lenders);
    event LenderTrusted(IERC3156PP lender);
    event LenderUntrusted(IERC3156PP lender);

    struct LenderSet {
        IERC3156PP[3] lenders;
        uint8[3] order;
    }

    mapping(address user => mapping(ERC20 asset => LenderSet)) internal lenderSets; // Why can't it be public? It doesn't look recursive to me.
    mapping(IERC3156PP => bool) public trustedLenders;

    constructor (address owner) Owned(owner) {}

    /// @dev Set three lenders for the given asset, and an algorithm to choose between them.
    function set(ERC20 asset, IERC3156PP[3] memory lenders) external {
        lenderSets[msg.sender][asset] = LenderSet({lenders: lenders, order: [0, 1, 2]});
        emit LendersSet(msg.sender, asset, lenders);
    }

    function trust(IERC3156PP lender) external onlyOwner {
        trustedLenders[lender] = true;
        emit LenderTrusted(lender);
    }

    function untrust(IERC3156PP lender) external onlyOwner {
        trustedLenders[lender] = false;
        emit LenderUntrusted(lender);
    }

    function addDefault(ERC20 asset, IERC3156PP lender) external {
        require(trustedLenders[lender], "Lender not trusted");
        LenderSet memory lenderSet = lenderSets[address(this)][asset];
        for (uint256 i = 0; i < 3; i++) {
            if (i == 2 || address(lenderSet.lenders[lenderSet.order[i]]) == address(0)) {
                lenderSet.lenders[lenderSet.order[i]] = lender;
                break;
            }
        }
        lenderSets[address(this)][asset] = lenderSet;
        emit LendersSet(address(this), asset, lenderSet.lenders);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    /// @notice If no suitable lender is found, returns address(0).
    function _choose(LenderSet memory lenderSet, ERC20 asset, uint256 amount) internal view returns (LenderSet memory, uint256) {
        IERC3156PP[3] memory lenders = lenderSet.lenders;
        uint8[3] memory order = lenderSet.order;
        
        uint256 cheapestFee = type(uint256).max;
        uint8 bestLender;
        for (uint8 i = 0; i < 3; i++) {
            IERC3156PP lender = lenders[order[i]];
            if (address(lender) == address(0)) break;
            if (lender.maxFlashLoan(asset) < amount) continue;

            uint256 fee = lender.flashFee(asset, amount);
            if (fee < cheapestFee) {
                cheapestFee = fee;
                bestLender = i;
            }

            if (fee == 0) break;
        }
        (order[0], order[bestLender]) = (order[bestLender], order[0]); // The best lender swaps places with the first lender.
        lenderSet.order = order;
        return (lenderSet, cheapestFee);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    /// @notice If no suitable lender is found, returns address(0).
    function choose(address user, ERC20 asset, uint256 amount, bytes memory) external view returns (IERC3156PP) {
        LenderSet memory lenderSet = lenderSets[user][asset];
        if (lenderSet.lenders[lenderSet.order[0]] == IERC3156PP(address(0))) lenderSet = lenderSets[address(this)][asset];
        
        (lenderSet,) = _choose(lenderSet, asset, amount);
        return lenderSet.lenders[lenderSet.order[0]];
    }

    /**
     * @dev The amount of currency available to be lended.
     * @param asset The loan currency.
     * @return The amount of `asset` that can be borrowed.
     */
    function maxFlashLoan(address user, ERC20 asset) external view returns (IERC3156PP, uint256) {
        LenderSet memory lenderSet = lenderSets[user][asset];
        if (lenderSet.lenders[lenderSet.order[0]] == IERC3156PP(address(0))) lenderSet = lenderSets[address(this)][asset];

        uint256 largestSize = 0;
        IERC3156PP bestLender;
        for (uint256 i = 0; i < 3; i++) {
            IERC3156PP lender = lenderSet.lenders[lenderSet.order[i]];
            if (address(lender) == address(0)) break;
            uint256 size = lender.maxFlashLoan(asset);
            if (size > largestSize) {
                bestLender = lender;
                largestSize = size;
            }
            if (largestSize == type(uint256).max) break;
        }
        return (bestLender, largestSize);
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param asset The loan currency.
     * @param amount The amount of assets lent.
     * @return The amount of `asset` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address user, ERC20 asset, uint256 amount) external view returns (IERC3156PP, uint256 fee) {
        LenderSet memory lenderSet = lenderSets[user][asset];
        if (lenderSet.lenders[lenderSet.order[0]] == IERC3156PP(address(0))) lenderSet = lenderSets[address(this)][asset];

        (lenderSet, fee) = _choose(lenderSet, asset, amount);
        return (lenderSet.lenders[lenderSet.order[0]], fee);
    }
}