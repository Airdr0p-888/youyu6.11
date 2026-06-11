// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Interfaces.sol";
import "./DividendTracker.sol";

/**
 * @title TaxDistributor
 * @notice 处理税费代币 → swap 成 BNB → 按四项分配（营销/分红/LP/销毁）
 *         由 ModaMintToken 卖出时自动转发税费代币到此合约
 */
contract TaxDistributor {
    using Address for address;

    address public owner;
    address public token;            // 主代币合约
    address public marketingWallet;  // 营销收款地址
    address public dividendTracker;  // 分红追踪合约
    address public router;           // PancakeSwap Router
    address public WBNB;             // WBNB 地址

    // BPS 分配比例（总和 <= 10000）
    // burnBps 在主合约层面直接销毁，不经过此合约
    uint256 public marketingBps;
    uint256 public dividendBps;
    uint256 public lpBps;

    uint256 public constant BPS_DENOMINATOR = 10000;

    // 最低处理额度（代币数量，wei）
    uint256 public minProcessAmount;
    // 是否允许任何人调用 tryProcess
    bool public autoProcess;

    // 状态
    string public lastFailure;

    event Processed(uint256 totalTokens, uint256 bnbForMarketing, uint256 bnbForDividend, uint256 tokensForLP);
    event BpsUpdated(uint256 marketing, uint256 dividend, uint256 lp);
    event MinProcessAmountUpdated(uint256 newMin);
    event AutoProcessToggled(bool enabled);
    event Rescued(address indexed to, uint256 amount, string kind);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _token,
        address _marketingWallet,
        address _dividendTracker,
        address _router,
        uint256 _marketingBps,
        uint256 _dividendBps,
        uint256 _lpBps
    ) {
        require(_token != address(0), "Zero token");
        require(_marketingWallet != address(0), "Zero marketing");
        require(_dividendTracker != address(0), "Zero tracker");
        require(_router != address(0), "Zero router");
        require(_marketingBps + _dividendBps + _lpBps <= BPS_DENOMINATOR, "BPS overflow");

        owner = msg.sender;
        token = _token;
        marketingWallet = _marketingWallet;
        dividendTracker = _dividendTracker;
        router = _router;
        WBNB = IPancakeRouter(_router).WETH();
        marketingBps = _marketingBps;
        dividendBps = _dividendBps;
        lpBps = _lpBps;
        minProcessAmount = 1000 * 10**18; // 默认 1000 个代币
        autoProcess = false;
    }

    receive() external payable {}

    /* ═══════════ 核心处理 ═══════════ */

    /**
     * @notice 处理合约中的税费代币（任何人可调用，需 autoProcess=true 或余额超阈值）
     */
    function tryProcess() external {
        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        require(tokenBal >= minProcessAmount, "Below min amount");
        _process(tokenBal);
    }

    /**
     * @notice 强制处理（仅 owner，无视阈值）
     */
    function forceProcess() external onlyOwner {
        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        require(tokenBal > 0, "No tokens");
        _process(tokenBal);
    }

    /**
     * @dev 内部处理逻辑
     *   总代币 = burnBps代币（已销毁） + swapBps代币（swap→BNB）
     *   swap获得的BNB → marketingBps / dividendBps 分别发送
     *   lpBps部分的代币 → 加流动性
     */
    function _process(uint256 totalTokens) internal {
        try this._processInternal(totalTokens) {
            lastFailure = "";
        } catch Error(string memory reason) {
            lastFailure = reason;
        } catch {
            lastFailure = "Unknown error";
        }
    }

    function _processInternal(uint256 totalTokens) external {
        require(msg.sender == address(this), "Internal only");

        // Step 1: 计算需要 swap 的代币（marketing + dividend 部分）
        uint256 swapBps = marketingBps + dividendBps;
        uint256 totalBps = swapBps + lpBps;

        uint256 swapTokens = 0;
        uint256 lpTokens = 0;

        if (totalBps > 0) {
            swapTokens = totalTokens * swapBps / totalBps;
            lpTokens = totalTokens - swapTokens;
        }

        // Step 2: swap 代币 → BNB
        uint256 bnbReceived = 0;
        if (swapTokens > 0 && swapBps > 0) {
            bnbReceived = _swapTokensForBNB(swapTokens);
        }

        // Step 3: 分配 BNB
        uint256 bnbForMarketing = 0;
        uint256 bnbForDividend = 0;

        if (swapBps > 0 && bnbReceived > 0) {
            bnbForMarketing = bnbReceived * marketingBps / swapBps;
            bnbForDividend = bnbReceived - bnbForMarketing;

            if (bnbForMarketing > 0) {
                Address.sendValue(payable(marketingWallet), bnbForMarketing);
            }

            if (bnbForDividend > 0) {
                Address.sendValue(payable(dividendTracker), bnbForDividend);
                // 通知分红追踪合约分配
                try DividendTracker(payable(dividendTracker)).distribute(bnbForDividend) {} catch {}
            }
        }

        // Step 4: LP 部分代币 → 加流动性
        if (lpTokens > 0) {
            _addLiquidity(lpTokens);
        }

        emit Processed(totalTokens, bnbForMarketing, bnbForDividend, lpTokens);
    }

    /* ═══════════ Internal ═══════════ */

    function _swapTokensForBNB(uint256 tokenAmount) internal returns (uint256) {
        IERC20(token).approve(router, tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;

        uint256[] memory amounts = IPancakeRouter(router).swapExactTokensForETH(
            tokenAmount,
            0, // accept any amount
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[1];
    }

    function _addLiquidity(uint256 tokenAmount) internal {
        // 将一半代币 swap 成 BNB，然后加流动性
        uint256 halfTokens = tokenAmount / 2;
        if (halfTokens == 0) return;

        uint256 bnbFromHalf = _swapTokensForBNB(halfTokens);
        if (bnbFromHalf == 0) return;

        uint256 remainingTokens = tokenAmount - halfTokens;

        IERC20(token).approve(router, remainingTokens);

        IPancakeRouter(router).addLiquidityETH{value: bnbFromHalf}(
            token,
            remainingTokens,
            0, // slippage
            0, // slippage
            address(this),
            block.timestamp + 300
        );
    }

    /* ═══════════ Admin ═══════════ */

    function setBps(uint256 _marketing, uint256 _dividend, uint256 _lp) external onlyOwner {
        require(_marketing + _dividend + _lp <= BPS_DENOMINATOR, "BPS overflow");
        marketingBps = _marketing;
        dividendBps = _dividend;
        lpBps = _lp;
        emit BpsUpdated(_marketing, _dividend, _lp);
    }

    function setMinProcessAmount(uint256 _min) external onlyOwner {
        minProcessAmount = _min;
        emit MinProcessAmountUpdated(_min);
    }

    function setAutoProcess(bool _enabled) external onlyOwner {
        autoProcess = _enabled;
        emit AutoProcessToggled(_enabled);
    }

    /* ═══════════ 救援提取 ═══════════ */

    function rescueBNB(address to, uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        Address.sendValue(payable(to), amount);
        emit Rescued(to, amount, "BNB");
    }

    function rescueToken(address _token, address to, uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        require(_token != token || amount <= IERC20(token).balanceOf(address(this)) - minProcessAmount,
            "Cannot rescue below min");
        IERC20(_token).transfer(to, amount);
        emit Rescued(to, amount, "Token");
    }

    function rescueLP(address pair, address to, uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        IERC20(pair).transfer(to, amount);
        emit Rescued(to, amount, "LP");
    }

    /* ═══════════ View ═══════════ */

    struct Status {
        uint256 balance_;
        uint256 minProcessAmount_;
        string lastFailure_;
        bool autoProcess_;
        uint256 marketingBps_;
        uint256 dividendBps_;
        uint256 lpBps_;
    }

    function getStatus() external view returns (Status memory) {
        return Status({
            balance_: IERC20(token).balanceOf(address(this)),
            minProcessAmount_: minProcessAmount,
            lastFailure_: lastFailure,
            autoProcess_: autoProcess,
            marketingBps_: marketingBps,
            dividendBps_: dividendBps,
            lpBps_: lpBps
        });
    }
}

library Address {
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Insufficient balance");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
