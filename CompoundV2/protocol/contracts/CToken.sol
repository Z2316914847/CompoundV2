// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";      // 控制器接口
import "./CTokenInterfaces.sol";          // CToken 接口
import "./ErrorReporter.sol";             // 错误报告器：token 和 Comptroller
import "./EIP20Interface.sol";            // EIP-20 接口
import "./InterestRateModel.sol";         // 利率模型
import "./ExponentialNoError.sol";        // 指数运算库（无错误版本）

abstract contract CToken is CTokenInterface, ExponentialNoError, TokenErrorReporter {

    // 为什么不用构造函数初始化，而是是由 initialize 函数初始化？
    //   因为：构造函数在代理模式下无法工作，所以使用 initialize 函数来初始化合约状态
    // 参数：comptroller_：控制器地址、interestRateModel_：利率模型地址、initialExchangeRateMantissa_：初始兑换率（1e18精度）、name_：EIP-20 代币名称、symbol_：EIP-20 代币符号、decimals_：EIP-20 代币小数位数
    function initialize(ComptrollerInterface comptroller_,
                        InterestRateModel interestRateModel_,
                        uint initialExchangeRateMantissa_,     //设置初始化兑换率：0.02e18
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public {
        require(msg.sender == admin, "only admin may initialize the market");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // 1、设置初始兑换率
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");

        // 2、设置控制器
        uint err = _setComptroller(comptroller_);
        require(err == NO_ERROR, "setting comptroller failed");

        // 3、初始化区块号
        accrualBlockNumber = getBlockNumber();
        // 3.1、借款指数初始化为 1e18
        borrowIndex = mantissaOne;

        // 4、设置利率模型（取决于区块号/借入指数）
        err = _setInterestRateModelFresh(interestRateModel_);
        require(err == NO_ERROR, "setting interest rate model failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // 5、启用重入锁: 计数器启动为真，以防止将其从零更改为非零（即较小的成本/退款）
        _notEntered = true;
    }

    // =============================================================================================
    //                                 一：ERC-20 代币功能模块
    // =============================================================================================

    // 将 CToken 从调用者转账到目标地址
    function transfer(address dst, uint256 amount) override external nonReentrant returns (bool) {
        // 为什么是四个参数？答：一个函数处理两种转账场景（普通转账、被授权人使用津贴进行转账）、明确区分调用者和发送方
        // 第一个参数：实际执行转账操作的地址（调用者）
        // 第二个参数：代币来源地址（发送方）
        return transferTokens(msg.sender, msg.sender, dst, amount) == NO_ERROR;
    }

    // 通过 `spender` 将 `tokens` 代币从 `src` 转移到 `dst`
    // 参数：spender：实际执行转账操作的地址（调用者）、src：代币来源地址（发送方）、dst：目标账户的地址、tokens：要传输的代币数量
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        // 进行权限检查目的：
        //   1、检查市场是否被暂停，停止的话，就不让转账。
        //   2、检查转账后，账户抵押率是否健康，健康的话，就让转账，反之，不让账户转账。💧
        // uint和int分别是uint256和int256别名. uint不能为负数,int可以为负数
        uint allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        // 使用自定义错误，节省Gas。
        //   抛出异常有以下几种：require(condition,"message")、require(condition,error)、assert(boll condition)、revert()、revert(string memory string)、revert error()。
        //   三者具体差别可以查看我的文档（solidity-错误）：https://github.com/Z2316914847/foundry_Study/blob/main/task/day12/project/opensapce_%E5%AD%A6%E4%B9%A0_%E9%9A%8F%E6%89%8B%E7%AC%94%E8%AE%B0.md
        if (allowed != 0) {
            revert TransferComptrollerRejection(allowed);
        }

        // 不允许自己给自己转账 
        if (src == dst) {
            revert TransferNotAllowed();
        }

        // 获取津贴，账户所有者可以使用账户所有金额，被授权者只能使用被授权的津贴金额
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = type(uint).max;      // type(uint256).max` 表示无限授权
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        // 这里采用,进行计算然后赋值。调试内容简单、遵循 检查-效果-交互模式
        // 注意 solidity0.8.0+ 有溢出检查。
        uint allowanceNew = startingAllowance - tokens;
        uint srcTokensNew = accountTokens[src] - tokens;
        uint dstTokensNew = accountTokens[dst] + tokens;
        
        // 遵循 检查-效果-交互模式

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        // 被授权者津贴更新
        if (startingAllowance != type(uint).max) {
            transferAllowances[src][spender] = allowanceNew;
        }

        // 我们发出一个 Transfer 事件 
        emit Transfer(src, dst, tokens);

        // 未使用的功能
        // comptroller.transferVerify(地址(this), src, dst, 令牌);

        // no_Error = 0
        return NO_ERROR;
    }

    // 授权转账
    // 参数：src：源账户地址、dst：目标账户地址、amount：要转账的代币数量
    function transferFrom(address src, address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == NO_ERROR;
    }

    // 授权
    // 参数：spender：目标账户地址、amount：要授权的代币数量
    function approve(address spender, uint256 amount) override external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    // 查询授权额度, 允许花费的代币数量（-1表示无限）
    function allowance(address owner, address spender) override external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    // 查询余额
    function balanceOf(address owner) override external view returns (uint256) {
        return accountTokens[owner];
    }

    // 查询底层资产余额。底层资产余额 = CToken 余额 × 最新兑换率
    // 返回：指定地址持有的 CToken 可以兑换的底层资产数量。
    function balanceOfUnderlying(address owner) override external returns (uint) {
        // 获取最新兑汇率 = (池子内当前最新底层资产余额 + 池子内当前最新 所有借款人的总借款额 - 池子内最新协议存储金 ）/ 已发行的cToken总量
        Exp memory exchangeRate = Exp({
            mantissa: exchangeRateCurrent()
        });
        // 底层资产 = CToken 余额 × 最新兑换率
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    // =============================================================================================
    //                                 二：存款（Mint）模块
    // =============================================================================================

    // 内部存款函数：发送者向市场提供资产并接收 cToken 作为交换，无论操作是否成功都会产生利息，除非恢复
    // 参数：mintAmount 提供的基础资产数量
    function mintInternal(uint mintAmount) internal nonReentrant {
        accrueInterest();
        // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        mintFresh(msg.sender, mintAmount);
    }

    // 铸造 CToken
    function mintFresh(address minter, uint mintAmount) internal {
        // 1、验证是否允许存款
        uint allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != 0) {
            revert MintComptrollerRejection(allowed);
        }

        // 2、新鲜度检查：验证市场的区块号等于当前区块号
        if (accrualBlockNumber != getBlockNumber()) {
            revert MintFreshnessCheck();
        }

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});

        /////////////////////////
        // 效果与相互作用
        // （超出此点没有安全故障）

        /*
         *我们为铸币者和铸币金额调用“doTransferIn”。
         *  注意：cToken 必须处理 ERC-20 和 ETH 底层之间的差异。
         *如果出现任何问题，`doTransferIn` 会恢复，因为我们无法确定是否
         *发生副作用。该函数返回实际转账的金额，
         *如果需要付费。成功后，cToken 会持有额外的“actualMintAmount”
         *现金。
         */
        // 3、转入资产：从用户转入底层资产
        uint actualMintAmount = doTransferIn(minter, mintAmount);

        /*
         *我们获取当前汇率并计算要铸造的 cToken 数量：
         *mintTokens = 实际MintAmount /兑换率
         */
        // 4、计算铸造量
        uint mintTokens = div_(actualMintAmount, exchangeRate);

        /*
         *我们计算新的 cToken 总供应量和铸币者代币余额，检查是否溢出：
         *新增供应总量 = 供应总量 + mintTokens
         *accountTokensNew = accountTokens[minter] + mintTokens
         *并将它们写入存储
         */
        // 5、更新状态
        totalSupply = totalSupply + mintTokens;
        accountTokens[minter] = accountTokens[minter] + mintTokens;

        // 6、触发事件：我们发出一个 Mint 事件和一个 Transfer 事件
        emit Mint(minter, actualMintAmount, mintTokens);
        emit Transfer(address(this), minter, mintTokens);

        // 我们称之为防御钩子
        // 未使用的功能
        // comptroller.mintVerify(address(this), minter, actualMintAmount, mintTokens);
    }

    // =============================================================================================
    //                                 三：赎回（Redeem）模块
    // =============================================================================================

    // 按 CToken 数量赎回：销毁指定数量的 CToken，赎回底层资产
    function redeemInternal(uint redeemTokens) internal nonReentrant {
        accrueInterest();
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        redeemFresh(payable(msg.sender), redeemTokens, 0);
    }

    // 按底层资产数量赎回：赎回指定数量的底层资产，自动计算需要销毁的 CToken
    function redeemUnderlyingInternal(uint redeemAmount) internal nonReentrant {
        accrueInterest();
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        redeemFresh(payable(msg.sender), 0, redeemAmount);
    }

    // 赎回核心逻辑
    // 参数：redeemer：赎回账户地址、redeemTokensIn：要赎回的 cToken 数量（redeemTokensIn 或 redeemAmountIn 只能有一个非零）、redeemAmountIn：要从赎回 cToken 中接收的基础资产数量（redeemTokensIn 或 redeemAmountIn 只能有一个非零）
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        // 1、ExchangeRate = 调用 Exchange Rate Stored() 
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal() });

        // 2、计算赎回量
        uint redeemTokens;
        uint redeemAmount;
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            // 如果指定了 CToken 数量
            redeemTokens = redeemTokensIn;
            redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokensIn);
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */
            // 如果指定了底层资产数量
            redeemTokens = div_(redeemAmountIn, exchangeRate);
            redeemAmount = redeemAmountIn;
        }

        // 3、权限检查
        uint allowed = comptroller.redeemAllowed(address(this), redeemer, redeemTokens);
        if (allowed != 0) {
            revert RedeemComptrollerRejection(allowed);
        }

        // 4、流动性检查
        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert RedeemFreshnessCheck();
        }

        /* Fail gracefully if protocol has insufficient cash */
        if (getCashPrior() < redeemAmount) {
            revert RedeemTransferOutNotPossible();
        }

        /////////////////////////
        // 效果与相互作用
        // （超出此点没有安全故障）


        /*
         *我们将之前计算的值写入存储中。
         *  注意：通过在外部传输之前写入减少的供应量来避免代币重入攻击。
         */
        // 5、更新状态
        totalSupply = totalSupply - redeemTokens;
        accountTokens[redeemer] = accountTokens[redeemer] - redeemTokens;

        /*
         *我们为赎回者和赎回金额调用 doTransferOut。
         *  注意：cToken 必须处理 ERC-20 和 ETH 底层之间的差异。
         *成功后，cToken 的赎回金额会少于现金。
         *如果出现任何问题，doTransferOut 会恢复，因为我们无法确定是否发生了副作用。
         */
        // 6、转出资产
        doTransferOut(redeemer, redeemAmount);

        // 7、触发事件
        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens);

        // 我们称之为防御钩子
        comptroller.redeemVerify(address(this), redeemer, redeemAmount, redeemTokens);
    }

    // =============================================================================================
    //                                四：借款（Borrow）模块
    // =============================================================================================

    // 借款入口：从协议借出底层资产
    function borrowInternal(uint borrowAmount) internal nonReentrant {
        accrueInterest();
        // borrowFresh 会发出特定于借用的错误日志，因此我们不需要
        borrowFresh(payable(msg.sender), borrowAmount);
    }

    // 借款核心逻辑
    function borrowFresh(address payable borrower, uint borrowAmount) internal {
        // 权限检查
        uint allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != 0) {
            revert BorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert BorrowFreshnessCheck();
        }

        /* Fail gracefully if protocol has insufficient underlying cash */
        if (getCashPrior() < borrowAmount) {
            revert BorrowCashNotAvailable();
        }

        /*
         *我们计算新借款人和总借款余额，溢出失败：
         *accountBorrowNew = accountBorrow + 借入金额
         *借入总额 = 借入总额 + 借入金额
         */
        // 计算新记账
        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);
        uint accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint totalBorrowsNew = totalBorrows + borrowAmount;

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)
        
        /*
         *我们将之前计算的值写入存储中。
         *注意：通过在外部转账之前写入增加的借入来避免代币重入攻击。
        `*/
        // 更新借款快照
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        /*
         *我们为借款人和借用金额调用 doTransferOut。
         *  注意：cToken 必须处理 ERC-20 和 ETH 底层之间的差异。
         *成功后，cToken 借入金额减去现金。
         *如果出现任何问题，doTransferOut 会恢复，因为我们无法确定是否发生了副作用。
         */
        // 转出资产
        doTransferOut(borrower, borrowAmount);

        // 触发事件
        emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    }

    // =============================================================================================
    //                                 五；偿还借款（Repay Borrow）模块
    // =============================================================================================

    // 还是自己的款
    // 参数：repayAmount 要偿还的金额，或 -1 表示全部未偿还金额
    function repayBorrowInternal(uint repayAmount) internal nonReentrant {
        accrueInterest();
        // repayBorrowFresh 会发出特定于还款借用的错误日志，因此我们不需要
        repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    // 代他人还款
    function repayBorrowBehalfInternal(address borrower, uint repayAmount) internal nonReentrant {
        accrueInterest();
        repayBorrowFresh(msg.sender, borrower, repayAmount);
    }

    // 还款核心逻辑
    function repayBorrowFresh(address payer, address borrower, uint repayAmount) internal returns (uint) {
        // 权限检查
        uint allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            revert RepayBorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert RepayBorrowFreshnessCheck();
        }

        // 我们获取借款人所欠金额以及累积利息 
        // 计算还款额
        // 借款人当前欠款
        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

        // 如果 repayAmount == -1, repayAmount = accountBorrows
        uint repayAmountFinal = repayAmount == type(uint).max ? accountBorrowsPrev : repayAmount;

        /////////////////////////
        // 效果与相互作用
        // （超出此点没有安全故障）

        /*
         *我们为付款人和 repayAmount 调用 doTransferIn
         *  注意：cToken 必须处理 ERC-20 和 ETH 底层之间的差异。
         *成功后，cToken 会持有额外的还款金额现金。
         *如果出现任何问题，doTransferIn 就会恢复，因为我们无法确定是否发生了副作用。
         *如果需要付费，则返回实际转账的金额。
         */
        // 转入资产
        uint actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        /*
         *我们计算新借款人和总借款余额，未发生下溢：
         *accountBorrowsNew = accountBorrows -实际还款金额
         *新增借款总额 = 借款总额 -实际还款金额
         */
        // 更新借款
        uint accountBorrowsNew = accountBorrowsPrev - actualRepayAmount;
        uint totalBorrowsNew = totalBorrows - actualRepayAmount;
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        // 触发事件 
        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);

        return actualRepayAmount;
    }

    // =============================================================================================
    //                                六：清算借款（Liquidate Borrow）模块
    // =============================================================================================

    // 清算入口
    // 参数：borrower 要清算的借款人地址、repayAmount 偿还的借款金额、cTokenCollateral 用作抵押品的 cToken 市场/地址
    function liquidateBorrowInternal(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) internal nonReentrant {
        accrueInterest();

        uint error = cTokenCollateral.accrueInterest();
        if (error != NO_ERROR) {
            // accrueInterest 发出错误日志，但我们仍然想记录尝试清算失败的事实
            revert LiquidateAccrueCollateralInterestFailed(error);
        }

        // LiquidateBorrowFresh 会发出特定于借用的错误日志，因此我们不需要
        liquidateBorrowFresh(msg.sender, borrower, repayAmount, cTokenCollateral);
    }

    // 清算核心逻辑
    function liquidateBorrowFresh(address liquidator, address borrower, uint repayAmount, CTokenInterface cTokenCollateral) internal {
        // 1、权限检查
        uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(cTokenCollateral), liquidator, borrower, repayAmount);
        if (allowed != 0) {
            revert LiquidateComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert LiquidateFreshnessCheck();
        }

        /* Verify cTokenCollateral market's block number equals current block number */
        if (cTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
            revert LiquidateCollateralFreshnessCheck();
        }

        // 2、验证条件：不能自我清算、 还款金额 不能为 0 && 不能为 -1
        if (borrower == liquidator) {
            revert LiquidateLiquidatorIsBorrower();
        }

        if (repayAmount == 0) {
            revert LiquidateCloseAmountIsZero();
        }

        if (repayAmount == type(uint).max) {
            revert LiquidateCloseAmountIsUintMax();
        }

        // 3、代偿债务
        uint actualRepayAmount = repayBorrowFresh(liquidator, borrower, repayAmount);

        /////////////////////////
        // 效果与相互作用
        // （超出此点没有安全故障）

        // 4、计算清算获得
        // 我们计算将被扣押的抵押代币数量
        (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateCalculateSeizeTokens(address(this), address(cTokenCollateral), actualRepayAmount);
        require(amountSeizeError == NO_ERROR, "LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");

        // 如果借款人抵押代币余额 < acquireTokens 则恢复 
        require(cTokenCollateral.balanceOf(borrower) >= seizeTokens, "LIQUIDATE_SEIZE_TOO_MUCH");

        // 5、执行扣押：如果这也是抵押品，请运行 acquireInternal 以避免重入，否则进行外部调用
        if (address(cTokenCollateral) == address(this)) {
            seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            require(cTokenCollateral.seize(liquidator, borrower, seizeTokens) == NO_ERROR, "token seizure failed");
        }

        // 6、触发事件
        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(cTokenCollateral), seizeTokens);
    }

    //  将抵押代币（本市场）转移给清算人。
    // 除非在清算过程中被另一个 cToken 调用，否则将会失败。
    //  *使用 msg.sender 作为借用的 cToken 而不是参数绝对至关重要。
    //  * @param Liquidator 接收扣押抵押品的账户
    //  * @param 借款人 已扣押抵押品的账户
    //  * @param acquireTokens 要抢占的 cToken 数量
    //  * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
    // 扣押抵押品
    function seize(address liquidator, address borrower, uint seizeTokens) override external nonReentrant returns (uint) {
        seizeInternal(msg.sender, liquidator, borrower, seizeTokens);

        return NO_ERROR;
    }

    //  将抵押代币（本市场）转移给清算人。
    //  * @dev 仅在实物清算期间调用，或在另一个 CToken 清算期间由 LiquidateBorrow 调用。
    //  *使用 msg.sender 作为抢占器 cToken 而不是参数绝对至关重要。
    //  * @param acquirerToken 扣押抵押品的合约（即借来的 cToken）
    //  * @param Liquidator 接收扣押抵押品的账户
    //  * @param 借款人 已扣押抵押品的账户
    //  * @param seizeTokens The number of cTokens to seize
    // 扣押抵押品
    function seizeInternal(address seizerToken, address liquidator, address borrower, uint seizeTokens) internal {
        // 1、权限检查
        uint allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != 0) {
            revert LiquidateSeizeComptrollerRejection(allowed);
        }

        if (borrower == liquidator) {
            revert LiquidateSeizeLiquidatorIsBorrower();
        }

        /*
         * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
         *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
         *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
         */
        // 计算分配：protocolSeizeTokens（协议分成：2.8%），liquidatorSeizeTokens：清算人获得
        uint protocolSeizeTokens = mul_(seizeTokens, Exp({mantissa: protocolSeizeShareMantissa}));
        uint liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens;
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
        // 更新储备金
        uint protocolSeizeAmount = mul_ScalarTruncate(exchangeRate, protocolSeizeTokens);
        uint totalReservesNew = totalReserves + protocolSeizeAmount;


        /////////////////////////
        // 效果与相互作用
        // （超出此点没有安全故障）

        // 转移 CToken
        totalReserves = totalReservesNew;
        totalSupply = totalSupply - protocolSeizeTokens;
        accountTokens[borrower] = accountTokens[borrower] - seizeTokens;
        accountTokens[liquidator] = accountTokens[liquidator] + liquidatorSeizeTokens;

        // 触发事件
        emit Transfer(borrower, liquidator, liquidatorSeizeTokens);
        emit Transfer(borrower, address(this), protocolSeizeTokens);
        emit ReservesAdded(address(this), protocolSeizeAmount, totalReservesNew);
    }

    // =============================================================================================
    //                                 七；利息累积模块
    // =============================================================================================

    // 利息累积:更新了这些内容: 最新区块号, 最新借贷指数, 最新借贷总额, 最新储备金
    function accrueInterest() virtual override public returns (uint) {
        // 获取基础数据
        //   获取最新区块号
        uint currentBlockNumber = getBlockNumber();
        //   上一次累计利息的区块号
        uint accrualBlockNumberPrior = accrualBlockNumber;

        // 如果上一次累计利息区块号 == 最新区块号, 那么累计利息 就用上次计算的. 
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return NO_ERROR;
        }

        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;
        
        // 计算当前 每个区块的借款利率
        // 为什么借贷利率不保存起来,而是每次来获取
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        // 计算自上次累积以来经过的区块数
        uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        /*
         *计算借款和准备金累计利息以及新指数：
         *simpleInterestFactor = 借入率 *blockDelta
         *累计利息 = simpleInterestFactor *总借款
         *新借款总额 = 累计利息 + 借款总额
         *总储备新 = 利息累计 *储备系数 + 总储备
         *借用指数新 = 简单利息系数 *借用指数 + 借用指数
         */
        // 计算这段时间的累计利率
        Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
        // 计算这段时间用户利息 = 这段时间的累计利率 * 最初贷款
        uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
        // 新借款总额 = 这段时间的累计利息 + 最初借贷的借款总额
        uint totalBorrowsNew = interestAccumulated + borrowsPrior;
        // 更新储备金 = 之前储备金 + 新添加储备金: 从这段时间内用户支付的利息 抽取 x%资金 划入储备金内
        uint totalReservesNew = mul_ScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        // 累计利息指数 = 简单利息系数 * 上一次累计利息指数 + 上一次累计利息指数
        uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

        // 遵循 检查-效果-交互模式

        // 更新状态: 最新区块号, 最新借贷指数, 最新借贷总额, 最新储备金
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        // 触发事件
        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

        return NO_ERROR;
    }

    // =============================================================================================
    //                                八：兑换率与利率查询模块
    // =============================================================================================
    
    // 获取最新兑换率 = (池子内当前最新底层资产余额 + 池子内当前最新 所有借款人的总借款额 - 池子内最新协议存储金 ）/ 已发行的cToken总量
    // 注意： 计算汇率按 1e18 缩放
    function exchangeRateCurrent() override public nonReentrant returns (uint) {
        // 更新最新区块号, 最新借贷指数, 最新借贷总额, 最新储备金
        //   我获取最新兑换率, 为什么还要更新其他数据? 答: 因为最新兑换率中使用到了 底层资产, 借贷总额, 储备金, 所以要将这些数据更新 
        //   更新三项即可, 为什么还要更新区块号? 答: 因为这 累计利息 涉及到 最新区块号，所以要更新最新区块号。
        //   计算这段时间的利率 = 这段时间的区号数 * 每个区块的利率
        accrueInterest();
        // 返回兑换率
        return exchangeRateStored();
    }

    // 存储的兑换率（不计息）
    function exchangeRateStored() override public view returns (uint) {
        return exchangeRateStoredInternal();
    }

    // 兑换率计算
    function exchangeRateStoredInternal() virtual internal view returns (uint) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // 最新兑换率 = 初始兑换率(初始兑换率是部署Ctoken后,用户调用ctoken中 initialize()函数时设置的)
            return initialExchangeRateMantissa;
        } else {
            // exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
            //   参数（针对上面函数）：otalCash: 获取底层资产, totalBorrows: 最新的借贷总额, totalReserves: 储备金
            uint totalCash = getCashPrior();
            uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            uint exchangeRate = cashPlusBorrowsMinusReserves * expScale / _totalSupply;

            return exchangeRate;
        }
    }

    // 每区块借款利率
    function borrowRatePerBlock() override external view returns (uint) {
        return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    // 每区块存款利率
    //   存款利率 = 借款利率 × 资金利用率 × (1 - 储备金系数)
    function supplyRatePerBlock() override external view returns (uint) {
        return interestRateModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    // 当前借款余额（含利息）：对更新后的borrowIndex 累积利息，然后使用更新后的borrowIndex 计算帐户的借入余额
    function borrowBalanceCurrent(address account) override external nonReentrant returns (uint) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    // 存储的借款余额。不触发计息，基于存储数据计算
    function borrowBalanceStored(address account) override public view returns (uint) {
        return borrowBalanceStoredInternal(account);
    }

    // 账户快照：获取账户余额的快照以及缓存的汇率
    // 用途：控制器用于高效的流动性检查
    // 返回：（错误代码（0表达成功）、ctoken代币余额、借款余额、兑换率）
    function getAccountSnapshot(address account) override external view returns (uint, uint, uint, uint) {
        return (
            NO_ERROR,
            accountTokens[account],
            borrowBalanceStoredInternal(account),
            exchangeRateStoredInternal()
        );
    }

    // =============================================================================================
    //                                 九；管理员功能模块
    // =============================================================================================

    /**
      * @notice 开始转移管理权限。 newPendingAdmin 必须调用 `_acceptAdmin` 来完成传输。
      * @dev 管理功能开始更改管理员。 newPendingAdmin 必须调用 `_acceptAdmin` 来完成传输。
      * @param newPendingAdmin 新的待处理管理员。
      * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
      */
    // 设置待定管理员
    function _setPendingAdmin(address payable newPendingAdmin) override external returns (uint) {
        // Check caller = admin
        if (msg.sender != admin) {
            revert SetPendingAdminOwnerCheck();
        }

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

        return NO_ERROR;
    }

    /**
      * @notice 接受管理权限的转让。 msg.sender 必须待处理管理员
      * @dev 管理功能，供待处理的管理员接受角色并更新管理
      * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
      */
    // 接受管理员权限
    function _acceptAdmin() override external returns (uint) {
        // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            revert AcceptAdminPendingAdminCheck();
        }

        // Save current values for inclusion in log
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        admin = pendingAdmin;

        // Clear the pending value
        pendingAdmin = payable(address(0));

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

        return NO_ERROR;
    }

    // 设置控制器
    function _setComptroller(ComptrollerInterface newComptroller) override public returns (uint) {
        // 检查是否为管理员，只有管理员才能设置新的控制器
        if (msg.sender != admin) {
            revert SetComptrollerOwnerCheck();
        }

        ComptrollerInterface oldComptroller = comptroller;
        // 确保调用 comptroller.isComptroller() 返回 true
        require(newComptroller.isComptroller(), "marker method returned false");

        // 将市场的控制器设置为 newComptroller
        comptroller = newComptroller;

        // 触发事件
        emit NewComptroller(oldComptroller, newComptroller);

        return NO_ERROR;
    }

    /**
      * @notice 累积利息并使用 _setReserveFactorFresh 为协议设置新的储备因子
      * @dev 管理功能可累积利息并设置新的准备金系数
      * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
      */
    // 储备金系数
    // 参数：newReserveFactorMantissa 新的储备因子乘数(1e18 精度，如 0.1e18 = 10%)
    function _setReserveFactor(uint newReserveFactorMantissa) override external nonReentrant returns (uint) {
        accrueInterest();
        // _setReserveFactorFresh 会发出特定于保留因子的错误日志，因此我们不需要这样做。
        return _setReserveFactorFresh(newReserveFactorMantissa);
    }

    /**
     * @notice 累积利息并使用 _setInterestRateModelFresh 更新利率模型
     * @dev 管理功能，用于累积利息和更新利率模型
     * @param newInterestRateModel 要使用的新利率模型
     * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
     */
    // 设置利率模型
    function _setInterestRateModel(InterestRateModel newInterestRateModel) override public returns (uint) {
        accrueInterest();
        // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
        return _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
     * @notice 通过从 msg.sender 转账来累积利息并减少准备金
     * @param addAmount 储备金添加量
     * @return uint 0=成功，否则失败（详情参见ErrorReporter.sol）
     */
    // 增加储备金
    function _addReservesInternal(uint addAmount) internal nonReentrant returns (uint) {
        accrueInterest();

        // _addReservesFresh 会发出有关错误的保留添加特定日志，因此我们不需要这样做。
        _addReservesFresh(addAmount);
        return NO_ERROR;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    // 提取储备金, 仅管理员
    function _reduceReserves(uint reduceAmount) override external nonReentrant returns (uint) {
        accrueInterest();
        // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
        return _reduceReservesFresh(reduceAmount);
    }

    // =============================================================================================
    //                                 十：虚拟函数（需要子合约实现
    // =============================================================================================

    /**
     * @notice 获取该合约的标的余额
     * @dev 这不包括当前消息的值（如果有）
     * @return 该合约拥有的底层证券数量
     */
    // 获取合约持有的底层资产
    function getCashPrior() virtual internal view returns (uint);

    /**
     *@dev 执行转入，失败时恢复。如果需要付费，则返回实际转移到协议的金额。
     *这可能会因余额不足或津贴不足而恢复。
     */
    // 转入资产
    function doTransferIn(address from, uint amount) virtual internal returns (uint);

    /**
     *@dev 执行转出，理想情况下在失败时返回解释性错误代码而不是恢复。
     *如果调用者没有调用检查协议的余额，可能会因合约中持有的现金不足而恢复。
     *如果调用者检查了协议的余额，并验证其 >= 金额，则在正常情况下不应恢复。
     */
    // 转出资产
    function doTransferOut(address payable to, uint amount) virtual internal;

    // =============================================================================================
    //                                 十一：重入防护
    // =============================================================================================

    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    // =============================================================================================
    //                                 未知函数模块
    // =============================================================================================

    // 为协议设置新的准备金系数（*需要新的应计利息）
    // 返回；uint 0=成功，否则失败（详情参见ErrorReporter.sol）
    function _setReserveFactorFresh(uint newReserveFactorMantissa) internal returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            revert SetReserveFactorAdminCheck();
        }

        // Verify market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert SetReserveFactorFreshCheck();
        }

        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorMantissa > reserveFactorMaxMantissa) {
            revert SetReserveFactorBoundsCheck();
        }

        uint oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;

        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

        return NO_ERROR;
    }

    /**
     * @notice Add reserves by transferring from caller
     * @dev Requires fresh interest accrual
     * @param addAmount Amount of addition to reserves
     * @return (uint, uint) An error code (0=success, otherwise a failure (see ErrorReporter.sol for details)) and the actual amount added, net token fees
     */
    function _addReservesFresh(uint addAmount) internal returns (uint, uint) {
        // totalReserves + actualAddAmount
        uint totalReservesNew;
        uint actualAddAmount;

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert AddReservesFactorFreshCheck(actualAddAmount);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the caller and the addAmount
         *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the cToken holds an additional addAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *  it returns the amount actually transferred, in case of a fee.
         */

        actualAddAmount = doTransferIn(msg.sender, addAmount);

        totalReservesNew = totalReserves + actualAddAmount;

        // Store reserves[n+1] = reserves[n] + actualAddAmount
        totalReserves = totalReservesNew;

        /* Emit NewReserves(admin, actualAddAmount, reserves[n+1]) */
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

        /* Return (NO_ERROR, actualAddAmount) */
        return (NO_ERROR, actualAddAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReservesFresh(uint reduceAmount) internal returns (uint) {
        // totalReserves - reduceAmount
        uint totalReservesNew;

        // Check caller is admin
        if (msg.sender != admin) {
            revert ReduceReservesAdminCheck();
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert ReduceReservesFreshCheck();
        }

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < reduceAmount) {
            revert ReduceReservesCashNotAvailable();
        }

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        if (reduceAmount > totalReserves) {
            revert ReduceReservesCashValidation();
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        totalReservesNew = totalReserves - reduceAmount;

        // Store reserves[n+1] = reserves[n] - reduceAmount
        totalReserves = totalReservesNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);

        return NO_ERROR;
    }

    /**
     * @notice updates the interest rate model (*requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint) {

        // Used to store old model for use in the event that is emitted on success
        InterestRateModel oldInterestRateModel;

        // Check caller is admin
        if (msg.sender != admin) {
            revert SetInterestRateModelOwnerCheck();
        }

        // We fail gracefully unless market's block number equals current block number
        if (accrualBlockNumber != getBlockNumber()) {
            revert SetInterestRateModelFreshCheck();
        }

        // Track the market's current interest rate model
        oldInterestRateModel = interestRateModel;

        // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
        require(newInterestRateModel.isInterestRateModel(), "marker method returned false");

        // Set the interest rate model to newInterestRateModel
        interestRateModel = newInterestRateModel;

        // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);

        return NO_ERROR;
    }

    // 函数来简单地检索块号这主要是为了继承测试合约来存根这个结果。
    function getBlockNumber() virtual internal view returns (uint) {
        return block.number;
    }

    // 返回当前总借款加上应计利息
    function totalBorrowsCurrent() override external nonReentrant returns (uint) {
        accrueInterest();
        return totalBorrows;
    }

    // 根据存储的数据返回账户的借入余额
    // 返回：错误代码，计算出的余额或如果错误代码非零则为0）
    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        /* Get borrowBalance and borrowIndex */
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        /* If borrowBalance = 0 then borrowIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        /* Calculate new borrow balance using the interest index:
         *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
         */
        uint principalTimesIndex = borrowSnapshot.principal * borrowIndex;
        return principalTimesIndex / borrowSnapshot.interestIndex;
    }

    // 获取该cToken在基础资产中的现金余额
    // 返回：本合约拥有的标的资产数量
    function getCash() override external view returns (uint) {
        return getCashPrior();
    }
}
