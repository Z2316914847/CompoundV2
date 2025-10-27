// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";
import "./InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";
import "./ErrorReporter.sol";

contract CTokenStorage {

    // 用于重入检查的保护变量
    bool internal _notEntered;

    // 此令牌的 EIP-20 令牌名称
    string public name;

    // 此代币的 EIP-20 代币符号
    string public symbol;

    // 此代币的 EIP-20 代币小数位数
    uint8 public decimals;

    // 每区块最大借款利率
    // Mantissa 是定点数表示法，Compound 使用 1e18 精度：1e18 = 100%、0.5e18 = 50%、0.02e18 = 2%
    uint internal constant borrowRateMaxMantissa = 0.0005e16;

    // 最大储备金系数 (100%)
    uint internal constant reserveFactorMaxMantissa = 1e18;

    // 本合同的管理员
    address payable public admin;

    // 该合同的待定管理员
    address payable public pendingAdmin;

    // -------------------------- 关联合约 ------------------------

    // 控制器合约（风险中心+资产管理）: 监督 cToken 间操作的合约
    ComptrollerInterface public comptroller;

    // 利率模型合约: 模型表明当前利率应该是多少
    InterestRateModel public interestRateModel;

    // -------------------------- 配置参数 ------------------------

    // 初始兑换率,初始化时为0.02e18 (1 cToken = 0.02 个基础资产)
    uint internal initialExchangeRateMantissa;

    // 储备金系数：目前预留给储备金的利息比例
    uint public reserveFactorMantissa;

    // 协议清算分成:添加到储备金中的扣押抵押品份额
    uint public constant protocolSeizeShareMantissa = 2.8e16; //2.8%

    // -------------------------- 资产相关状态变量 ------------------------

    // 上次计息区块号：上次应计利息的区块号
    uint public accrualBlockNumber;

    // 借款指数：自市场开盘以来的总利息收益率的累加器
    uint public borrowIndex;

    //总借款金额 ：CToken 市场中未偿还的基础资产总额
    uint public totalBorrows;

    //  协议储备金：该市场持有的标的准备金总额
    uint public totalReserves;

    // CToken 总供应量
    uint public totalSupply;

    // ---------------------------- 用户数据映射 ------------------------

    // 用户 CToken 余额: 每个账户的代币余额的官方记录
    mapping (address => uint) internal accountTokens;

    // 转账授权: 代表他人批准的代币转让金额
    mapping (address => mapping (address => uint)) internal transferAllowances;

    // 用户借款快照: 将账户地址映射到未偿借款余额
    mapping(address => BorrowSnapshot) internal accountBorrows;

    // 借入余额信息容器
    struct BorrowSnapshot {
        uint principal;       // 本金 应用最近一次余额变更操作后的总余额（含应计利息）
        uint interestIndex;   // interestIndex 截至最近一次余额变动操作的全局借贷指数
    }
    
}

abstract contract CTokenInterface is CTokenStorage {
    // 指示这是一个 CToken 合约（用于检查）
    bool public constant isCToken = true;


    /*** Market Events ***/

    // 应计利息时发出的事件
    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
    event Mint(address minter, uint mintAmount, uint mintTokens);
    // 赎回：兑换代币时发出的事件
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
    event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
    // 偿还借款时发出的事件
    event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);
    event LiquidateBorrow(address liquidator, address borrower, uint repayAmount, address cTokenCollateral, uint seizeTokens);


    /*** Admin Events ***/

    // 待定管理员更改时发出的事件
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    // 当pendingAdmin被接受时发出事件，这意味着admin被更新
    event NewAdmin(address oldAdmin, address newAdmin);
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);
    event NewMarketInterestRateModel(InterestRateModel oldInterestRateModel, InterestRateModel newInterestRateModel);
    event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);
    // 当储备金增加时发出的事件
    event ReservesAdded(address benefactor, uint addAmount, uint newTotalReserves);
    // 当储备金减少时发出的事件
    event ReservesReduced(address admin, uint reduceAmount, uint newTotalReserves);
    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed owner, address indexed spender, uint amount);


    /*** User Interface ***/

    function transfer(address dst, uint amount) virtual external returns (bool);
    function transferFrom(address src, address dst, uint amount) virtual external returns (bool);
    function approve(address spender, uint amount) virtual external returns (bool);
    function allowance(address owner, address spender) virtual external view returns (uint);
    function balanceOf(address owner) virtual external view returns (uint);
    function balanceOfUnderlying(address owner) virtual external returns (uint);
    function getAccountSnapshot(address account) virtual external view returns (uint, uint, uint, uint);
    function borrowRatePerBlock() virtual external view returns (uint);
    function supplyRatePerBlock() virtual external view returns (uint);
    function totalBorrowsCurrent() virtual external returns (uint);
    function borrowBalanceCurrent(address account) virtual external returns (uint);
    function borrowBalanceStored(address account) virtual external view returns (uint);
    function exchangeRateCurrent() virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
    function getCash() virtual external view returns (uint);
    function accrueInterest() virtual external returns (uint);
    function seize(address liquidator, address borrower, uint seizeTokens) virtual external returns (uint);


    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) virtual external returns (uint);
    function _acceptAdmin() virtual external returns (uint);
    function _setComptroller(ComptrollerInterface newComptroller) virtual external returns (uint);
    function _setReserveFactor(uint newReserveFactorMantissa) virtual external returns (uint);
    function _reduceReserves(uint reduceAmount) virtual external returns (uint);
    function _setInterestRateModel(InterestRateModel newInterestRateModel) virtual external returns (uint);
}

contract CErc20Storage {
    /**
     * @notice Underlying asset for this CToken
     */
    address public underlying;
}

abstract contract CErc20Interface is CErc20Storage {

    /*** User Interface ***/

    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function redeemUnderlying(uint redeemAmount) virtual external returns (uint);
    function borrow(uint borrowAmount) virtual external returns (uint);
    function repayBorrow(uint repayAmount) virtual external returns (uint);
    function repayBorrowBehalf(address borrower, uint repayAmount) virtual external returns (uint);
    function liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) virtual external returns (uint);
    function sweepToken(EIP20NonStandardInterface token) virtual external;


    /*** Admin Functions ***/

    function _addReserves(uint addAmount) virtual external returns (uint);
}

contract CDelegationStorage {
    /**
     * @notice Implementation address for this contract
     */
    address public implementation;
}

abstract contract CDelegatorInterface is CDelegationStorage {
    /**
     * @notice Emitted when implementation is changed
     */
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData) virtual external;
}

abstract contract CDelegateInterface is CDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) virtual external;

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() virtual external;
}
