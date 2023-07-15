// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/token/ERC20.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";

interface IERC3156PPLender is Owned {

    /// @dev Flash borrow using the ERC3156++ flash loan standard.
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
        function(address, ERC20, uint256, uint256, bytes memory, address) external returns (bytes memory) callback
    ) external returns (bytes memory);
}

/// @dev The forwarder is deployed by the registry to verify that the loan can be sent to a contract
/// different from the one that receives the callback
contract Forwarder {
    address public immutable owner;
    constructor() {
        owner = msg.sender;
    }

    function retrieve(ERC20 asset, uint256 amount) external {
        require(msg.sender == owner, "Unauthorized");
        asset.transfer(owner, amount);
    }
}

contract Registry is Owned {
    event Requested(IERC3156PPLender lender, ERC20 asset);
    event Unrequested(IERC3156PPLender lender, ERC20 asset);
    event Registered(IERC3156PPLender lender, ERC20 asset, uint256 rank);
    event Unregistered(IERC3156PPLender lender, ERC20 asset);
    
    struct Lender {
        // TODO: Pack to save gas on registration
        IERC3156PPLender lender; // The address of the lender
        ERC20 asset;             // The address of the asset
        uint256 amount;          // The amount of the asset lent on registration, in asset units and capped at 2**88-1
        uint256 fee;             // The fee paid to the lender on registration, in percentage of the loan amount
        uint256 gas;             // The gas used on registration
    }

    Forwarder public immutable forwarder; // The forwarder contract
    bool public safe;   // Whether a callback is authorized

    Lender[] public lenders; // The list of registered lenders
    mapping(IERC3156PPLender lender => mapping(ERC20 asset => uint256)) public lenderIndex; // The index of the lender in the list of registered lenders
    mapping(ERC20 asset => uint256[3]) public topLenders; // The top lenders for each asset

    constructor() Owned() {
        forwarder = new Forwarder();

        // We add a dummy lender at index 0 so that the lenderIndex returning zero is interpreted as "not registered"
        lenders.push(
            Lender(
                IERC3156PPLender(address(0)),
                ERC20(address(0)),
                type(uint256).max,
                0,
                0
            )
        );
    }

    /// ------------------------------------------------------------------------------------------------------------------------ ///
    /// ------------------------------------------------------- REGISTRY ------------------------------------------------------- ///
    /// ------------------------------------------------------------------------------------------------------------------------ ///

    /// @dev Anyone can request a lender to be registered for a given asset. There is a delay of 7 days.
    function request(IERC3156PPLender lender, ERC20 asset) external {
        bytes32 requestHash = keccak256(abi.encode(lender,asset));
        require(requests[requestHash] == 0, "Request already made");
        requests[requestHash] = block.timestamp + 7 days;

        emit Requested(lender, asset);
    }

    /// @dev Governance can remove a request if found to be malicious.
    function unrequest(IERC3156PPLender lender, ERC20 asset) external onlyOwner {
        bytes32 requestHash = keccak256(abi.encode(lender,asset));
        require(requests[requestHash] > 0, "Request not made");
        delete requests[requestHash];

        emit Unrequested(lender, asset);
    }

    /// @dev Register an ERC3156++ flash loan lender for a given asset.
    /// The registry process will involve a flash loan of the asset of the amount specified by the user.
    /// If the assets are made available to this contract, and the caller pays for the fee, the lender will be registered.
    /// All registered lenders can be retrieved one by one.
    /// The top three lenders can be retrieved. A lender is better than another if the loan served is larger and the fee/loan ratio is lower.
    /// @param lender The address of the lender to be registered.
    /// @param asset The address of the asset to be registered.
    /// @param amount The amount of the asset to be registered.
    function register(IERC3156PPLender lender, ERC20 asset, uint256 amount) external returns (uint256) {
        bytes32 requestHash = keccak256(abi.encode(lender,asset));
        require(requests[requestHash] > block.timestamp, "Request not ready");
        delete requests[requestHash];

        safe = true;
        uint256 rank = abi.decode(uint256, lender.flashLoan(
            forwarder,
            address(this),
            asset,
            amount,
            abi.encode(gasleft()),
            this.registerCallback(address, ERC20, uint256, uint256, bytes)
        ));
        delete safe;

        emit Registered(lender, asset, rank);
        return rank;
    }

    function registerCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory data) external returns (bytes memory) {
        uint256 gasAtCallback = gasleft();
        require(safe, "Unauthorized callback");

        require(asset.balanceOf(loanReceiver) >= amount, "Loan not received");
        loanReceiver.retrieve(asset, amount);
        asset.approve(msg.sender, amount);

        IERC3156PPLender lender = IERC3156PPLender(msg.sender);
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
        uint256 index = lenderIndex[lender][asset];
        if (index == 0) {
            index = lenders.length;
            lenders.push(newLender);
            lenderIndex[lender][asset] = index;
        } else {
            Lender memory storedLender = lenders[index];
            if (newLender.amount >= storedLender.amount && newLender.fee <= storedLender.fee) {
                lenders[index] = newLender;
            }
        }

        // Update the top lenders for the given asset
        return abi.encode(_rank(newLender, index));
    }

    /// @dev Unregister an ERC3156++ flash loan lender for a given asset.
    function unregister(IERC3156PPLender lender, ERC20 asset) onlyOwner external {
        uint256 index = lenderIndex[lender][asset];
        require(index != 0, "Lender not registered");
        delete lenderIndex[lender][asset];
        delete lenders[index];

        uint256[3] memory topLenders_ = topLenders[asset];
        if (topLenders_[0] == index) {
            topLenders_[0] = topLenders_[1];
            topLenders_[1] = topLenders_[2];
            topLenders_[2] = 0;
        }
        if (topLenders_[1] == index) {
            topLenders_[1] = topLenders_[2];
            topLenders_[2] = 0;
        }
        if (topLenders_[2] == index) {
            topLenders_[2] = 0;
        }
        topLenders[asset] = topLenders_;

        emit Unregistered(lender, asset);
    }

    /// @dev Return the rank of the lender for the given asset, and update the top lenders if needed.
    function _rank(Lender memory newLender, uint256 index) internal returns (uint256 rank) {
        uint256[3] memory topLenders_ = topLenders[newLender.asset];

        Lender memory firstLender = lenders[topLenders_[0]];
        if (newLender.amount >= firstLender.amount && newLender.fee < firstLender.fee) {
            topLenders_[2] = topLenders_[1];
            topLenders_[1] = topLenders_[0];
            topLenders_[0] = index;
            return 0;
        }

        Lender memory secondLender = lenders[topLenders_[1]];
        if (newLender.amount >= secondLender.amount && newLender.fee < secondLender.fee) {
            topLenders_[2] = topLenders_[1];
            topLenders_[1] = index;
            return 1;
        }

        Lender memory thirdLender = lenders[topLenders_[2]];
        if (newLender.amount >= thirdLender.amount && newLender.fee < thirdLender.fee) {
            topLenders_[2] = index;
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
        function(address, ERC20, uint256, uint256, bytes memory, address) external returns (bytes memory) callback
    ) external returns (bytes memory) {
        require(!safe, "No reentrancy");
        safe = true;

        Lender storage storedLender = lenders[topLenders[0]];
        require(storedLender.lender != address(0), "No lender registered");
        (uint256 storedAmount, uint256 storedFee) = (storedLender.amount, storedLender.fee);

        // If the flash loan is more significant than the registered one, we update it
        if (amount >= storedAmount) {
            uint256 fee = storedLender.lender.flashFee(asset, amount); // We only do this call if it is the largest flash loan for this lender and asset
            if (fee * 1e18 / amount <= storedFee) {
                (storedLender.amount, storedLender.fee) = (amount, fee * 1e18 / amount);
                // We can't measure gas, so we just assume it is the same as it was
            }
        }

        // A malicious lender could serve zero fees to this contract, and then charge a fee to other users routed through here.
        // This contract has governance only to keep such malicious lenders out. If a lender is registered, it is assumed to be trusted.

        bytes memory result = storedLender.lender.flashLoan(
            loanReceiver,
            address(this),
            asset,
            amount,
            abi.encode(data, callbackReceiver, callback),
            this.forwardCallback(address, ERC20, uint256, uint256, bytes) // In many cases, for the callback receiver to trust the flash loan, the callback must come from a known contract. The aggregator contract can be used as a trusted forwarder.
        );
        delete safe;
        return result;
    }

    /// @dev Forward the callback to the callback receiver, acting as a trusted forwarder.
    function forwardCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory outerData) external returns (bytes memory) {
        require(safe, "Unauthorized callback");
        (
            bytes memory innerData,
            address callbackReceiver,
            function(address, ERC20, uint256, uint256, bytes memory) external returns (bytes memory) innerCallback
        ) = abi.decode(outerData, (
            bytes,
            address, 
            function(address, ERC20, uint256, uint256, bytes)
        ));
        return innerCallback(loanReceiver, asset, amount, fee, innerData);

    }
}
