// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal WETH9-style wrapper for tests.
/// - `deposit()` mints ERC20 1:1 to msg.sender
/// - `withdraw(wad)` burns from msg.sender and sends native
/// - `transfer/transferFrom/approve` implemented
contract MockWETH9 {
    string public name = "Mock Wrapped Native";
    string public symbol = "mWNATIVE";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "balance");
        unchecked {
            balanceOf[msg.sender] -= wad;
        }
        emit Transfer(msg.sender, address(0), wad);
        payable(msg.sender).transfer(wad);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    receive() external payable {}
}

