// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract Counter {
    uint256 public count;
    address public owner;

    event Incremented(address indexed caller, uint256 newCount);
    event Reset(address indexed caller);

    error NotOwner(address caller);

    constructor() {
        owner = msg.sender;
    }

    function increment() external {
        count += 1;
        emit Incremented(msg.sender, count);
    }

    function reset() external {
        if (msg.sender != owner) {
            revert NotOwner(msg.sender);
        }

        count = 0;
        emit Reset(msg.sender);
    }
}
