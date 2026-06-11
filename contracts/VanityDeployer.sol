// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title VanityDeployer
 * @notice CREATE2 工厂合约 — 通过碰撞 salt 获得靓号合约地址
 *
 * 使用方式：
 *   1. 部署此工厂合约（只需一次）
 *   2. 在前端碰撞 salt，使 CREATE2 计算出的地址符合靓号尾号
 *   3. 调用 deploy(bytecode, salt) 部署目标合约
 */
contract VanityDeployer {
    event Deployed(address indexed addr, bytes32 salt);

    /**
     * @notice 通过 CREATE2 部署合约
     * @param bytecode 目标合约的 creation bytecode（含 constructor args）
     * @param salt     用于碰撞靓号的 salt
     * @return addr    部署后的合约地址
     */
    function deploy(bytes memory bytecode, bytes32 salt) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "CREATE2 failed");
        emit Deployed(addr, salt);
    }
}
