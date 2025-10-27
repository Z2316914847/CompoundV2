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
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => CToken[]) public accountAssets;

}

contract ComptrollerV2Storage is ComptrollerV1Storage {
    struct Market {
        // ctoken 是否上架
        bool isListed;

        //  乘数代表在这个市场上可以以其抵押品借款的最大金额。
        //  例如，0.9 允许借入抵押品价值的 90%。
        //  必须介于 0 和 1 之间，并存储为尾数。
        // 抵押因子（0-1之间）
        uint collateralFactorMantissa;

        // 用户是否参与此市场
        mapping(address => bool) accountMembership;

        // 是否参与 COMP 奖励分发
        bool isComped;
    }

    // ctoken 地址  =>  市场信息
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
