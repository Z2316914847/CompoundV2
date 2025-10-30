// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public comptrollerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingComptrollerImplementation;
}

contract ComptrollerV1Storage is UnitrollerAdminStorage {

    /**
     * @notice Oracle 给出任何给定资产的价格
     */
    PriceOracle public oracle;

    /**
     * @notice 乘数用于计算清算借款时的最大还款金额
     */
    // 清算质押品比例 Close Factor (0-1e18, default 0.5e18 = 0.5)
    uint public closeFactorMantissa;

    /**
     * @notice 乘数代表清算人收到的抵押品折扣
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice 单个账户可参与的最大资产数量（借入或用作抵押）
     */
    uint public maxAssets;

    /**
     * @notice “您所在资产”的每个账户映射，以 maxAssets 为上限
     */
    // 账户地址  =>  资产列表（用户参与的市场列表：用户资产添加到流动性计算中）
    //   用户可能有些ctoken资产没添加到市场，那么数组中变不能找到。
    mapping(address => CToken[]) public accountAssets;

}

contract ComptrollerV2Storage is ComptrollerV1Storage {
    struct Market {
        // ctoken 是否上架
        // 这个变量在 6大功能的 权限检察中都会使用
        bool isListed;

        //  乘数代表在这个市场上可以以其抵押品借款的最大金额。
        //  例如，0.9 允许借入抵押品价值的 90%。
        //  必须介于 0 和 1 之间，并存储为尾数。
        // 抵押因子（0-1之间）
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


    /**
     * @notice 暂停守护者可以暂停某些操作作为安全机制。
     *允许用户删除自己资产的操作无法暂停。
     *清算/扣押/转移只能在全球范围内暂停，不能按市场暂停。
     */
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

contract ComptrollerV3Storage is ComptrollerV2Storage {
    // 市场的供应状态
    struct CompMarketState {
        // The market's last updated compBorrowIndex or compSupplyIndex
        uint224 index;   // 全局供应者指数（持续增长）

        // The block number the index was last updated at
        uint32 block;    // 上次更新的区块号
    }

    /// @notice A list of all markets
    CToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes COMP, per block
    uint public compRate;

    /// @notice The portion of compRate that each market currently receives
    mapping(address => uint) public compSpeeds;

    /// @notice The COMP market supply state for each market
    mapping(address => CompMarketState) public compSupplyState;

    /// @notice The COMP market borrow state for each market
    mapping(address => CompMarketState) public compBorrowState;

    /// @notice The COMP borrow index for each market for each supplier as of the last time they accrued COMP
    mapping(address => mapping(address => uint)) public compSupplierIndex;

    /// @notice The COMP borrow index for each market for each borrower as of the last time they accrued COMP
    mapping(address => mapping(address => uint)) public compBorrowerIndex;

    /// @notice The COMP accrued but not yet transferred to each user
    mapping(address => uint) public compAccrued;
}

contract ComptrollerV4Storage is ComptrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each cToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

contract ComptrollerV5Storage is ComptrollerV4Storage {
    /// @notice The portion of COMP that each contributor receives per block
    mapping(address => uint) public compContributorSpeeds;

    /// @notice Last block at which a contributor's COMP rewards have been allocated
    mapping(address => uint) public lastContributorBlock;
}

contract ComptrollerV6Storage is ComptrollerV5Storage {
    /// @notice The rate at which comp is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public compBorrowSpeeds;

    /// @notice The rate at which comp is distributed to the corresponding supply market (per block)
    mapping(address => uint) public compSupplySpeeds;
}

contract ComptrollerV7Storage is ComptrollerV6Storage {
    /// @notice Flag indicating whether the function to fix COMP accruals has been executed (RE: proposal 62 bug)
    bool public proposal65FixExecuted;

    /// @notice Accounting storage mapping account addresses to how much COMP they owe the protocol.
    mapping(address => uint) public compReceivable;
}
