// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    error InsufficientAllowance(uint256 currentAllowance, uint256 value);
    error InsufficientBalance(uint256 currentBalance, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance < value) {
            revert InsufficientAllowance(currentAllowance, value);
        }

        allowance[from][msg.sender] = currentAllowance - value;
        emit Approval(from, msg.sender, allowance[from][msg.sender]);

        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        uint256 currentBalance = balanceOf[from];
        if (currentBalance < value) {
            revert InsufficientBalance(currentBalance, value);
        }

        balanceOf[from] = currentBalance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
