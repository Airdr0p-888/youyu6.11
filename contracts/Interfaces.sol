// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Shared interfaces for all contracts in the ModaMint ecosystem

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeRouter {
    function WETH() external pure returns (address);
    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external returns (uint256[] memory amounts);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin,
        uint256 amountETHMin, address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function removeLiquidityETH(
        address token, uint256 liquidity, uint256 amountTokenMin,
        uint256 amountETHMin, address to, uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
}
