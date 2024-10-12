pragma solidity 0.8.13;

import {Borrowable} from "./Borrowable.sol";
import {IBDeployer} from "./interfaces/IBDeployer.sol";

/// @title Borrowable Deployer
/// @author Chainvisions
/// @notice Contract for deploying Borrowable contracts.

contract BDeployer is IBDeployer {
    constructor() public {}

    function deployBorrowable(
        address uniswapV2Pair,
        uint8 index
    ) external returns (address borrowable) {
        bytes memory bytecode = type(Borrowable).creationCode;
        bytes32 salt = keccak256(
            abi.encodePacked(msg.sender, uniswapV2Pair, index)
        );
        assembly {
            borrowable := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
    }
}

