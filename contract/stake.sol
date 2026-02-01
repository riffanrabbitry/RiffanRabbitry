// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract RiffanRabbitryStaking {
    address public owner;
    IERC20 public rfnToken;
    
    // Reentrancy guard
    bool private _locked;
    
    // Pool configuration
    struct PoolConfig {
        uint256 lockPeriod;
        uint256 apy; // basis points (1000 = 10%)
        uint256 minRfnStake;       // Minimal stake RFN
        uint256 minNativeStake;    // Minimal stake Native (BNB) - dalam wei
        uint256 maxRfnStake;
        uint256 maxNativeStake;
        uint256 totalStaked;       // Total yang staked di pool ini (dalam satuan stake)
        uint256 totalStakers;      // Jumlah staker di pool
        bool active;
        uint256 lastUpdated;       // Timestamp terakhir update APY
    }
    
    struct UserStake {
        uint256 amount;
        uint256 stakeTime;
        uint256 unlockTime;
        uint256 rewardDebt;        // Reward yang akan diterima saat unlock
        bool isNative;
        uint8 poolId;
        bool unstaked;
        bool rewardsClaimed;
        uint256 apyAtStakeTime;    // APY saat user stake
    }
    
    // Withdrawal tracking untuk admin panel
    struct WithdrawalRecord {
        uint256 amount;
        bool isNative;
        uint256 withdrawTime;
        uint256 returnDeadline;
        bool returned;
        address returnedBy;
        uint256 returnTime;
    }
    
    // APY History untuk transparansi
    struct APYHistory {
        uint256 timestamp;
        uint256 apy;
        uint8 poolId;
        address updatedBy;
    }
    
    // Public variables
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public rewardPool;
    uint256 public totalStakers;
    
    // Price Oracle untuk konversi nilai (dapat diupdate oleh admin)
    uint256 public rfnPrice = 1476; // $0.001476 = 1476 (dalam 1e6)
    uint256 public nativePrice = 777000000; // $777 = 777000000 (dalam 1e6)
    uint256 public priceDecimals = 1e6;
    
    // 4 Pool configurations
    PoolConfig[4] public pools;
    mapping(address => UserStake[]) public userStakes;
    mapping(uint8 => uint256) public poolTotalStaked;
    mapping(address => mapping(uint8 => bool)) public hasStakedInPool;
    
    // Withdrawal tracking
    WithdrawalRecord[] public withdrawalRecords;
    mapping(uint256 => bool) public activeWithdrawals;
    
    // APY History tracking
    APYHistory[] public apyHistory;
    
    // Events
    event Staked(address indexed user, uint256 amount, bool isNative, uint8 poolId, uint256 unlockTime, uint256 apy);
    event Unstaked(address indexed user, uint256 amount, uint8 poolId);
    event RewardsClaimed(address indexed user, uint256 amount, uint8 poolId);
    event PoolUpdated(uint8 poolId, uint256 apy, uint256 minStake, uint256 lockPeriod, bool active);
    event EmergencyWithdraw(address token, uint256 amount);
    event RewardsAdded(uint256 amount);
    event NativeReceived(address from, uint256 amount);
    event ERC20Received(address token, address from, uint256 amount);
    event WithdrawalCreated(uint256 withdrawalId, uint256 amount, bool isNative, uint256 deadline);
    event FundsReturned(uint256 withdrawalId, uint256 amount, address returnedBy);
    event EmergencyAlert(string message, uint256 requiredAmount, uint256 deadline);
    event APYUpdated(uint8 poolId, uint256 oldAPY, uint256 newAPY, address updatedBy);
    event PricesUpdated(uint256 newRfnPrice, uint256 newNativePrice);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }
    
    modifier validPool(uint8 poolId) {
        require(poolId < 4, "Invalid pool");
        require(pools[poolId].active, "Pool inactive");
        _;
    }
    
    modifier validAmount(uint256 amount, bool isNative, uint8 poolId) {
        if (isNative) {
            require(amount >= pools[poolId].minNativeStake, "Below minimum Native stake");
            require(amount <= pools[poolId].maxNativeStake, "Exceeds maximum Native stake");
        } else {
            require(amount >= pools[poolId].minRfnStake, "Below minimum RFN stake");
            require(amount <= pools[poolId].maxRfnStake, "Exceeds maximum RFN stake");
        }
        _;
    }

    constructor(address _rfnToken) {
        owner = msg.sender;
        rfnToken = IERC20(_rfnToken);
        
        // HARGA ASUSMSI untuk konversi:
        // 1 RFN = $0.001476 = 1476 (dalam 1e6)
        // 1 BNB = $777 = 777000000 (dalam 1e6)
        // Minimal stake: $14.76
        
        // Calculate equivalent values
        // $14.76 in RFN = 14.76 / 0.001476 = 10,000 RFN
        // $14.76 in BNB = 14.76 / 777 = 0.019 BNB = 19 * 10^15 wei
        
        uint256 minRfnStake = 10000 * 10**18;      // 10,000 RFN
        uint256 minNativeStake = 19 * 10**15;      // 0.019 BNB
        uint256 maxRfnStake = 1000000 * 10**18;    // 1,000,000 RFN
        uint256 maxNativeStake = 2 * 10**18;       // 2 BNB
        
        // Initialize 4 pools dengan nilai SETARA
        pools[0] = PoolConfig({
            lockPeriod: 30 days,
            apy: 1500,                     // 15% APY
            minRfnStake: minRfnStake,
            minNativeStake: minNativeStake,
            maxRfnStake: maxRfnStake,
            maxNativeStake: maxNativeStake,
            totalStaked: 0,
            totalStakers: 0,
            active: true,
            lastUpdated: block.timestamp
        });
        
        pools[1] = PoolConfig({
            lockPeriod: 90 days,
            apy: 3500,                     // 35% APY
            minRfnStake: minRfnStake,
            minNativeStake: minNativeStake,
            maxRfnStake: maxRfnStake,
            maxNativeStake: maxNativeStake,
            totalStaked: 0,
            totalStakers: 0,
            active: true,
            lastUpdated: block.timestamp
        });
        
        pools[2] = PoolConfig({
            lockPeriod: 180 days,
            apy: 5500,                     // 55% APY
            minRfnStake: minRfnStake,
            minNativeStake: minNativeStake,
            maxRfnStake: maxRfnStake,
            maxNativeStake: maxNativeStake,
            totalStaked: 0,
            totalStakers: 0,
            active: true,
            lastUpdated: block.timestamp
        });
        
        pools[3] = PoolConfig({
            lockPeriod: 365 days,
            apy: 8500,                     // 85% APY
            minRfnStake: minRfnStake,
            minNativeStake: minNativeStake,
            maxRfnStake: maxRfnStake,
            maxNativeStake: maxNativeStake,
            totalStaked: 0,
            totalStakers: 0,
            active: true,
            lastUpdated: block.timestamp
        });
        
        // Record initial APY
        for (uint8 i = 0; i < 4; i++) {
            apyHistory.push(APYHistory({
                timestamp: block.timestamp,
                apy: pools[i].apy,
                poolId: i,
                updatedBy: owner
            }));
        }
        
        rewardPool = 0;
    }
    
    // ========== PRICE ORACLE FUNCTIONS ========== //
    
    function updatePrices(uint256 newRfnPrice, uint256 newNativePrice) external onlyOwner {
        require(newRfnPrice > 0, "Invalid RFN price");
        require(newNativePrice > 0, "Invalid Native price");
        
        rfnPrice = newRfnPrice;
        nativePrice = newNativePrice;
        
        emit PricesUpdated(newRfnPrice, newNativePrice);
    }
    
    // Convert RFN to USD value
    function rfnToUSD(uint256 rfnAmount) public view returns (uint256) {
        return (rfnAmount * rfnPrice) / (10**18 * priceDecimals);
    }
    
    // Convert Native to USD value
    function nativeToUSD(uint256 nativeAmount) public view returns (uint256) {
        return (nativeAmount * nativePrice) / (10**18 * priceDecimals);
    }
    
    // Get equivalent RFN amount for Native stake
    function getEquivalentRfn(uint256 nativeAmount) public view returns (uint256) {
        uint256 usdValue = nativeToUSD(nativeAmount);
        return (usdValue * 10**18 * priceDecimals) / rfnPrice;
    }
    
    // ========== STAKE FUNCTIONS ========== //
    
    function stakeNative(uint8 poolId) external payable nonReentrant validPool(poolId) {
        require(msg.value > 0, "Zero amount");
        
        PoolConfig storage pool = pools[poolId];
        require(msg.value >= pool.minNativeStake, "Below minimum Native stake");
        require(msg.value <= pool.maxNativeStake, "Exceeds maximum Native stake");
        
        // Calculate equivalent RFN for reward calculation
        uint256 equivalentRfn = getEquivalentRfn(msg.value);
        
        uint256 unlockTime = block.timestamp + pool.lockPeriod;
        uint256 reward = calculateReward(equivalentRfn, pool.apy, pool.lockPeriod);
        
        require(rewardPool >= reward, "Insufficient reward pool");
        
        // Update pool statistics
        if (!hasStakedInPool[msg.sender][poolId]) {
            pool.totalStakers++;
            hasStakedInPool[msg.sender][poolId] = true;
            totalStakers++;
        }
        
        userStakes[msg.sender].push(UserStake({
            amount: msg.value,
            stakeTime: block.timestamp,
            unlockTime: unlockTime,
            rewardDebt: reward,
            isNative: true,
            poolId: poolId,
            unstaked: false,
            rewardsClaimed: false,
            apyAtStakeTime: pool.apy
        }));
        
        pool.totalStaked += msg.value;
        poolTotalStaked[poolId] += msg.value;
        totalStaked += msg.value;
        
        emit Staked(msg.sender, msg.value, true, poolId, unlockTime, pool.apy);
    }
    
    function stakeRfn(uint256 amount, uint8 poolId) external nonReentrant validPool(poolId) {
        PoolConfig storage pool = pools[poolId];
        require(amount >= pool.minRfnStake, "Below minimum RFN stake");
        require(amount <= pool.maxRfnStake, "Exceeds maximum RFN stake");
        
        require(rfnToken.transferFrom(msg.sender, address(this), amount), "RFN transfer failed");
        
        uint256 unlockTime = block.timestamp + pool.lockPeriod;
        uint256 reward = calculateReward(amount, pool.apy, pool.lockPeriod);
        
        require(rewardPool >= reward, "Insufficient reward pool");
        
        // Update pool statistics
        if (!hasStakedInPool[msg.sender][poolId]) {
            pool.totalStakers++;
            hasStakedInPool[msg.sender][poolId] = true;
            totalStakers++;
        }
        
        userStakes[msg.sender].push(UserStake({
            amount: amount,
            stakeTime: block.timestamp,
            unlockTime: unlockTime,
            rewardDebt: reward,
            isNative: false,
            poolId: poolId,
            unstaked: false,
            rewardsClaimed: false,
            apyAtStakeTime: pool.apy
        }));
        
        pool.totalStaked += amount;
        poolTotalStaked[poolId] += amount;
        totalStaked += amount;
        
        emit Staked(msg.sender, amount, false, poolId, unlockTime, pool.apy);
    }
    
    // ========== UNSTAKE & CLAIM FUNCTIONS ========== //
    
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        UserStake storage stake = userStakes[msg.sender][stakeIndex];
        require(!stake.unstaked, "Already unstaked");
        require(block.timestamp >= stake.unlockTime, "Stake still locked");
        
        uint256 principal = stake.amount;
        
        // Transfer principal back
        if (stake.isNative) {
            payable(msg.sender).transfer(principal);
        } else {
            require(rfnToken.transfer(msg.sender, principal), "RFN transfer failed");
        }
        
        // Update totals
        pools[stake.poolId].totalStaked -= principal;
        poolTotalStaked[stake.poolId] -= principal;
        totalStaked -= principal;
        stake.unstaked = true;
        
        emit Unstaked(msg.sender, principal, stake.poolId);
    }
    
    function claimRewards(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        UserStake storage stake = userStakes[msg.sender][stakeIndex];
        require(!stake.unstaked, "Already unstaked");
        require(!stake.rewardsClaimed, "Rewards already claimed");
        require(block.timestamp >= stake.unlockTime, "Stake still locked");
        
        uint256 reward = stake.rewardDebt;
        require(reward > 0, "No rewards to claim");
        require(rewardPool >= reward, "Insufficient reward pool");
        
        // Transfer rewards
        require(rfnToken.transfer(msg.sender, reward), "Reward transfer failed");
        rewardPool -= reward;
        totalRewardsDistributed += reward;
        stake.rewardsClaimed = true;
        
        emit RewardsClaimed(msg.sender, reward, stake.poolId);
    }
    
    function claimAllRewards() external nonReentrant {
        uint256 totalReward;
        
        for (uint256 i = 0; i < userStakes[msg.sender].length; i++) {
            UserStake storage stake = userStakes[msg.sender][i];
            
            if (!stake.unstaked && 
                !stake.rewardsClaimed && 
                block.timestamp >= stake.unlockTime && 
                stake.rewardDebt > 0) {
                totalReward += stake.rewardDebt;
                stake.rewardsClaimed = true;
            }
        }
        
        require(totalReward > 0, "No rewards to claim");
        require(rewardPool >= totalReward, "Insufficient reward pool");
        
        require(rfnToken.transfer(msg.sender, totalReward), "Reward transfer failed");
        rewardPool -= totalReward;
        totalRewardsDistributed += totalReward;
        
        emit RewardsClaimed(msg.sender, totalReward, 99);
    }
    
    // ========== REWARD CALCULATION ========== //
    
    function calculateReward(uint256 amount, uint256 apy, uint256 duration) public pure returns (uint256) {
        uint256 base = (amount * apy) / 10000;
        return (base * duration) / 365 days;
    }
    
    // ========== APY MANAGEMENT (UPDATABLE) ========== //
    
    function updatePoolAPY(uint8 poolId, uint256 newApy) external onlyOwner {
        require(poolId < 4, "Invalid pool");
        require(newApy <= 10000, "APY too high"); // Max 100%
        
        uint256 oldApy = pools[poolId].apy;
        pools[poolId].apy = newApy;
        pools[poolId].lastUpdated = block.timestamp;
        
        // Record APY change in history
        apyHistory.push(APYHistory({
            timestamp: block.timestamp,
            apy: newApy,
            poolId: poolId,
            updatedBy: msg.sender
        }));
        
        emit APYUpdated(poolId, oldApy, newApy, msg.sender);
        emit PoolUpdated(poolId, newApy, pools[poolId].minRfnStake, pools[poolId].lockPeriod, pools[poolId].active);
    }
    
    function updatePoolConfig(
        uint8 poolId, 
        uint256 newApy, 
        uint256 newMinRfn, 
        uint256 newMinNative,
        uint256 newMaxRfn,
        uint256 newMaxNative,
        uint256 newLockPeriod,
        bool isActive
    ) external onlyOwner {
        require(poolId < 4, "Invalid pool");
        require(newApy <= 10000, "APY too high");
        
        uint256 oldApy = pools[poolId].apy;
        
        pools[poolId].apy = newApy;
        pools[poolId].minRfnStake = newMinRfn;
        pools[poolId].minNativeStake = newMinNative;
        pools[poolId].maxRfnStake = newMaxRfn;
        pools[poolId].maxNativeStake = newMaxNative;
        pools[poolId].lockPeriod = newLockPeriod;
        pools[poolId].active = isActive;
        pools[poolId].lastUpdated = block.timestamp;
        
        // Record APY change if it's different
        if (oldApy != newApy) {
            apyHistory.push(APYHistory({
                timestamp: block.timestamp,
                apy: newApy,
                poolId: poolId,
                updatedBy: msg.sender
            }));
            emit APYUpdated(poolId, oldApy, newApy, msg.sender);
        }
        
        emit PoolUpdated(poolId, newApy, newMinRfn, newLockPeriod, isActive);
    }
    
    // ========== REWARD POOL MANAGEMENT ========== //
    
    function addRewards(uint256 amount) external onlyOwner {
        require(rfnToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        rewardPool += amount;
        emit RewardsAdded(amount);
    }
    
    // ========== WITHDRAWAL TRACKING SYSTEM ========== //
    
    function emergencyWithdrawNative(uint256 amount) external onlyOwner {
        uint256 availableBalance = address(this).balance;
        uint256 requiredForStakers = _getTotalNativeNeeded();
        uint256 trulyAvailable = availableBalance > requiredForStakers ? availableBalance - requiredForStakers : 0;
        
        require(trulyAvailable >= amount, "Insufficient available Native");
        
        uint256 withdrawalId = withdrawalRecords.length;
        uint256 deadline = block.timestamp + _calculateSafetyPeriod();
        
        withdrawalRecords.push(WithdrawalRecord({
            amount: amount,
            isNative: true,
            withdrawTime: block.timestamp,
            returnDeadline: deadline,
            returned: false,
            returnedBy: address(0),
            returnTime: 0
        }));
        
        activeWithdrawals[withdrawalId] = true;
        
        payable(owner).transfer(amount);
        
        _checkEmergencyAlerts();
        
        emit EmergencyWithdraw(address(0), amount);
        emit WithdrawalCreated(withdrawalId, amount, true, deadline);
    }
    
    function emergencyWithdrawRfn(uint256 amount) external onlyOwner {
        uint256 totalBalance = rfnToken.balanceOf(address(this));
        uint256 lockedBalance = rewardPool + _getTotalRfnStaked();
        uint256 availableBalance = totalBalance > lockedBalance ? totalBalance - lockedBalance : 0;
        
        require(availableBalance >= amount, "Insufficient available RFN");
        
        uint256 withdrawalId = withdrawalRecords.length;
        uint256 deadline = block.timestamp + _calculateSafetyPeriod();
        
        withdrawalRecords.push(WithdrawalRecord({
            amount: amount,
            isNative: false,
            withdrawTime: block.timestamp,
            returnDeadline: deadline,
            returned: false,
            returnedBy: address(0),
            returnTime: 0
        }));
        
        activeWithdrawals[withdrawalId] = true;
        
        require(rfnToken.transfer(owner, amount), "RFN transfer failed");
        
        _checkEmergencyAlerts();
        
        emit EmergencyWithdraw(address(rfnToken), amount);
        emit WithdrawalCreated(withdrawalId, amount, false, deadline);
    }
    
    function returnWithdrawnFunds(uint256 withdrawalId) external payable onlyOwner {
        require(withdrawalId < withdrawalRecords.length, "Invalid withdrawal ID");
        require(!withdrawalRecords[withdrawalId].returned, "Funds already returned");
        
        WithdrawalRecord storage record = withdrawalRecords[withdrawalId];
        
        if (record.isNative) {
            require(msg.value == record.amount, "Incorrect Native amount");
        } else {
            require(rfnToken.transferFrom(msg.sender, address(this), record.amount), "RFN transfer failed");
        }
        
        record.returned = true;
        record.returnedBy = msg.sender;
        record.returnTime = block.timestamp;
        activeWithdrawals[withdrawalId] = false;
        
        emit FundsReturned(withdrawalId, record.amount, msg.sender);
    }
    
    // ========== EMERGENCY ALERT SYSTEM ========== //
    
    function _checkEmergencyAlerts() internal {
        uint256 totalNativeNeeded = _getTotalNativeNeeded();
        uint256 totalRfnNeeded = _getTotalRfnNeeded();
        
        uint256 earliestDeadline = type(uint256).max;
        
        for (uint256 i = 0; i < withdrawalRecords.length; i++) {
            if (activeWithdrawals[i] && withdrawalRecords[i].returnDeadline < earliestDeadline) {
                earliestDeadline = withdrawalRecords[i].returnDeadline;
            }
        }
        
        if (totalNativeNeeded > 0) {
            emit EmergencyAlert(
                "EMERGENCY: Insufficient Native for unstaking", 
                totalNativeNeeded, 
                earliestDeadline
            );
        }
        
        if (totalRfnNeeded > 0) {
            emit EmergencyAlert(
                "EMERGENCY: Insufficient RFN for rewards", 
                totalRfnNeeded, 
                earliestDeadline
            );
        }
    }
    
    function _getTotalNativeNeeded() internal view returns (uint256) {
        uint256 totalStakedNative = _getTotalNativeStaked();
        uint256 contractNativeBalance = address(this).balance;
        
        if (contractNativeBalance >= totalStakedNative) {
            return 0;
        }
        return totalStakedNative - contractNativeBalance;
    }
    
    function _getTotalRfnNeeded() internal view returns (uint256) {
        uint256 totalNeeded = rewardPool + _getTotalRfnStaked();
        uint256 contractRfnBalance = rfnToken.balanceOf(address(this));
        
        if (contractRfnBalance >= totalNeeded) {
            return 0;
        }
        return totalNeeded - contractRfnBalance;
    }
    
    function _getTotalNativeStaked() internal view returns (uint256) {
        uint256 total = 0;
        for (uint8 i = 0; i < 4; i++) {
            total += pools[i].totalStaked;
        }
        return total;
    }
    
    function _getTotalRfnStaked() internal view returns (uint256) {
        return totalStaked - _getTotalNativeStaked();
    }
    
    function _calculateSafetyPeriod() internal view returns (uint256) {
        uint256 earliestUnlock = type(uint256).max;
        
        for (uint8 poolId = 0; poolId < 4; poolId++) {
            uint256 poolUnlockTime = block.timestamp + pools[poolId].lockPeriod;
            if (poolUnlockTime < earliestUnlock) {
                earliestUnlock = poolUnlockTime;
            }
        }
        
        return earliestUnlock > block.timestamp ? earliestUnlock - block.timestamp - 1 days : 1 days;
    }
    
    // ========== VIEW FUNCTIONS ========== //
    
    function getUserStakes(address user) external view returns (UserStake[] memory) {
        return userStakes[user];
    }
    
    function getClaimableRewards(address user) external view returns (uint256 totalRewards) {
        UserStake[] memory stakes = userStakes[user];
        for (uint i = 0; i < stakes.length; i++) {
            if (!stakes[i].unstaked && 
                !stakes[i].rewardsClaimed && 
                block.timestamp >= stakes[i].unlockTime) {
                totalRewards += stakes[i].rewardDebt;
            }
        }
        return totalRewards;
    }
    
    function getPendingRewards(address user) external view returns (uint256 totalPending) {
        UserStake[] memory stakes = userStakes[user];
        for (uint i = 0; i < stakes.length; i++) {
            if (!stakes[i].unstaked && !stakes[i].rewardsClaimed) {
                if (block.timestamp >= stakes[i].unlockTime) {
                    totalPending += stakes[i].rewardDebt;
                } else {
                    // Calculate partial rewards based on elapsed time
                    uint256 elapsed = block.timestamp - stakes[i].stakeTime;
                    if (elapsed > 0) {
                        uint256 fullReward = stakes[i].rewardDebt;
                        uint256 pending = (fullReward * elapsed) / (stakes[i].unlockTime - stakes[i].stakeTime);
                        totalPending += pending;
                    }
                }
            }
        }
        return totalPending;
    }
    
    function getPoolInfo(uint8 poolId) external view returns (PoolConfig memory) {
        require(poolId < 4, "Invalid pool");
        return pools[poolId];
    }
    
    function getContractBalance() external view returns (uint256 rfnBalance, uint256 nativeBalance, uint256 availableRewardPool) {
        rfnBalance = rfnToken.balanceOf(address(this));
        nativeBalance = address(this).balance;
        availableRewardPool = rewardPool;
    }
    
    function getActiveWithdrawals() external view returns (WithdrawalRecord[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < withdrawalRecords.length; i++) {
            if (activeWithdrawals[i]) {
                activeCount++;
            }
        }
        
        WithdrawalRecord[] memory active = new WithdrawalRecord[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < withdrawalRecords.length; i++) {
            if (activeWithdrawals[i]) {
                active[index] = withdrawalRecords[i];
                index++;
            }
        }
        return active;
    }
    
    function getEmergencyStatus() external view returns (
        uint256 nativeNeeded,
        uint256 rfnNeeded, 
        uint256 earliestDeadline,
        bool isEmergency
    ) {
        nativeNeeded = _getTotalNativeNeeded();
        rfnNeeded = _getTotalRfnNeeded();
        earliestDeadline = type(uint256).max;
        
        for (uint256 i = 0; i < withdrawalRecords.length; i++) {
            if (activeWithdrawals[i] && withdrawalRecords[i].returnDeadline < earliestDeadline) {
                earliestDeadline = withdrawalRecords[i].returnDeadline;
            }
        }
        
        isEmergency = (nativeNeeded > 0) || (rfnNeeded > 0);
        
        return (nativeNeeded, rfnNeeded, earliestDeadline, isEmergency);
    }
    
    function getAPYHistory(uint8 poolId, uint256 limit) external view returns (APYHistory[] memory) {
        require(poolId < 4, "Invalid pool");
        
        uint256 count = 0;
        for (uint256 i = 0; i < apyHistory.length; i++) {
            if (apyHistory[i].poolId == poolId) {
                count++;
            }
        }
        
        if (limit > 0 && limit < count) {
            count = limit;
        }
        
        APYHistory[] memory history = new APYHistory[](count);
        uint256 index = 0;
        
        for (uint256 i = apyHistory.length; i > 0 && index < count; i--) {
            if (apyHistory[i-1].poolId == poolId) {
                history[index] = apyHistory[i-1];
                index++;
            }
        }
        
        return history;
    }
    
    function getStakingStats() external view returns (
        uint256 totalStakedValue,
        uint256 totalStakersCount,
        uint256 totalPoolsActive,
        uint256[4] memory poolStakers
    ) {
        totalStakedValue = totalStaked;
        totalStakersCount = totalStakers;
        
        uint256 activePools = 0;
        for (uint8 i = 0; i < 4; i++) {
            if (pools[i].active) {
                activePools++;
            }
            poolStakers[i] = pools[i].totalStakers;
        }
        
        totalPoolsActive = activePools;
        
        return (totalStakedValue, totalStakersCount, totalPoolsActive, poolStakers);
    }
    
    // ========== OWNERSHIP MANAGEMENT ========== //
    
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    // ========== RECEIVE & FALLBACK ========== //
    
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
    
    fallback() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
}