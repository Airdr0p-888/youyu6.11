# ModaMintToken 代币发射平台

## 文件说明

### 前端页面
- `launch.html` — 代币发射页面（填写参数 → 部署合约）
- `mint.html` — 用户 Mint 页面（连接钱包 → 发送 BNB 获得代币）
- `admin.html` — 管理员页面（白名单、提币、分红管理）
- `index.html` — 首页
- `owner.html` — Owner 管理页
- `refund.html` — 退款页

### 合约源码（Solidity 0.8.19）
- `contracts/ModaMintToken.sol` — 主代币合约
- `contracts/DividendTracker.sol` — 分红追踪合约
- `contracts/TaxDistributor.sol` — 税费分配合约
- `contracts/VanityDeployer.sol` — CREATE2 靓号工厂
- `contracts/Interfaces.sol` — 共享接口

### 编译产物（JS 数据文件）
- `contract_data.js` — 主合约 ABI + Bytecode
- `tracker_data.js` — DividendTracker ABI + Bytecode
- `tax_distributor_data.js` — TaxDistributor ABI + Bytecode
- `vanity_deployer_data.js` — VanityDeployer ABI + Bytecode
- `distributor_data.js` — 兼容别名（admin.html 使用）
- `ethers.umd.min.js` — ethers.js v5.7.2

## 使用方法

1. 用浏览器打开 `launch.html`（需要本地 HTTP 服务器，或直接双击打开）
2. 连接 MetaMask（BSC 网络）
3. 填写代币参数：
   - 代币名称、符号、总供应量
   - Mint 价格（BNB）、满额总量（BNB）
   - 预售占比、LP 比例
   - 买卖税率、税收分配比例
   - 白名单模式、分红门槛
   - 靓号尾号（可选）
4. 点击「立即发射代币」
5. 按钱包提示确认 3 笔交易：
   - 第 1 笔：部署主合约
   - 第 2 笔：部署税费分配合约
   - 第 3 笔：关联税费分配合约
6. 部署成功后复制合约地址，发给用户去 `mint.html` 参与 Mint

## 依赖

- [ethers.js v5](https://docs.ethers.org/v5/)
- MetaMask 钱包（BSC 网络）
- Solidity 编译器：solc 0.8.19（含 viaIR）

## 编译合约

```bash
cd "F:/动态图片/youyu2-main/youyu2-main - 重写合约"
node build.js
```

## 注意事项

- BSC 链上部署，确保钱包有充足 BNB
- 税费分配四项总和必须为 100%
- 靓号尾号越长，碰撞时间越久（4 位约 20 万次）
- Owner 弃权后不可逆，请谨慎操作
