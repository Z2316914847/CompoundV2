// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {

    // 管理员 
    address public admin;

    // 待管理员
    address public pendingAdmin;

    //  Unitroller 活跃的大脑
    address public comptrollerImplementation;

    //  Comptroller地址 - implementation - Pending
    address public pendingComptrollerImplementation;
}

// 查看存储合约的演进链：V1 → V2 → V3 → V4 → V5 → V6 → V7
// 用户哪些资产参与 流动性计算、清算奖励、清算质押比例...
contract ComptrollerV1Storage is UnitrollerAdminStorage {

    /**
     * @notice Oracle 给出任何给定资产的价格
     */
    PriceOracle public oracle;

    // 清算质押品比例，默认清算借贷的最大50%仓位
    uint public closeFactorMantissa;

    // 清算奖励5%-8%
    uint public liquidationIncentiveMantissa;

    /**
     * @notice 单个账户可参与的最大资产数量（借入或用作抵押）
     */
    uint public maxAssets;

    // 用户加入的市场(这里的市场：只算流动性计算部分，用户可能有些ctoken资产没添加到市场，那么数组中变不能找到。)
    mapping(address => CToken[]) public accountAssets;

}

// V2 - 暂停市场 和 市场信息(上架、抵押率、用户加入市场进行流动性计算、是否参与COMP分配)
contract ComptrollerV2Storage is ComptrollerV1Storage {
    // 在市场第一次上架设置初始化(true、0、ctoken、false)
    struct Market {
        // ctoken 是否上架
        // 这个变量在 6大功能的 权限检察中都会使用
        bool isListed;

        // 抵押因子（0-1之间）：抵押率
        uint collateralFactorMantissa;

        // 用户是否参与此市场
        // 这个变量在操作这个市场的ctoken是才会应用：转账、赎回、借贷。注意 清算 不算哦
        // 用户在这个市场借贷，用户必须加入到这个市场，用户加入这个市场=》
        //   说明用户这个市场的质押物被归入流动性计算中，如果没加入这个市场，
        //   那么用户这个市场的资产不规流动性假设。加入这个市场的标识：
        //   是指markets[ctoken].accountMembership[borrower] = true。
        //   如何然他变为true呢？用户手动调用CompTroller合约的enterMakets方法（这个方法就是让用户加入到市场中）,
        //   获取用户首次在这个市场进行借贷，借贷过程中，用户会添加到市场汇总。
        mapping(address => bool) accountMembership;

        // 是否参与 COMP 奖励分发
        bool isComped;
    }

    // ctoken 地址  =>  市场信息
    // 控制器中要保存所有市场(ctoken)
    mapping(address => Market) public markets;

    // 全局暂停功能
    address public pauseGuardian;               // 暂停守护者地址：拥有暂停权限的地址，通常是治理合约或多签钱包
    bool public _mintGuardianPaused;            // 全局暂停 所有市场的 铸造功能
    bool public _borrowGuardianPaused;          // 全局暂停 所有市场的 借款功能
    bool public transferGuardianPaused;         // 全局暂停 所有市场的 转账功能
    bool public seizeGuardianPaused;            // 全局暂停 所有市场的 清算时的资产扣押功能
    // 市场级别的暂停
    mapping(address => bool) public mintGuardianPaused;   // 按市场暂停铸造
    mapping(address => bool) public borrowGuardianPaused; // 按市场暂停借款
}

// V3 - COMP治理代币
contract ComptrollerV3Storage is ComptrollerV2Storage {
    // 市场的供应状态
    struct CompMarketState {
        uint224 index;   // 全局供应者指数（持续增长）
        uint32 block;    // 上次更新的区块号
    }

    // 所有市场的列表
    CToken[] public allMarkets;

    // 全局市场的 COMP 发放速度（不再使用全局总预算再分配，好像已经弃用）
    // 所有市场compSpeeds <= comRate
    uint public compRate;

    // 每个市场的 COMP 发放速度（每个市场，在每个区块中 能分多少COMP代币）
    mapping(address => uint) public compSpeeds;

    // 每个市场的 COMP市场 供应状态
    mapping(address => CompMarketState) public compSupplyState;

    // 每个市场的 COMP市场 借贷状态
    mapping(address => CompMarketState) public compBorrowState;

    // 某个市场中 某用户的 市场的供应状态.全局供应者指数(用户级别的)
    mapping(address => mapping(address => uint)) public compSupplierIndex;

    // 某个市场中 某用户的 市场的借贷状态.全局借贷者指数(用户级别的)
    mapping(address => mapping(address => uint)) public compBorrowerIndex;

    // 用户已累计的COMP数量（未转移：用户还没领取的COMP数量）
    mapping(address => uint) public compAccrued;
}

// V4 - 设置借贷上限
contract ComptrollerV4Storage is ComptrollerV3Storage {
    // @noticeborrowCapGuardian 可以将borrowCaps 设置为任何市场的任何数字。降低借贷上限可能会禁止特定市场上的借贷。
    // 借贷上限监护人
    address public borrowCapGuardian;

    // 借用 上限由borrowAllowed 对每个cToken 地址强制执行。默认为零，相当于无限制借贷。
    // 借贷上限，默认借贷是无限的=0
    mapping(address => uint) public borrowCaps;
}

// V5 - 设置贡献者 将可以从每个区块获得 COMP治理代币。distribute是分配、Contributor时贡献者
contract ComptrollerV5Storage is ComptrollerV4Storage {
    // 每个贡献者在每个区块中收到的 COMP 部分
    mapping(address => uint) public compContributorSpeeds;

    /// @notice 分配贡献者 COMP 奖励的最后一个区块
    mapping(address => uint) public lastContributorBlock;
}

// 引入分离的奖励速度：
//   compBorrowSpeeds - 借贷市场的独立奖励速度
//   compSupplySpeeds - 供应市场的独立奖励速度
//   ComptrollerG7 使用统一的 compSpeeds，不需要分离
contract ComptrollerV6Storage is ComptrollerV5Storage {
    /// @notice The rate at which comp is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public compBorrowSpeeds;

    /// @notice The rate at which comp is distributed to the corresponding supply market (per block)
    mapping(address => uint) public compSupplySpeeds;
}

// V7Storage 添加了 proposal65FixExecuted、compReceivable
//   proposal65FixExecuted - 提案 65 修复执行标志
//   compReceivable - 用户欠协议的 COMP 数量
// ComptrollerG7 不需要这些修复和应收款功能
contract ComptrollerV7Storage is ComptrollerV6Storage {
    /// @notice Flag indicating whether the function to fix COMP accruals has been executed (RE: proposal 62 bug)
    bool public proposal65FixExecuted;

    /// @notice Accounting storage mapping account addresses to how much COMP they owe the protocol.
    mapping(address => uint) public compReceivable;
}
