// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";                    // 市场
import "./ErrorReporter.sol";             // 错误报告器：token 和 Comptroller
import "./PriceOracle.sol";               // 预言机
import "./ComptrollerInterface.sol";      // 控制器接口
import "./ComptrollerStorage.sol";        // 控制器存储
import "./Unitroller.sol";                // 单位角色
import "./Governance/Comp.sol";           // 治理合约

// ComptrollerG7为什么不继承ComptrollerV7Storage？因为ComptrollerG7使用的是同一个 compSpeeds[cToken] 既用于供应奖励，
//   也用于借贷奖励。如果继承 V6，会需要两个独立的速度变量（compSupplySpeeds 和 compBorrowSpeeds），这与当前设计不符。
contract ComptrollerG7 is ComptrollerV5Storage, ComptrollerInterface, ComptrollerErrorReporter, ExponentialNoError {
    // 市场上架时发出     
    event MarketListed(CToken cToken);

    /// 账户进入市场时发出
    event MarketEntered(CToken cToken, address account);

    // 账户退出市场时发出
    event MarketExited(CToken cToken, address account);

    // 更改清算比例时发出
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    // 更改抵押因子时发出
    event NewCollateralFactor(CToken cToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    // 更改清算奖励时发出
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    // 更改预言机时发出
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    // 当暂停守护者更改时发出
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    // 当操作全局暂停时发出
    event ActionPaused(string action, bool pauseState);

    // 当市场上的操作暂停时发出
    event ActionPaused(CToken cToken, string action, bool pauseState);

    // 当为市场计算新的 COMP 速度时发出
    event CompSpeedUpdated(CToken indexed cToken, uint newSpeed);

    // 当为贡献者设置新的 COMP 速度时发出
    event ContributorCompSpeedUpdated(address indexed contributor, uint newSpeed);

    // 当 COMP 分发给供应商时发出
    event DistributedSupplierComp(CToken indexed cToken, address indexed supplier, uint compDelta, uint compSupplyIndex);

    // 当 COMP 分发给借款人时发出
    event DistributedBorrowerComp(CToken indexed cToken, address indexed borrower, uint compDelta, uint compBorrowIndex);

    // 当 cToken 的借入上限更改时发出
    event NewBorrowCap(CToken indexed cToken, uint newBorrowCap);

    // 当借用上限监护人更改时发出
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    // 当管理员授予 COMP 时发出
    event CompGranted(address recipient, uint amount);

    // 市场的初始 COMP 指数，1*e18 = compSupplyState[address].index 
    uint224 public constant compInitialIndex = 1e36;

    // closeFactorMantissa 必须严格大于该值
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa 不得超过该值
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // 抵押因子尾数不得超过该值
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    // =============================================================================================
    //                                 
    // ============================================================================================= 

    /**
     * @notice 返回账户已输入的资产
     * @param account 拉取资产的账户地址
     * @return 包含账户已输入资产的动态列表
     */
    // 获取用户资产 - 这些资产是 归入流动性计算部分
    function getAssetsIn(address account) external view returns (CToken[] memory) {
        CToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    // 检查用户 是否将 资产加入到 流动性计算
    function checkMembership(address account, CToken cToken) external view returns (bool) {
        return markets[address(cToken)].accountMembership[account];
    }

    // =============================================================================================
    //                                 用户 加入/退出市场
    // =============================================================================================

    // 用户加入一个市场 或 多个市场。请不要把 用户加入市场 和 市场加入到comtroller混淆 
    //   market[ctoken].accountMembership[borrow] = true (市场级别记录加入市场)
    //   accountAssets[user_Address].push[ctoken]  （获取用户加入所有的市场（注意是流动性部分））
    function enterMarkets(address[] memory cTokens) override public returns (uint[] memory) {
        uint len = cTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            CToken cToken = CToken(cTokens[i]);

            results[i] = uint(addToMarketInternal(cToken, msg.sender));
        }

        return results;
    }

    // 用户加入市场：用户资产添加到流动性计算中
    function addToMarketInternal(CToken cToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(cToken)];

        // 市场是否上架
        if (!marketToJoin.isListed) {
            // 市场未上市，无法加入
            return Error.MARKET_NOT_LISTED;
        }

        // 用户是否已经参与此市场
        if (marketToJoin.accountMembership[borrower] == true) {
            return Error.NO_ERROR;
        }

        // 用户加入市场
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);

        return Error.NO_ERROR;
    }

    // 退出市场（用户退出资产流动性计算）
    function exitMarket(address cTokenAddress) override external returns (uint) {
        // 获取退出的市场
        CToken cToken = CToken(cTokenAddress);

        // 获取用户在这个市场的（没更新）：状态码（获取数据是否成功）、ctoken代币余额、借款余额、兑换率）
        (uint oErr, uint tokensHeld, uint amountOwed, ) = cToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed");

        // 退出市场时，用户在这个市场必须没有借贷。因为退出市场后，accountAssets[address]会减去这个市场。accountAssets这个变量不仅可以获取资产还可以获取借贷余额
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        // 假设用户退出市场后，健康度检查
        uint allowed = redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(cToken)];

        // 如果发送者尚未“进入”市场，则统一退出市场
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        // 删除用户在市场级别的记录
        delete marketToExit.accountMembership[msg.sender];

        /*从账户资产列表中删除cToken */
        // 加载到内存中以加快迭代速度
        CToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == cToken) {
                assetIndex = i;
                break;
            }
        }

        // 我们*必须*已在列表中找到该资产，否则我们的冗余数据结构已损坏
        assert(assetIndex < len);

        // 将列表中的最后一项复制到要删除的项的位置，长度减少 1
        // 在 exitMarket 中，直接删除中间元素会移动大量元素，成本高。当前做法是：
        //   将最后一个元素移到目标位置
        //   用 pop() 删除最后一个元素
        //   这样只需一次赋值和一次 pop()，Gas 成本更低，适合数组操作。
        CToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();  // 删除最后一项数据，仅适用于动态数组（storage 数组）

        emit MarketExited(cToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    // =============================================================================================
    //                                 策略钩子函数(在ctoken中被调用)
    // =============================================================================================

    // 检查是否允许账户在给定市场转移代币
    // 参数：cToken：市场核实转让、src：源账户、dst：目标账户、transferTokens：转让的cToken数量
    // 如果允许转账，则为 0，否则为半透明错误代码（请参阅 ErrorReporter.sol）
    function transferAllowed(address cToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // 1、检查 全局转账 是否被暂停，如果是，抛出异常。  为什么要设置一个市场停止功能？答：设置这个功能是为了维持系统稳定，让用户有更多时间来应对市场波动。
        require(!transferGuardianPaused, "transfer is paused");

        // 2、目前唯一考虑的是src是否可以赎回这么多代币
        uint allowed = redeemAllowedInternal(cToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // 3、COMP 奖励分发：每次转账都会触发奖励分发

        // 更新该市场的 COMP 供应指数
        updateCompSupplyIndex(cToken);
        // 为发送方分发 COMP 奖励
        distributeSupplierComp(cToken, src);
        // 为接收方分发 COMP 奖励
        distributeSupplierComp(cToken, dst);

        return uint(Error.NO_ERROR);
    }

    // 检查是否应允许帐户在给定市场中铸造代币
    // 返回：如果允许铸造，则为返回 0，否则为半不透明错误代码（请参阅 ErrorReporter.sol）
    function mintAllowed(address cToken, address minter, uint mintAmount) override external returns (uint) {
        // 检查 市场级别 是否被暂停，如果是，抛出异常
        require(!mintGuardianPaused[cToken], "mint is paused");

        // 在 Solidity 里，单独写一行 minter; 或 mintAmount; 是一条表达式语句，
        //  什么也不做，但会让编译器认为参数被“读取”过，从而不报 unused variable 的警告。
        minter;
        mintAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // COMP治理代币 奖励分发
        updateCompSupplyIndex(cToken);
        // 用户应得 COMP = 用户持有 cToken × (当前指数 - 用户上次快照指数)
        distributeSupplierComp(cToken, minter);

        return uint(Error.NO_ERROR);
    }

    // 检查账户是否允许在给定市场赎回代币
    function redeemAllowed(address cToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(cToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // COMP 奖励分发
        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    // 内部函数：健康度查询：检查账户是否允许在给定市场赎回代币
    function redeemAllowedInternal(address cToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        // 市场是否上架
        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 用户（可能是 所有者/被授权者）是否使用了该市场（质押品）
        if (!markets[cToken].accountMembership[redeemer]) {
            // 没有参与这个市场，则用户可以直接赎回
            // 用户没有参与市场 意味着没有使用 该资产 作为抵押品，那么用户就不存在 逃离清算的风险。
            return uint(Error.NO_ERROR);
        }

        // 用户参与了这个市场，则需要检查 赎回后 的 账户流动性
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, CToken(cToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            // 流动出错
            return uint(err);
        }
        if (shortfall > 0) {
            // 流动性不足
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    // 检查账户是否允许在给定市场 借贷代币
    function borrowAllowed(address cToken, address borrower, uint borrowAmount) override external returns (uint) {
        // 检查 市场级别 是否被暂停，如果是，抛出异常
        require(!borrowGuardianPaused[cToken], "borrow is paused");

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 判断借贷人是否在市场中
        if (!markets[cToken].accountMembership[borrower]) {
            require(msg.sender == cToken, "sender must be cToken");

            // 将借款人添加到市场中，之后用户的这个市场资产就会被 计入流动性计算中
            Error err = addToMarketInternal(CToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // 抛出异常又三种方式：require，assert、revert
            //   下面这段代码，按理说是一定要为真的。
            assert(markets[cToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(CToken(cToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[cToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = CToken(cToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, CToken(cToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    // 检查账户是否允许在给定市场偿还代币
    function repayBorrowAllowed(
        address cToken,
        address payer,
        address borrower,
        uint repayAmount) override external returns (uint) {
            
        payer;
        borrower;
        repayAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }


        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    // 检查是否允许清算用户
    function liquidateBorrowAllowed(
        address cTokenBorrowed,     // 借款人 借入资产的 市场地址
        address cTokenCollateral,   // 抵押品的市场地址
        address liquidator,         // 清算人地址
        address borrower,           // 借款人的地址
        uint repayAmount) override external returns (uint) {

        liquidator;
        // 借入与抵押市场必须 都是 已上架
        if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 检查健康度
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        // 判断用户是否资金短缺情况，只有在 账户缺口 大于 0 时，才允许清算发生
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        // 计算出用户总借贷数量
        uint borrowBalance = CToken(cTokenBorrowed).borrowBalanceStored(borrower);
        // 获取用户被清算的最大数量 = 总借贷数量 * closeFactorMantissa。 closeFactorMantissa：
        uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        // 用户偿还底层资产数量 不能大于 用户被清算的最大数量
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    // 检查是否允许扣押抵押品
    function seizeAllowed(
        address cTokenCollateral,   // 用作抵押品并将被扣押的资产
        address cTokenBorrowed,     // 借款人借入的资产
        address liquidator,         // 清算人地址
        address borrower,           // 借贷人地址
        uint seizeTokens) override external returns (uint) {
        // 检查 全局扣押 是否被暂停，如果是，抛出异常 
        require(!seizeGuardianPaused, "seize is paused");

        seizeTokens;

        if (!markets[cTokenCollateral].isListed || !markets[cTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }
        // 必须存在，防止跨协议攻击
        if (CToken(cTokenCollateral).comptroller() != CToken(cTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // COMP治理代代币 奖励分发
        updateCompSupplyIndex(cTokenCollateral);
        distributeSupplierComp(cTokenCollateral, borrower);
        distributeSupplierComp(cTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    // 参数：ctoken：市场、src：发送代币地址、dst：接受代币地址、TransferTokens：要转移的 cToken 数量
    function transferVerify(address cToken, address src, address dst, uint transferTokens) override external {
        // 嘘——目前未使用
        cToken;
        src;
        dst;
        transferTokens;

        // 嘘 -我们不希望这个钩子被标记为纯的
        if (false) {
            maxAssets = maxAssets;
        }
    }

    // 参数：ctoken：市场、minter：接受代币地址、actualMintAmount：铸造底层资产数量、mintTokens：铸造ctoken代币数量
    function mintVerify(address cToken, address minter, uint actualMintAmount, uint mintTokens) override external {
        // 嘘——目前未使用
        cToken;
        minter;
        actualMintAmount;
        mintTokens;

        // 嘘 -我们不希望这个钩子被标记为纯的
        if (false) {
            maxAssets = maxAssets;
        }
    }

    // 参数：ctoken：市场、minter：接受代币地址、actualMintAmount：赎回底层资产数量、mintTokens：赎回ctoken代币数量
    function redeemVerify(address cToken, address redeemer, uint redeemAmount, uint redeemTokens) override external {
        // Shh - currently unused
        cToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    // 参数：ctoken：市场、minter：接受代币地址、actualMintAmount：借入底层资产数量、mintTokens：借入ctoken代币数量
    function borrowVerify(address cToken, address borrower, uint borrowAmount) override external {
        // Shh - currently unused
        cToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    function repayBorrowVerify(
        address cToken,           // 市场
        address payer,            // 偿还地址
        address borrower,         // 借贷地址
        uint actualRepayAmount,   // 偿还底层资产数量
        uint borrowerIndex) override external {
        // Shh - currently unused
        cToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    function liquidateBorrowVerify(
        address cTokenBorrowed,      // 借贷人借贷资产地址
        address cTokenCollateral,    // 借贷人质押品地址
        address liquidator,          // 清算人地址
        address borrower,            // 借贷人地址
        uint actualRepayAmount,      // 偿还底层资产数量
        uint seizeTokens) override external {
        // Shh - currently unused
        cTokenBorrowed;
        cTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    function seizeVerify(
        address cTokenCollateral,    // 用作抵押品并将被扣押的资产
        address cTokenBorrowed,      // 借贷人借贷资产地址
        address liquidator,          // 清算人地址
        address borrower,            // 借贷人地址、 扣押ctoken数量
        uint seizeTokens) override external {
        // Shh - currently unused
        cTokenCollateral;
        cTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    // =============================================================================================
    //                                  流动性计算
    // =============================================================================================

    // 账户流动性本地标签：用于避免计算帐户流动性时的堆栈深度限制
    struct AccountLiquidityLocalVars {
        uint sumCollateral;            // 总质押品价值
        uint sumBorrowPlusEffects;     // 总借贷价值（含假设操作）
        uint cTokenBalance;            // ctoken 数量
        uint borrowBalance;            // 借贷 数量
        uint exchangeRateMantissa;     // 兑换率
        uint oraclePriceMantissa;      // 预言机价格
        Exp collateralFactor;          // 抵押因子
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;             
    }

    // 获取账户的流动性状态
    // 返回(状态码、流动性余额、流动性资产短缺)
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    // 内部函数
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);
    }

    // 假设执行某些操作后的流动性状态
    function getHypotheticalAccountLiquidity(
        address account,
        address cTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(cTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    // 内部函数：健康度检查
    // 首先的得明白：比较的是价格，所以必须要将他们化为统一单位
    // 用户质押底层资产 * 代币资产的价格 * 最大抵押率 > 用户借贷底层资产 * 代币资产价格
    function getHypotheticalAccountLiquidityInternal(
        address account,         // 被检查健康度的 账户
        CToken cTokenModify,     // 要赎回/借入的市场
        uint redeemTokens,       // 赎回 ctoken的数量
        uint borrowAmount        // 借贷 Ctoken的数量
        ) internal view returns (Error, uint, uint) {

        // 保存所有的计算结果
        AccountLiquidityLocalVars memory vars; 
        uint oErr;
        CToken[] memory assets = accountAssets[account];

        // 遍历用户的所有资产（这个资产是用户主动进入的），这样就能获取到 用户在每个市场的 抵押数量和借贷数量，进而计算出用户在这个市场 质押价值和借贷价值。
        //   在然后就是累计所有市场的 抵押价值和借贷价值。
        for (uint i = 0; i < assets.length; i++) {
            // 获取市场
            CToken asset = assets[i];

            // 获取：状态码、用户在这个市场 ctoken数量、用户在这个市场 借贷数量、当前兑换率）
            (oErr, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            
            // 判断状态码是否匹配
            if (oErr != 0) {
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }

            // 获取 这个市场的抵押因子 和 这个市场的兑换率
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // 获取代币的真实价格：用预言机获取
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // 预先计算代币 -> 以太币（标准化价格值）的转换系数
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // 汇总 抵押价值: sumCollateral += tokensToDenom * cTokenBalance
            //  用户在这个市场拥有的 CToken * ( collateralFactor * exchangeRate * oraclePrice) 
            //   = CToken * exchangeRate * ( collateralFactor * oraclePrice)
            //   = 用户在这个市场的 底层资产数量 * 抵押率 * 每个底层资产价格 = 最多可以借贷数量 
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.cTokenBalance, vars.sumCollateral);

            // 汇总 借贷价值: sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // 判断 要赎回/借入的市场 是否等于 用户资产中的某一项市场
            if (asset == cTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                // 赎回影响：减少抵押品价值
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                // 借款影响：增加借款价值
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // 判断 借贷价值 是否大于 最大质押率价值  
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            // 借贷价值 < 最大质押率价值   说明账户健康
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            // // 借贷价值 >= 最大质押率价值   说明账户 不健康
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    // 计算 清算时 需要扣押的抵押品 cToken 数量
    // 参数：cTokenBorrowed：借入的 cToken 地址、cTokenCollateral：抵押品 cToken 地址、actualRepayAmount：清算人实际偿还的底层资产金额
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,         // 借贷市场地址
        address cTokenCollateral,       // 用户质押品地址
        uint actualRepayAmount ) override external view returns (uint, uint) {
        
        // 步骤1：从预言机获取两个市场的底层资产价格：因为用户借/还得都是数量，并不是价格。
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(CToken(cTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(CToken(cTokenCollateral));
        
        // 如果价格获取失败（返回0），返回错误
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
        * 步骤2：计算扣押的底层资产金额和 cToken 数量
        * 
        * 计算逻辑（分两步）：
        * 
        * 第一步：计算需要扣押的底层资产金额（seizeAmount）
        *   seizeAmount = actualRepayAmount × liquidationIncentive × priceBorrowed / priceCollateral
        *   
        *   解释：
        *   - actualRepayAmount：清算人偿还的借款金额（底层资产单位）
        *   - liquidationIncentive：清算奖励系数（如 1.08，表示清算人可获得 8% 的奖励）
        *   - priceBorrowed / priceCollateral：价格比率，将借款资产转换为抵押品资产
        *   
        *   例如：偿还 1000 USDC，奖励 8%，USDC/ETH 价格比为 3000
        *        seizeAmount = 1000 × 1.08 × 1 = 1080 USDC（如果抵押品也是 USDC）
        *        或 = 1000 × 1.08 × 1/3000 = 0.36 ETH（如果抵押品是 ETH）
        * 
        * 第二步：将底层资产金额转换为 cToken 数量
        *   seizeTokens = seizeAmount / exchangeRate
        *   
        *   解释：
        *   - exchangeRate：cToken 与底层资产的兑换率
        *   - 例如：如果 1 cETH = 0.02 ETH，则 0.36 ETH = 18 cETH
        * 
        * 合并公式（一步计算）：
        *   seizeTokens = actualRepayAmount × (liquidationIncentive × priceBorrowed) / (priceCollateral × exchangeRate)
        */

        // 大概意思就是：首先计算出质押得数量 和 质押得兑换率 。ctoken = 底层资产/兑换率  就得到了被
        
        // 获取抵押品市场的兑换率（cToken 与底层资产的比例）
        uint exchangeRateMantissa = CToken(cTokenCollateral).exchangeRateStored();
        
        uint seizeTokens;
        Exp memory numerator;     // 分子
        Exp memory denominator;   // 分母
        Exp memory ratio;         // 比率
        
        // 计算分子：liquidationIncentive × priceBorrowed
        // 这表示"带奖励的借款资产价值"
        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        
        // 计算分母：priceCollateral × exchangeRate
        // 这表示"抵押品 cToken 的底层资产价值"
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        
        // 计算比率：分子 / 分母
        ratio = div_(numerator, denominator);
        
        // 最终计算：actualRepayAmount × 比率 = 需要扣押的 cToken 数量
        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);
        
        // 返回成功码和扣押的 cToken 数量
        return (uint(Error.NO_ERROR), seizeTokens);
    }

    // =============================================================================================
    //                                  管理员功能
    // =============================================================================================

    // 管理功能设置新的价格预言机
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    // 设置清算比例：一般清算用户借贷资产的50%
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    // 设置某个市场的质押率：eth最多可以借贷60%、Btc最多借贷70%....
    function _setCollateralFactor(CToken cToken, uint newCollateralFactorMantissa) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        Market storage market = markets[address(cToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // 抵押率必须 <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // 抵押率 != 0, 底层资产价格 == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(cToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(cToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    // 设置清算奖励：一般清算奖励是5%-8%
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    // 将市场上架
    function _supportMarket(CToken cToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(cToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        // 健全性检查以确保其确实是 CToken。其实 isctoken不是方法，而是一个 变量
        cToken.isCToken();

        // 请注意 isComped 不再有效使用
        Market storage market = markets[address(cToken)];
        market.isListed = true;
        market.isComped = false;
        market.collateralFactorMantissa = 0;
        // 将市场添加到流动性计算中
        _addMarketInternal(address(cToken));

        emit MarketListed(cToken);

        return uint(Error.NO_ERROR);
    }

    // 将市场添加到流动性计算中
    function _addMarketInternal(address cToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != CToken(cToken), "market already added");
        }
        allMarkets.push(CToken(cToken));
    }

    // 设置给定 cToken 市场的给定借入上限
    function _setMarketBorrowCaps(CToken[] calldata cTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps");

        uint numMarkets = cTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(cTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(cTokens[i], newBorrowCaps[i]);
        }
    }

    // 设置借用上限监护人的管理功能
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        address oldBorrowCapGuardian = borrowCapGuardian;

        borrowCapGuardian = newBorrowCapGuardian;

        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    // 管理功能更改暂停监护人
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        address oldPauseGuardian = pauseGuardian;

        pauseGuardian = newPauseGuardian;

        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    // _become 是 Compound 协议中用于升级 Comptroller 实现合约的方法，属于代理升级模式（Proxy Upgrade Pattern）。
    //   Unitroller（代理合约）：存储状态，地址固定、用户交互的入口Comptroller（实现合约）：逻辑实现，可升级
    // 1. 部署新版本的 ComptrollerG7 实现合约
    //    ↓
    // 2. 管理员调用 Unitroller._setPendingImplementation(新合约地址)
    //    ↓
    // 3. 新合约调用 _become(Unitroller地址)
    //    ↓
    // 4. _become 内部调用 Unitroller._acceptImplementation()
    //    ↓
    // 5. Unitroller 的 comptrollerImplementation 更新为新地址
    //    ↓
    // 6. 所有后续调用通过 fallback 函数委托到新实现
    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    // 检查调用者是否为管理员，或者此合约正在成为新的实现
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    // =============================================================================================
    //                                 暂停/启动市场
    // =============================================================================================

    // 设置铸造暂停
    function _setMintPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Mint", state);
        return state;
    }

    // 设置借贷暂停
    function _setBorrowPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Borrow", state);
        return state;
    }

    // 设置转账暂停 
    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    // 设置清算暂停
    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    // =============================================================================================
    //                                  Comp 分配
    // =============================================================================================

    // 设置市场的 COMP 发放速度
    function _setCompSpeed(CToken cToken, uint compSpeed) public {
        require(adminOrInitializing(), "only admin can set comp speed");
        setCompSpeedInternal(cToken, compSpeed);
    }

    // 设置贡献者的 COMP 发放速度
    function _setContributorCompSpeed(address contributor, uint compSpeed) public {
        require(adminOrInitializing(), "only admin can set comp speed");

        // 请注意，COMP 速度可以设置为 0，以停止对贡献者的流动性奖励
        updateContributorRewards(contributor);
        if (compSpeed == 0) {
            // 释放存储
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        compContributorSpeeds[contributor] = compSpeed;

        emit ContributorCompSpeedUpdated(contributor, compSpeed);
    }

    // 内部函数：设置市场的 compSeed
    function setCompSpeedInternal(CToken cToken, uint compSpeed) internal {
        // 获取这个市场的 compSeed
        uint currentCompSpeed = compSpeeds[address(cToken)];
        
        if (currentCompSpeed != 0) {
            // 进入到这里有只有一种情况：旧市场compSeed != 0。请注意，COMP 速度可以设置为 0 以停止市场的流动性奖励
            // 更新compSeed 之前先将之前的supplyIndex/borrowIndex更新完：因为supplyIndex/borrowIndex会涉及COMP奖励发放。所以更新compSeed 之前先将之前的supplyIndex/borrowIndex更新号。
            Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
            updateCompSupplyIndex(address(cToken));
            updateCompBorrowIndex(address(cToken), borrowIndex);
        } else if (compSpeed != 0) {
            // 进入到这里有这2种情况：第一次设置市场的compSeed，或者后续市场的compSeed 从 0 -> 非0
            // 一般是：市场的compSeed 从 0 -> 非0
            Market storage market = markets[address(cToken)];
            require(market.isListed == true, "comp market is not listed");

            // 市场的全局供应指数 = 0 && 市场的区块 = 0
            if (compSupplyState[address(cToken)].index == 0 && compSupplyState[address(cToken)].block == 0) {
                compSupplyState[address(cToken)] = CompMarketState({
                    index: compInitialIndex,
                    block: safe32(getBlockNumber(), "block number exceeds 32 bits")
                });
            }

            // 市场的全局借贷指数 = 0 && 市场的区块 = 0
            if (compBorrowState[address(cToken)].index == 0 && compBorrowState[address(cToken)].block == 0) {
                compBorrowState[address(cToken)] = CompMarketState({
                    index: compInitialIndex,
                    block: safe32(getBlockNumber(), "block number exceeds 32 bits")
                });
            }
        }

        if (currentCompSpeed != compSpeed) {
            compSpeeds[address(cToken)] = compSpeed;
            emit CompSpeedUpdated(cToken, compSpeed);
        }
    }

    // 更新该市场的 COMP 供应指数
    // 需要的数据：区块号，comp速率、
    function updateCompSupplyIndex(address cToken) internal {
        // 获取该市场的状态: 上次更新时的 指数和区块号
        CompMarketState storage supplyState = compSupplyState[cToken];

        // 获取该市场的 COMP 发放速度（每秒发放多少 COMP）
        uint supplySpeed = compSpeeds[cToken];

        // 计算经过了几个区块
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        
        // 如果有新区块且有发放速度，
        if (deltaBlocks > 0 && supplySpeed > 0) {
            // 1.获取当前的总供应量
            uint supplyTokens = CToken(cToken).totalSupply();

            // 2.计算应该发放的总 COMP 数量,  奖励 = 经过的区块数 × 每秒发放量
            uint compAccrued = mul_(deltaBlocks, supplySpeed);

            // 3.计算每个 cToken 应该新增多少 COMP 比率,  比率 = 总应发放的 COMP / 总供应量
            Double memory ratio = supplyTokens > 0 ? fraction(compAccrued, supplyTokens) : Double({mantissa: 0});

            // 4.更新全局指数 = 旧指数 + 新增比率
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            
            // 5.保存新状态
            compSupplyState[cToken] = CompMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            // 如果只是更新区块号，不发放 COMP
            supplyState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    // 更新该市场的 COMP 借贷指数
    function updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) internal {
        CompMarketState storage borrowState = compBorrowState[cToken];
        uint borrowSpeed = compSpeeds[cToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(CToken(cToken).totalBorrows(), marketBorrowIndex);
            uint compAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(compAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            compBorrowState[cToken] = CompMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    // 为分发 COMP 奖励  -  supply
    // 用户应得 COMP = 用户持有 cToken × (当前指数 - 用户上次快照指数)
    function distributeSupplierComp(address cToken, address supplier) internal {
        // 获取市场的供应状态
        CompMarketState storage supplyState = compSupplyState[cToken];
        
        // 获取全局供应指数。将 uint 类型的指数转换为 Double 类型（用于定点数运算）
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        
        // 获取用户的旧快照
        Double memory supplierIndex = Double({mantissa: compSupplierIndex[cToken][supplier]});
        
        // 更新用户的快照到最新。下次再调用此函数时，supplierIndex 就是最新的了，不会重复计算奖励
        compSupplierIndex[cToken][supplier] = supplyIndex.mantissa;

        // 首次参与的特殊处理：如果是用户第一次参与该市场，设置初始指数
        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = compInitialIndex;
        }

        // 计算指数差异：计算从用户上次快照到现在，指数增长了多少
        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        
        // 获取用户持有的代币数量
        uint supplierTokens = CToken(cToken).balanceOf(supplier);
        
        // 计算用户应得的 COMP：用户应得的 COMP = 持有的代币数量 × 指数增长
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        
        // 累加到总债权：将这次新增的 COMP 累加到用户的总债权中
        uint supplierAccrued = add_(compAccrued[supplier], supplierDelta);
        compAccrued[supplier] = supplierAccrued;
        
        emit DistributedSupplierComp(CToken(cToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    // 为分发 COMP 奖励  -  borrow
    function distributeBorrowerComp(address cToken, address borrower, Exp memory marketBorrowIndex) internal {
        CompMarketState storage borrowState = compBorrowState[cToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: compBorrowerIndex[cToken][borrower]});
        compBorrowerIndex[cToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(CToken(cToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(compAccrued[borrower], borrowerDelta);
            compAccrued[borrower] = borrowerAccrued;
            emit DistributedBorrowerComp(CToken(cToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    // 更新贡献者应该获取comp数量
    function updateContributorRewards(address contributor) public {
        uint compSpeed = compContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && compSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, compSpeed);
            uint contributorAccrued = add_(compAccrued[contributor], newAccrued);

            compAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    // 领取用户在所有市场的所有 COMP 奖励（包含存款和借贷的comp奖励）
    function claimComp(address holder) public {
        return claimComp(holder, allMarkets);
    }

    // 内部函数：领取用户在所有市场的所有 COMP 奖励（包含存款和借贷的comp奖励）
    // 参数：holder：接受地址、ctokens：领取 COMP 的市场列表
    function claimComp(address holder, CToken[] memory cTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimComp(holders, cTokens, true, true);
    }

    // 内部函数：领取用户在所有市场的所有 COMP 奖励（包含存款和借贷的comp奖励）
    // 参数：holders：领取人、cTokens：领取 COMP 的市场列表、borrowers：是否领取借入所得的COMP、suppliers：是否要求通过供应获得的COMP
    function claimComp(address[] memory holders, CToken[] memory cTokens, bool borrowers, bool suppliers) public {
        // 遍历市场列表
        for (uint i = 0; i < cTokens.length; i++) {
            CToken cToken = cTokens[i];
            require(markets[address(cToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
                updateCompBorrowIndex(address(cToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerComp(address(cToken), holders[j], borrowIndex);
                    compAccrued[holders[j]] = grantCompInternal(holders[j], compAccrued[holders[j]]);
                }
            }
            if (suppliers == true) {
                updateCompSupplyIndex(address(cToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierComp(address(cToken), holders[j]);
                    compAccrued[holders[j]] = grantCompInternal(holders[j], compAccrued[holders[j]]);
                }
            }
        }
    }

    // 内部函数：转移COMP代币
    function grantCompInternal(address user, uint amount) internal returns (uint) {
        Comp comp = Comp(getCompAddress());
        uint compRemaining = comp.balanceOf(address(this));
        if (amount > 0 && amount <= compRemaining) {
            comp.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    // 管理员 直接将COMP转移给 recipient
    function _grantComp(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant comp");
        uint amountLeft = grantCompInternal(recipient, amount);
        require(amountLeft == 0, "insufficient comp for grant");
        emit CompGranted(recipient, amount);
    }

    // =============================================================================================
    //                                  其他功能
    // =============================================================================================

    /**
     * @notice 返回所有市场
     * @dev 自动获取器可用于访问单个市场。
     * @return 市场地址列表
     */
    function getAllMarkets() public view returns (CToken[] memory) {
        return allMarkets;
    }

    // 获取最新区块
    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    // COMP代币地址
    function getCompAddress() public view returns (address) {
        return 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    }
}
