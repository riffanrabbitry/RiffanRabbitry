// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract RFNPresale is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // Hardcoded addresses - HARUS DIUPDATE SEBELUM DEPLOY
    address public constant RFN_TOKEN = 0x603fcF9aCEDAB68007fd82d86913A88c1d41A6b2; // ALAMAT TOKEN RFN
    address public constant WALLET_OWNER = 0x379c7600ac527a60592a880f72140d432577e8da; // ALAMAT WALLET OWNER

    // Token information
    IERC20 public rfnToken;
    uint256 public constant TOTAL_SUPPLY = 27_000_000 * 10**18; // 27 juta RFN
    uint256 public constant PRESALE_PERCENTAGE = 30; // 30% untuk presale
    uint256 public constant PRESALE_TOKENS = TOTAL_SUPPLY * PRESALE_PERCENTAGE / 100; // 8.1 juta RFN

    // Presale configuration (dalam BNB)
    uint256 public constant MINI_CAP_BNB = 5 * 10**18; // 5 BNB (minimum untuk start)
    uint256 public constant SOFT_CAP_BNB = 10 * 10**18; // 10 BNB (soft cap)
    uint256 public constant HARD_CAP_BNB = 20 * 10**18; // 20 BNB (hard cap)
    uint256 public constant MIN_CONTRIBUTION = 5 * 10**15; // 0.005 BNB minimum
    uint256 public constant MAX_CONTRIBUTION = 5 * 10**17; // 0.5 BNB maximum per address
    uint256 public constant PRESALE_DURATION = 30 days; // 30 hari presale

    // Price calculation: 1 BNB = ? RFN
    // 20 BNB = 8,100,000 RFN -> 1 BNB = 405,000 RFN
    uint256 public constant TOKENS_PER_BNB = 405_000 * 10**18; // 405,000 RFN per BNB

    // Presale state
    uint256 public totalRaised; // Dalam BNB
    uint256 public startTime;
    uint256 public endTime;
    bool public presaleFinalized;
    bool public miniCapReached; // Baru: mini cap (5 BNB)
    bool public softCapReached;
    bool public presaleStarted;
    bool public hardCapReached;
    bool public emergencyPaused; // Fitur pause emergency

    // Vesting configuration
    uint256 public constant CLIFF_DURATION = 2 weeks;
    uint256 public constant VESTING_DURATION = 180 days; // 6 bulan vesting
    uint256 public constant RELEASE_INTERVAL = 30 days; // Claim setiap bulan
    uint256 public constant CLIFF_PERCENTAGE = 25; // 25% release di cliff
    uint256 public constant VESTING_PERCENTAGE = 75; // 75% vesting

    // Participant information
    struct Participant {
        uint256 contributed; // Dalam BNB
        uint256 tokensBought; // Dalam RFN
        uint256 tokensClaimed;
        uint256 lastClaimTime;
        bool refunded;
    }

    mapping(address => Participant) public participants;
    address[] public participantAddresses;

    // Events
    event PresaleStarted(uint256 startTime, uint256 endTime);
    event TokensPurchased(address indexed buyer, uint256 bnbAmount, uint256 tokenAmount);
    event TokensClaimed(address indexed claimer, uint256 amount);
    event RefundClaimed(address indexed refundee, uint256 amount);
    event PresaleFinalized(bool success, uint256 totalRaised);
    event FundsWithdrawn(address indexed owner, uint256 amount);
    event MiniCapReached(uint256 totalRaised, uint256 timestamp);
    event SoftCapReached(uint256 totalRaised, uint256 timestamp);
    event HardCapReached(uint256 totalRaised, uint256 timestamp);
    event PresaleEndedEarly(uint256 totalRaised, uint256 timestamp);
    event PresalePaused(bool paused, uint256 timestamp);
    event PresaleExtended(uint256 newEndTime);

    constructor() Ownable(WALLET_OWNER) {
        rfnToken = IERC20(RFN_TOKEN);
    }

    // Modifiers
    modifier presaleActive() {
        require(presaleStarted, "Presale not started");
        require(!emergencyPaused, "Presale is paused");
        require(block.timestamp >= startTime, "Presale not started yet");
        require(block.timestamp <= endTime, "Presale ended");
        require(!presaleFinalized, "Presale finalized");
        require(!hardCapReached, "Hard cap reached");
        _;
    }

    modifier presaleEnded() {
        require(presaleStarted, "Presale not started");
        require(block.timestamp > endTime || presaleFinalized || hardCapReached, "Presale not ended");
        _;
    }

    modifier onlyParticipant() {
        require(participants[msg.sender].contributed > 0, "Not a participant");
        _;
    }

    modifier whenNotPaused() {
        require(!emergencyPaused, "Presale is paused");
        _;
    }

    // Start presale function - only owner
    function startPresale() external onlyOwner {
        require(!presaleStarted, "Presale already started");
        
        // Check if owner has enough RFN tokens
        uint256 ownerBalance = rfnToken.balanceOf(WALLET_OWNER);
        require(ownerBalance >= PRESALE_TOKENS, "Owner doesn't have enough RFN tokens");
        
        presaleStarted = true;
        startTime = block.timestamp;
        endTime = block.timestamp + PRESALE_DURATION;
        hardCapReached = false;
        emergencyPaused = false;

        emit PresaleStarted(startTime, endTime);
    }

    // Buy tokens with BNB - with auto-end when hardcap reached
    function buyTokens() external payable presaleActive nonReentrant {
        require(msg.value >= MIN_CONTRIBUTION, "Contribution too low");
        require(msg.value <= MAX_CONTRIBUTION, "Contribution too high");
        require(totalRaised + msg.value <= HARD_CAP_BNB, "Hard cap reached");

        Participant storage participant = participants[msg.sender];
        
        // Check total contribution per address
        uint256 newContribution = participant.contributed + msg.value;
        require(newContribution <= MAX_CONTRIBUTION, "Max contribution per address exceeded");

        // Calculate tokens to allocate
        uint256 tokensToAllocate = calculateTokens(msg.value);
        require(tokensToAllocate > 0, "Token calculation error");

        // First time contributor
        if (participant.contributed == 0) {
            participantAddresses.push(msg.sender);
        }

        // Update participant info
        participant.contributed = newContribution;
        participant.tokensBought += tokensToAllocate;

        // Update total raised
        totalRaised += msg.value;

        // Check if mini cap is reached (5 BNB)
        if (!miniCapReached && totalRaised >= MINI_CAP_BNB) {
            miniCapReached = true;
            emit MiniCapReached(totalRaised, block.timestamp);
        }

        // Check if soft cap is reached (10 BNB)
        if (!softCapReached && totalRaised >= SOFT_CAP_BNB) {
            softCapReached = true;
            emit SoftCapReached(totalRaised, block.timestamp);
        }

        // Check if hard cap is reached (20 BNB) - AUTO END PRESALE
        if (totalRaised >= HARD_CAP_BNB) {
            hardCapReached = true;
            endTime = block.timestamp; // End presale immediately
            emit HardCapReached(totalRaised, block.timestamp);
            emit PresaleEndedEarly(totalRaised, block.timestamp);
        }

        emit TokensPurchased(msg.sender, msg.value, tokensToAllocate);
    }

    // Calculate tokens based on BNB amount
    function calculateTokens(uint256 bnbAmount) public pure returns (uint256) {
        return bnbAmount * TOKENS_PER_BNB / 10**18;
    }

    // Claim tokens after presale
    function claimTokens() external presaleEnded nonReentrant onlyParticipant whenNotPaused {
        require(presaleFinalized, "Presale not finalized");
        require(softCapReached, "Soft cap not reached - use refund instead");
        
        Participant storage participant = participants[msg.sender];
        require(!participant.refunded, "Already refunded");
        require(participant.tokensBought > 0, "No tokens to claim");
        require(participant.tokensClaimed < participant.tokensBought, "All tokens already claimed");

        uint256 claimableTokens = getClaimableTokens(msg.sender);
        require(claimableTokens > 0, "No tokens claimable at this time");

        // Check contract token balance
        uint256 contractBalance = rfnToken.balanceOf(address(this));
        require(contractBalance >= claimableTokens, "Insufficient tokens in contract");

        participant.tokensClaimed += claimableTokens;
        participant.lastClaimTime = block.timestamp;

        bool success = rfnToken.transfer(msg.sender, claimableTokens);
        require(success, "Token transfer failed");

        emit TokensClaimed(msg.sender, claimableTokens);
    }

    // Claim refund if soft cap not reached
    function claimRefund() external presaleEnded nonReentrant onlyParticipant {
        require(presaleFinalized, "Presale not finalized");
        require(!softCapReached, "Soft cap reached - claim tokens instead");
        
        Participant storage participant = participants[msg.sender];
        require(!participant.refunded, "Already refunded");
        require(participant.contributed > 0, "No contribution to refund");

        uint256 refundAmount = participant.contributed;
        participant.refunded = true;

        // Check contract balance
        require(address(this).balance >= refundAmount, "Insufficient contract balance");

        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "Refund transfer failed");

        emit RefundClaimed(msg.sender, refundAmount);
    }

    // Finalize presale - only owner (with auto BNB withdrawal to owner)
    function finalizePresale() external onlyOwner presaleEnded {
        require(!presaleFinalized, "Presale already finalized");
        require(miniCapReached, "Mini cap (5 BNB) not reached");

        presaleFinalized = true;

        // Auto withdraw BNB to owner wallet if soft cap reached
        if (softCapReached) {
            uint256 raisedAmount = address(this).balance;
            if (raisedAmount > 0) {
                (bool success, ) = payable(WALLET_OWNER).call{value: raisedAmount}("");
                require(success, "Funds transfer to owner failed");
            }

            // Transfer RFN tokens to contract for distribution
            uint256 tokensToTransfer = PRESALE_TOKENS;
            bool tokenSuccess = rfnToken.transferFrom(WALLET_OWNER, address(this), tokensToTransfer);
            require(tokenSuccess, "Token transfer to contract failed");
        }

        emit PresaleFinalized(softCapReached, totalRaised);
    }

    // Pause/unpause presale (emergency only)
    function setPause(bool _paused) external onlyOwner {
        emergencyPaused = _paused;
        emit PresalePaused(_paused, block.timestamp);
    }

    // Extend presale duration
    function extendPresale(uint256 _additionalDays) external onlyOwner {
        require(presaleStarted && !presaleFinalized, "Presale not active");
        require(_additionalDays > 0, "Invalid extension");
        require(_additionalDays <= 30, "Max 30 days extension");
        
        endTime += _additionalDays * 1 days;
        emit PresaleExtended(endTime);
    }

    // Manual BNB withdrawal to owner (if needed)
    function withdrawToOwner() external onlyOwner {
        require(softCapReached || presaleFinalized, "Cannot withdraw before finalization");
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        
        (bool success, ) = payable(WALLET_OWNER).call{value: balance}("");
        require(success, "Withdrawal to owner failed");
        
        emit FundsWithdrawn(WALLET_OWNER, balance);
    }

    // Add RFN tokens to contract manually (if needed)
    function addTokensToContract(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        bool success = rfnToken.transferFrom(WALLET_OWNER, address(this), amount);
        require(success, "Token transfer failed");
    }

    // Emergency withdraw if something goes wrong - only owner
    function emergencyWithdraw() external onlyOwner {
        require(block.timestamp > endTime + 30 days, "Can only emergency withdraw 30 days after presale");
        require(!presaleFinalized, "Presale already finalized");

        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(WALLET_OWNER).call{value: balance}("");
            require(success, "Emergency withdraw failed");
        }

        // Return any RFN tokens to owner
        uint256 tokenBalance = rfnToken.balanceOf(address(this));
        if (tokenBalance > 0) {
            rfnToken.transfer(WALLET_OWNER, tokenBalance);
        }
    }

    // Calculate claimable tokens for an address
    function getClaimableTokens(address _participant) public view returns (uint256) {
        Participant memory participant = participants[_participant];
        
        if (participant.tokensBought == 0 || participant.refunded) {
            return 0;
        }

        if (!presaleFinalized || !softCapReached) {
            return 0;
        }

        uint256 cliffEndTime = endTime + CLIFF_DURATION;
        
        // Before cliff ends, no tokens claimable
        if (block.timestamp < cliffEndTime) {
            return 0;
        }

        // Calculate total claimable amount
        uint256 totalClaimable = calculateTotalClaimable(participant);
        uint256 alreadyClaimed = participant.tokensClaimed;
        
        if (totalClaimable <= alreadyClaimed) {
            return 0;
        }

        return totalClaimable - alreadyClaimed;
    }

    // Calculate total claimable tokens (cliff + vesting)
    function calculateTotalClaimable(Participant memory participant) internal view returns (uint256) {
        uint256 cliffEndTime = endTime + CLIFF_DURATION;
        uint256 vestingEndTime = cliffEndTime + VESTING_DURATION;

        // Before cliff, no tokens
        if (block.timestamp < cliffEndTime) {
            return 0;
        }

        // Calculate cliff tokens (25%)
        uint256 cliffTokens = participant.tokensBought * CLIFF_PERCENTAGE / 100;

        // After vesting period, all tokens are claimable
        if (block.timestamp >= vestingEndTime) {
            return participant.tokensBought;
        }

        // During vesting period
        uint256 timeInVesting = block.timestamp - cliffEndTime;
        uint256 totalVestingIntervals = VESTING_DURATION / RELEASE_INTERVAL;
        uint256 intervalsPassed = timeInVesting / RELEASE_INTERVAL;
        
        uint256 vestingTokensPerInterval = (participant.tokensBought * VESTING_PERCENTAGE / 100) / totalVestingIntervals;
        uint256 vestingTokensClaimable = intervalsPassed * vestingTokensPerInterval;

        return cliffTokens + vestingTokensClaimable;
    }

    // Get participant count
    function getParticipantCount() external view returns (uint256) {
        return participantAddresses.length;
    }

    // Get contract BNB balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Get contract RFN token balance
    function getTokenBalance() external view returns (uint256) {
        return rfnToken.balanceOf(address(this));
    }

    // Get participant info
    function getParticipantInfo(address _participant) external view returns (
        uint256 contributed,
        uint256 tokensBought,
        uint256 tokensClaimed,
        uint256 lastClaimTime,
        bool refunded,
        uint256 claimableTokens
    ) {
        Participant memory p = participants[_participant];
        contributed = p.contributed;
        tokensBought = p.tokensBought;
        tokensClaimed = p.tokensClaimed;
        lastClaimTime = p.lastClaimTime;
        refunded = p.refunded;
        claimableTokens = getClaimableTokens(_participant);
    }

    // Get presale status
    function getPresaleStatus() external view returns (
        uint256 _totalRaised,
        uint256 _participants,
        bool _isActive,
        bool _isFinalized,
        bool _miniCapReached,
        bool _softCapReached,
        bool _isStarted,
        bool _hardCapReached,
        uint256 _timeRemaining,
        uint256 _contractTokenBalance,
        bool _isPaused
    ) {
        _totalRaised = totalRaised;
        _participants = participantAddresses.length;
        _isStarted = presaleStarted;
        _isActive = (presaleStarted && block.timestamp >= startTime && block.timestamp <= endTime && !presaleFinalized && !hardCapReached && !emergencyPaused);
        _isFinalized = presaleFinalized;
        _miniCapReached = miniCapReached;
        _softCapReached = softCapReached;
        _hardCapReached = hardCapReached;
        _timeRemaining = presaleStarted && block.timestamp < endTime && !hardCapReached ? endTime - block.timestamp : 0;
        _contractTokenBalance = rfnToken.balanceOf(address(this));
        _isPaused = emergencyPaused;
    }

    // Get remaining tokens for sale
    function getRemainingTokens() external view returns (uint256) {
        uint256 soldTokens = calculateTokens(totalRaised);
        return PRESALE_TOKENS - soldTokens;
    }

    // Get BNB raised percentage
    function getRaisedPercentage() external view returns (uint256) {
        return totalRaised * 100 / HARD_CAP_BNB;
    }

    // Receive function - prevent direct transfers
    receive() external payable {
        revert("Please use buyTokens() function");
    }

    // Fallback function
    fallback() external payable {
        revert("Please use buyTokens() function");
    }
}