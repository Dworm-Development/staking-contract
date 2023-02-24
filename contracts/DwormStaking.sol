// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface Token {
    function transferFrom(
        address,
        address,
        uint256
    ) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract DwormStakingV1 is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardsPoolTransferred(address owner, uint256 amount);
    event RewardsTransferred(address holder, uint256 amount);
    event Paused();
    event Unpaused();

    address public constant dwormAddress =
        0x1bc9E0F6FE0B4F38eFF1f19a92476240d76a0f1f; // $Dworm Mainet

    // APR 333.00% per year
    uint256 public APR = 33300;
    uint256 public constant rewardInterval = 365 days;

    uint256 public totalClaimedRewards = 0;
    bool public applyWithdrawPenalty = true;

    // Penalties
    // 0-5 days, 15%
    uint256 public constant penalty5Percent = 500;
    // 0-5 days, 15%
    uint256 public constant penalty4Percent = 400;
    // 0-5 days, 15%
    uint256 public constant penalty3Percent = 300;
    // 0-5 days, 15%
    uint256 public constant penalty2Percent = 200;

    EnumerableSet.AddressSet private holders;

    mapping(address => uint256) public depositedDworm;
    mapping(address => uint256) public stakingTime;
    mapping(address => uint256) public lastClaimedTime;
    mapping(address => uint256) public totalEarnedTokens;

    function updateAccount(address account) private {
        uint256 pendingDivs = getPendingDivs(account);
        if (pendingDivs > 0) {
            require(
                Token(dwormAddress).transfer(account, pendingDivs),
                "Could not transfer tokens."
            );
            totalEarnedTokens[account] = totalEarnedTokens[account].add(
                pendingDivs
            );
            totalClaimedRewards = totalClaimedRewards.add(pendingDivs);
            emit RewardsTransferred(account, pendingDivs);
        }
        lastClaimedTime[account] = block.timestamp;
    }

    function getPendingDivs(address _holder) public view returns (uint256) {
        if (!holders.contains(_holder)) return 0;
        if (depositedDworm[_holder] == 0) return 0;

        uint256 timeDiff = block.timestamp.sub(lastClaimedTime[_holder]);
        uint256 stakedAmount = depositedDworm[_holder];

        uint256 pendingDivs = stakedAmount
            .mul(APR)
            .mul(timeDiff)
            .div(rewardInterval)
            .div(1e4);

        return pendingDivs;
    }

    function getNumberOfHolders() public view returns (uint256) {
        return holders.length();
    }

    function deposit(uint256 amount) public nonReentrant whenNotPaused {
        require(amount > 0, "Cannot deposit 0 Tokens");
        require(
            Token(dwormAddress).transferFrom(
                msg.sender,
                address(this),
                amount
            ),
            "Insufficient Token Allowance"
        );

        updateAccount(msg.sender);

        depositedDworm[msg.sender] = depositedDworm[msg.sender].add(
            amount
        );

        if (!holders.contains(msg.sender)) {
            holders.add(msg.sender);
            stakingTime[msg.sender] = block.timestamp;
        }

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amountToWithdraw)
        public
        nonReentrant
        whenNotPaused
    {
        require(
            depositedDworm[msg.sender] >= amountToWithdraw,
            "Cannot withdraw more than you own."
        );

        uint256 timeElapsed = block.timestamp.sub(stakingTime[msg.sender]);
        updateAccount(msg.sender);

        uint256 penaltyFee = amountToWithdraw.mul(applyPenlty(timeElapsed)).div(
            1e4
        );
        uint256 amountAfterFee = amountToWithdraw.sub(penaltyFee);

        require(
            Token(dwormAddress).transfer(dwormAddress, penaltyFee),
            "Cannot tranfer withdrawal penalty."
        );
        require(
            Token(dwormAddress).transfer(msg.sender, amountAfterFee),
            "Cannot transfer DWORM."
        );

        depositedDworm[msg.sender] = depositedDworm[msg.sender].sub(
            amountToWithdraw
        );

        if (
            holders.contains(msg.sender) && depositedDworm[msg.sender] == 0
        ) {
            holders.remove(msg.sender);
        }
        emit Withdraw(msg.sender, amountToWithdraw);
    }

    function claimDivs() public nonReentrant whenNotPaused {
        updateAccount(msg.sender);
    }

    function getTotalStaked() public view returns (uint256) {
        uint256 totalstaked = 0;
        for (uint256 i = 0; i < getNumberOfHolders(); i = i.add(1)) {
            address staker = holders.at(i);
            totalstaked = totalstaked.add(depositedDworm[staker]);
        }
        return totalstaked;
    }

    function getStakersList(uint256 startIndex, uint256 endIndex)
        public
        view
        returns (
            address[] memory stakers,
            uint256[] memory stakingTimestamps,
            uint256[] memory lastClaimedTimeStamps,
            uint256[] memory stakedTokens
        )
    {
        require(startIndex < endIndex);

        uint256 length = endIndex.sub(startIndex);
        address[] memory _stakers = new address[](length);
        uint256[] memory _stakingTimestamps = new uint256[](length);
        uint256[] memory _lastClaimedTimeStamps = new uint256[](length);
        uint256[] memory _stakedTokens = new uint256[](length);

        for (uint256 i = startIndex; i < endIndex; i = i.add(1)) {
            address staker = holders.at(i);
            uint256 listIndex = i.sub(startIndex);
            _stakers[listIndex] = staker;
            _stakingTimestamps[listIndex] = stakingTime[staker];
            _lastClaimedTimeStamps[listIndex] = lastClaimedTime[staker];
            _stakedTokens[listIndex] = depositedDworm[staker];
        }

        return (
            _stakers,
            _stakingTimestamps,
            _lastClaimedTimeStamps,
            _stakedTokens
        );
    }

    // claim other ERC20 tokens sent to this contract (by mistake)
    function transferAnyERC20Tokens(
        address _tokenAddr,
        address _to,
        uint256 _amount
    ) public nonReentrant onlyOwner {
        require(_tokenAddr != dwormAddress, "Cannot Transfer DWORM.");
        Token(_tokenAddr).transfer(_to, _amount);
    }

    // Withdraw reward pool incase of emergency
    function emergencyWithdrawRewardPool(uint256 amount)
        external
        onlyOwner
        whenPaused
    {
        uint256 totalTokens = Token(dwormAddress).balanceOf(address(this));
        uint256 noneStakerFunds = totalTokens.sub(getTotalStaked());
        require(amount <= noneStakerFunds, "Cannot withdraw holders tokens");
        require(
            Token(dwormAddress).transfer(msg.sender, amount),
            "Cannot transfer DWORM."
        );

        emit RewardsPoolTransferred(msg.sender, amount);
    }

    // Staker withdraws their tokens, forsake rewards
    function emergencyWithdraw() external nonReentrant {
        require(
            depositedDworm[msg.sender] > 0,
            "Cannot withdraw more than you own."
        );

        require(
            Token(dwormAddress).transfer(
                msg.sender,
                depositedDworm[msg.sender]
            ),
            "Cannot transfer DWORM."
        );

        depositedDworm[msg.sender] = 0;

        if (holders.contains(msg.sender)) {
            holders.remove(msg.sender);
        }
        emit EmergencyWithdraw(msg.sender, depositedDworm[msg.sender]);
    }

    // Pause
    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Paused();
    }

    // UnPause
    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpaused();
    }

    function applyPenlty(uint256 timeElapsed)
        internal
        view
        returns (uint256 penalty)
    {
        penalty = 0;

        if (applyWithdrawPenalty) {
            if (timeElapsed <= 5 days) {
                penalty = penalty5Percent;
            } else if (timeElapsed > 5 days && timeElapsed <= 14 days) {
                penalty = penalty4Percent;
            } else if (timeElapsed > 14 days && timeElapsed <= 30 days) {
                penalty = penalty3Percent;
            } else if (timeElapsed > 30 days && timeElapsed < 60 days) {
                penalty = penalty2Percent;
            }
        }
    }
}
