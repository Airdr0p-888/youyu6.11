// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Interfaces.sol";

/**
 * @title DividendTracker
 * @notice 追踪持币人分红份额，支持最低持币门槛
 *         由 ModaMintToken 在构造函数中自动部署
 */
contract DividendTracker {
    address public platformOwner;
    address public token;                  // 主代币合约地址
    uint256 public minDividendBalance;     // 最低持币门槛（wei）
    uint256 public totalDividendShares;    // 总分红份额

    struct HolderInfo {
        uint256 shares;          // 该持币人分红份额
        uint256 totalDividends;  // 累计可分红的BNB总额（每股分红 * shares）
        uint256 withdrawn;       // 已提取的BNB
        bool exists;
        uint256 lastIndex;       // 链表索引
    }

    mapping(address => HolderInfo) public holders;
    address[] public holderList;
    uint256 public holdersCount;

    // 分红池累计（每股累计分红）
    uint256 public dividendsPerShare;
    uint256 public totalDistributed;
    uint256 public totalWithdrawn;

    // 精度
    uint256 private constant MAGNITUDE = 10 ** 18;

    event DividendDeposited(uint256 amount, uint256 dividendsPerShare);
    event DividendWithdrawn(address indexed holder, uint256 amount);
    event MinDividendBalanceUpdated(uint256 newMin);
    event HolderAdded(address indexed holder);
    event HolderRemoved(address indexed holder);
    event HolderSharesUpdated(address indexed holder, uint256 newShares);

    modifier onlyOwner() {
        require(msg.sender == platformOwner, "Not platform owner");
        _;
    }

    modifier onlyToken() {
        require(msg.sender == token, "Not token contract");
        _;
    }

    constructor(address _token, address _platformOwner, uint256 _minDividendBalance) {
        token = _token;
        platformOwner = _platformOwner;
        minDividendBalance = _minDividendBalance;
    }

    receive() external payable {}

    /* ═══════════ 核心函数 ═══════════ */

    /**
     * @notice 更新持币人份额（由主合约在 transfer 时调用）
     */
    function updateHolder(address holder, uint256 newBalance) external onlyToken {
        HolderInfo storage info = holders[holder];

        if (newBalance >= minDividendBalance) {
            if (!info.exists) {
                // 新增持币人
                info.exists = true;
                info.lastIndex = holderList.length;
                holderList.push(holder);
                holdersCount++;
                emit HolderAdded(holder);
            } else {
                // 结算待领取分红
                uint256 pending = (info.shares * dividendsPerShare / MAGNITUDE) - info.totalDividends;
                if (pending > 0) {
                    info.totalDividends += pending;
                    // BNB 余额不足时尽力而为
                }
            }
            info.shares = newBalance;
            info.totalDividends = info.shares * dividendsPerShare / MAGNITUDE;
            emit HolderSharesUpdated(holder, newBalance);
        } else {
            if (info.exists) {
                // 低于门槛，移除
                _removeHolder(holder);
            }
        }
    }

    /**
     * @notice 分配 BNB 分红（由 TaxDistributor 调用）
     */
    function distribute(uint256 amount) external {
        require(amount > 0, "Zero amount");
        if (totalDividendShares == 0) {
            // 没人持有，BNB 留在合约中
            totalDistributed += amount;
            return;
        }
        uint256 perShare = amount * MAGNITUDE / totalDividendShares;
        dividendsPerShare += perShare;
        totalDistributed += amount;
        emit DividendDeposited(amount, dividendsPerShare);
    }

    /**
     * @notice 持币人提取分红
     */
    function claimDividend() external {
        HolderInfo storage info = holders[msg.sender];
        require(info.exists, "Not a holder");

        uint256 totalEarned = info.shares * dividendsPerShare / MAGNITUDE;
        uint256 pending = totalEarned - info.withdrawn;
        require(pending > 0, "Nothing to claim");

        // 同步份额（如果余额变了）
        info.totalDividends = totalEarned;
        info.withdrawn = totalEarned;

        totalWithdrawn += pending;

        (bool success, ) = payable(msg.sender).call{value: pending}("");
        require(success, "Transfer failed");
        emit DividendWithdrawn(msg.sender, pending);
    }

    /**
     * @notice 查询待领取分红
     */
    function pendingDividend(address holder) external view returns (uint256) {
        HolderInfo storage info = holders[holder];
        if (!info.exists || info.shares == 0) return 0;
        uint256 totalEarned = info.shares * dividendsPerShare / MAGNITUDE;
        return totalEarned > info.withdrawn ? totalEarned - info.withdrawn : 0;
    }

    /* ═══════════ Admin ═══════════ */

    function setMinDividendBalance(uint256 _min) external onlyOwner {
        minDividendBalance = _min;
        emit MinDividendBalanceUpdated(_min);
    }

    /**
     * @notice 提取合约内全部 BNB（紧急用途）
     */
    function withdrawBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB");
        (bool success, ) = payable(platformOwner).call{value: bal}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice 旧版兼容：提取滞留 BNB
     */
    function withdrawStuckBNB(address to) external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB");
        (bool success, ) = payable(to).call{value: bal}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice 救援误转入的代币
     */
    function withdrawStuckToken(address _token) external onlyOwner {
        IERC20 t = IERC20(_token);
        uint256 bal = t.balanceOf(address(this));
        require(bal > 0, "No tokens");
        t.transfer(platformOwner, bal);
    }

    function withdrawToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(platformOwner, _amount);
    }

    /* ═══════════ Internal ═══════════ */

    function _removeHolder(address holder) internal {
        HolderInfo storage info = holders[holder];
        uint256 idx = info.lastIndex;
        uint256 lastIdx = holderList.length - 1;

        if (idx != lastIdx) {
            address lastHolder = holderList[lastIdx];
            holderList[idx] = lastHolder;
            holders[lastHolder].lastIndex = idx;
        }
        holderList.pop();
        holdersCount--;

        delete holders[holder];
        emit HolderRemoved(holder);
    }

    /* ═══════════ View ═══════════ */

    function balanceOf(address account) external view returns (uint256) {
        return holders[account].shares;
    }
}
