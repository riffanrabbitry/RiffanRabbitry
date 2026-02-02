
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Riffan Rabbitry Token (RFN)
 * @dev Aman, Clean, Fixed Supply, No Burn, No Pause
 */
contract RiffanRabbitryToken is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Token information - CONSTANT untuk menghindari honeypot detection
    string private constant TOKEN_NAME = "Riffan Rabbitry Token";
    string private constant TOKEN_SYMBOL = "RFN";
    uint8 private constant DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 27_000_000 * 10**18; // 27 juta RFN
    
    // Events
    event NativeReceived(address indexed from, uint256 value);
    event NativeWithdrawn(address indexed to, uint256 value);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    
    // Constructor - simple dan clean
    constructor(address initialOwner) 
        ERC20(TOKEN_NAME, TOKEN_SYMBOL) 
        Ownable(initialOwner)
    {
        require(initialOwner != address(0), "RFN: owner is zero address");
        
        // Mint semua supply ke owner sekali saja
        _mint(initialOwner, MAX_SUPPLY);
    }
    
    // ==================== STANDARD ERC20 OVERRIDES ====================
    
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    // ==================== NATIVE TOKEN HANDLING ====================
    
    // Receive native token (BNB/ETH)
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
    
    // Fallback function
    fallback() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
    
    // Owner dapat menarik native token dari kontrak
    function withdrawNative(uint256 amount) external onlyOwner nonReentrant {
        require(address(this).balance >= amount, "RFN: insufficient balance");
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "RFN: transfer failed");
        
        emit NativeWithdrawn(owner(), amount);
    }
    
    // Owner dapat menarik semua native token
    function withdrawAllNative() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "RFN: no native tokens");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "RFN: transfer failed");
        
        emit NativeWithdrawn(owner(), balance);
    }
    
    // ==================== ERC20 TOKEN RECOVERY ====================
    
    // Owner dapat menarik token ERC20 yang salah dikirim ke kontrak ini
    function recoverERC20(address tokenAddress, uint256 amount) 
        external 
        onlyOwner 
        nonReentrant 
    {
        require(tokenAddress != address(this), "RFN: cannot recover RFN tokens");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "RFN: insufficient token balance");
        
        token.safeTransfer(owner(), amount);
        emit ERC20Recovered(tokenAddress, owner(), amount);
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    // Cek native balance kontrak
    function getNativeBalance() public view returns (uint256) {
        return address(this).balance;
    }
    
    // Cek balance token ERC20 di kontrak
    function getERC20Balance(address tokenAddress) public view returns (uint256) {
        return IERC20(tokenAddress).balanceOf(address(this));
    }
    
    // ==================== OWNERSHIP MANAGEMENT ====================
    
    // Transfer ownership dengan safety check
    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "RFN: new owner is zero address");
        require(newOwner != owner(), "RFN: same owner");
        
        _transferOwnership(newOwner);
    }
}
