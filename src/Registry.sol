// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

contract Registry {
    struct Lender {
        // TODO: Pack to save gas on registration
        address lender; // The address of the lender
        address asset;  // The address of the asset
        uint256 amount; // The amount of the asset lent on registration, in asset units and capped at 2**88-1
        uint256 fee;    // The fee paid to the lender on registration, in percentage of the loan amount
        uint256 gas;    // The gas used on registration
    }

    bool public safe;   // Whether a callback is authorized

    Lender[] public lenders; // The list of registered lenders
    mapping(address lender => mapping(address asset => uint256)) public lenderIndex; // The index of the lender in the list of registered lenders
    mapping(address asset => uint256[3]) public topLenders; // The top lenders for each asset


    /// ------------------------------------------------------------------------------------------------------------------------ ///
    /// ------------------------------------------------------- REGISTRY ------------------------------------------------------- ///
    /// ------------------------------------------------------------------------------------------------------------------------ ///

    /// @dev Register an ERC3156++ flash loan lender for a given asset.
    /// The registry process will involve a flash loan of the asset of the amount specified by the user.
    /// If the assets are made available to this contract, and the caller pays for the fee, the lender will be registered.
    /// All registered lenders can be retrieved one by one.
    /// The top three lenders can be retrieved. A lender is better than another if the loan served is larger and the fee/loan ratio is lower.
    /// @param lender The address of the lender to be registered.
    /// @param asset The address of the asset to be registered.
    /// @param amount The amount of the asset to be registered.
    function register(address lender, address asset, uint256 amount) external returns (uint256 ranking) {
        safe = true;
        rank = abi.decode(uint256, lender.flashLoan(
            forwarder,
            address(this),
            asset,
            amount,
            abi.encode(gasLeft()),
            this.registerCallback(address, IERC20, uint256, uint256, bytes)
        ));
        delete safe;
        return rank;
    }

    function registerCallback(address loanReceiver, IERC20 asset, uint256 amount, uint256 fee, bytes memory data) external returns (bytes memory) {
        uint256 gasAtCallback = gasLeft();
        require(safe, "Unauthorized callback");
        delete safe;

        require(asset.balanceOf(loanReceiver) >= amount, "Loan not received");
        loanReceiver.retrieve(asset, amount);
        asset.approve(msg.sender, amount);

        (uint256 gasAtCall) = abi.decode(data, (uint256));
        Lender memory newLender = Lender(
            lender,
            asset,
            amount,
            fee * 1e18 / amount,
            gasAtCall - gasAtCallback
        );

        // If this is the first time the lender is registered for the given asset, add it to the list of lenders
        // If not, update the lender entry only if amount is bigger or equal and fee/amount is lower
        uint256 lenderIndex_ = lenderIndex[lender][asset];
        if (newLenderIndex == 0) {
            newLenderIndex = lenders.length;
            lenders.push(newLender);
            lenderIndex[lender_][asset] = newLenderIndex;
        } else {
            Lender memory oldLender = lenders[newLenderIndex];
            if (newLender.amount >= oldLender.amount && newLender.fee < oldLender.fee) {
                lenders[newLenderIndex] = newLender;
            }
        }

        // Update the top lenders for the given asset
        return abi.encode(_rank(newLender, newLenderIndex));
    }

    /// @dev Return the rank of the lender for the given asset, and update the top lenders if needed.
    function _rank(Lender memory newLender, uint256 newLenderIndex) internal returns (uint256 rank) {
        uint256[3] memory topLenders_ = topLenders[lender.asset];

        Lender memory firstLender = lenders[topLenders_[0]];
        if (newLender.amount >= firstLender.amount && newLender.fee < firstLender.fee) {
            topLenders_[2] = topLenders_[1];
            topLenders_[1] = topLenders_[0];
            topLenders_[0] = newLenderIndex;
            return 0;
        }

        Lender memory secondLender = lenders[topLenders_[1]];
        if (newLender.amount >= secondLender.amount && newLender.fee < secondLender.fee) {
            topLenders_[2] = topLenders_[1];
            topLenders_[1] = newLenderIndex;
            return 1;
        }

        Lender memory thirdLender = lenders[topLenders_[2]];
        if (newLender.amount >= thirdLender.amount && newLender.fee < thirdLender.fee) {
            topLenders_[2] = newLenderIndex;
            return 2;
        }

        return 3;
    }

    /// @dev Return the top three lenders for an asset, in a gas efficient way.
    function topLendersPacked(address asset) external view returns (bytes memory) {
        uint256[3] memory topLenders_ = topLenders[asset];
        Lender memory firstLender = lenders[topLenders_[0]];
        Lender memory secondLender = lenders[topLenders_[1]];
        Lender memory thirdLender = lenders[topLenders_[2]];
        return abi.encodePacked(
            firstLender.lender, firstLender.amount, firstLender.fee, firstLender.gas,
            secondLender.lender, secondLender.amount, secondLender.fee, secondLender.gas,
            thirdLender.lender, thirdLender.amount, thirdLender.fee, thirdLender.gas
        );
    }

    /// ------------------------------------------------------------------------------------------------------------------------ ///
    /// ------------------------------------------------------- LENDING -------------------------------------------------------- ///
    /// ------------------------------------------------------------------------------------------------------------------------ ///

    /// @dev Use the top lender to serve an ERC3156++ flash loan.
    function flashLoan(
        address loanReceiver,
        address callbackReceiver,
        address asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param callbackReceiver The contract receiving the callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, IERC20, uint256, uint256, bytes memory, address) external returns (bytes memory) callback
    ) external returns (bytes memory) {
        safe = true;
        return lenders[topLenders[0]].lender.flashLoan(
            loanReceiver,
            address(this),
            asset,
            amount,
            abi.encode(data, callbackReceiver, callback),
            this.forwardCallback(address, IERC20, uint256, uint256, bytes) // In many cases, for the callback receiver to trust the flash loan, the callback must come from a known contract. The aggregator contract can be used as a trusted forwarder.
        );
    }

    /// @dev Forward the callback to the callback receiver, acting as a trusted forwarder.
    function forwardCallback(address loanReceiver, IERC20 asset, uint256 amount, uint256 fee, bytes memory outerData) external returns (bytes memory) {
        require(safe, "Unauthorized callback");
        delete safe;
        (
            bytes memory innerData,
            address callbackReceiver,
            function(address, IERC20, uint256, uint256, bytes memory) external returns (bytes memory) innerCallback
        ) = abi.decode(outerData, (
            bytes,
            address, 
            function(address, IERC20, uint256, uint256, bytes memory) external returns (bytes memory)));
        return callbackReceiver.innerCallback(loanReceiver, asset, amount, fee, innerData);

    }
}
