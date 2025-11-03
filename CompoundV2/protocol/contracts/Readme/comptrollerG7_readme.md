# ComptrollerG7 合约文档

目录：
- 一：合约概述
- 二：合约状态变量
- 三：合约核心函数
- 四：重要机制详解
- 五：COMP 奖励分发机制详解
- 六：流动性与清算机制

## 一：合约概述

### 1.1 合约简介
ComptrollerG7 是 Compound 协议的**核心控制器合约**，负责管理所有市场（CToken）的规则和逻辑。它是用户与 CToken 交互时的中间层，负责：
- 市场准入控制和上架管理
- 借贷风险控制（抵押因子、清算等）
- 流动性计算和健康度检查
- COMP 治理代币奖励分发
- 市场暂停/恢复管理

### 1.2 继承关系
ComptrollerG7 继承自：
- `ComptrollerV5Storage` - 存储结构体定义
- `ComptrollerInterface` - 控制器接口定义
- `ComptrollerErrorReporter` - 错误报告器
- `ExponentialNoError` - 指数运算库（无错误版本）

### 1.3 关键概念

#### 市场（Market）
- 每个 CToken 对应一个市场
- 市场必须通过 `_supportMarket()` 上架才能使用
- 市场可以设置抵押因子（collateral factor）和借贷上限（borrow cap）

#### 账户流动性（Account Liquidity）
- **流动性余额（Liquidity）**：账户抵押品价值超过借贷价值的部分
- **流动性缺口（Shortfall）**：账户借贷价值超过抵押品价值的部分
- 当缺口 > 0 时，账户可能被清算

#### COMP 奖励
- COMP 是 Compound 协议的治理代币
- 用户通过存款（供应）和借款可以获得 COMP 奖励
- 奖励通过指数机制（Index）累积和分发

## 二：合约状态变量

### 2.1 市场相关
- `markets` - 市场映射，存储每个市场的配置信息
- `allMarkets` - 所有已上架市场的数组
- `accountAssets` - 用户参与的市场列表

### 2.2 风险控制参数
- `closeFactorMantissa` - 清算因子（每次最多清算借款的百分比）
- `collateralFactorMantissa` - 抵押因子（抵押品价值的可借比例）
- `liquidationIncentiveMantissa` - 清算激励（清算人获得的奖励比例）
- `borrowCaps` - 每个市场的借贷上限
- `borrowCapGuardian` - 借贷上限监护人

### 2.3 暂停机制
- `pauseGuardian` - 暂停监护人
- `mintGuardianPaused` - 市场级别的铸造暂停
- `borrowGuardianPaused` - 市场级别的借贷暂停
- `transferGuardianPaused` - 全局转账暂停
- `seizeGuardianPaused` - 全局扣押暂停

### 2.4 COMP 奖励相关
- `compSpeeds` - 每个市场的 COMP 发放速度（每秒）
- `compSupplyState` - 每个市场的供应指数状态
- `compBorrowState` - 每个市场的借贷指数状态
- `compSupplierIndex` - 每个用户在每个市场的供应快照
- `compBorrowerIndex` - 每个用户在每个市场的借贷快照
- `compAccrued` - 每个用户累积的 COMP 总额
- `compContributorSpeeds` - 贡献者的 COMP 发放速度
- `compInitialIndex` - COMP 初始指数（1e36）

### 2.5 管理员
- `admin` - 合约管理员地址
- `oracle` - 价格预言机

## 三：合约核心函数

### 3.1 市场准入管理

#### `enterMarkets(address[] cTokens)`
- **功能**：用户加入一个或多个市场
- **作用**：将市场添加到用户的资产列表中，用于流动性计算
- **触发**：用户手动调用，或首次借款时自动调用
- **事件**：`MarketEntered`

#### `exitMarket(address cTokenAddress)`
- **功能**：用户退出一个市场
- **前置条件**：
  - 用户没有未偿还的借款余额
  - 退出后账户流动性仍然健康
- **事件**：`MarketExited`

### 3.2 策略钩子函数（Policy Hooks）

这些函数在用户操作时被 CToken 合约调用：

#### `mintAllowed(address cToken, address minter, uint mintAmount)`
- **功能**：检查是否允许铸造（存款）
- **验证**：
  - 市场是否上架
  - 市场是否暂停铸造
- **奖励**：更新供应指数并分发 COMP 奖励

#### `redeemAllowed(address cToken, address redeemer, uint redeemTokens)`
- **功能**：检查是否允许赎回
- **验证**：
  - 如果用户参与了市场（用作抵押品），检查赎回后流动性是否充足
- **奖励**：更新供应指数并分发 COMP 奖励

#### `borrowAllowed(address cToken, address borrower, uint borrowAmount)`
- **功能**：检查是否允许借贷
- **验证**：
  - 市场是否上架和暂停
  - 如果用户未参与市场，自动加入
  - 检查借贷上限（borrow cap）
  - 检查借贷后账户流动性是否充足
- **奖励**：更新借贷指数并分发 COMP 奖励

#### `repayBorrowAllowed(address cToken, address payer, address borrower, uint repayAmount)`
- **功能**：检查是否允许偿还借款
- **奖励**：更新借贷指数并分发 COMP 奖励

#### `liquidateBorrowAllowed(...)`
- **功能**：检查是否允许清算
- **验证**：
  - 市场是否上架
  - 账户是否有流动性缺口（shortfall > 0）
  - 清算金额不超过最大清算金额（close factor）
- **返回**：错误码或成功

#### `seizeAllowed(...)`
- **功能**：检查是否允许扣押抵押品
- **验证**：
  - 全局扣押是否暂停
  - 市场是否上架
  - 防止跨协议攻击（检查 comptroller 是否匹配）
- **奖励**：为借款人和清算人分发抵押品市场的 COMP 奖励

#### `transferAllowed(address cToken, address src, address dst, uint transferTokens)`
- **功能**：检查是否允许转账
- **验证**：
  - 全局转账是否暂停
  - 发送方是否可以赎回这么多代币（流动性检查）
- **奖励**：为发送方和接收方分发 COMP 奖励

### 3.3 流动性计算

#### `getAccountLiquidity(address account)`
- **功能**：获取账户的流动性状态
- **返回**：
  - `error` - 错误码
  - `liquidity` - 流动性余额（超过抵押要求的部分）
  - `shortfall` - 流动性缺口（低于抵押要求的部分）

#### `getHypotheticalAccountLiquidity(...)`
- **功能**：假设执行某些操作后的流动性状态
- **用途**：在用户实际操作前，预测操作后的账户状态
- **参数**：
  - `cTokenModify` - 假设操作的市场
  - `redeemTokens` - 假设赎回的代币数量
  - `borrowAmount` - 假设借贷的金额

#### `liquidateCalculateSeizeTokens(...)`
- **功能**：计算清算时需要扣押的抵押品 cToken 数量
- **计算公式**：
  ```
  seizeTokens = actualRepayAmount × (liquidationIncentive × priceBorrowed) / (priceCollateral × exchangeRate)
  ```
- **返回**：错误码和需要扣押的 cToken 数量

### 3.4 COMP 奖励分发

#### `updateCompSupplyIndex(address cToken)`
- **功能**：更新供应市场的 COMP 指数
- **计算逻辑**：
  1. 计算经过的区块数：`deltaBlocks = 当前区块 - 上次更新区块`
  2. 计算总应发奖励：`compAccrued = deltaBlocks × supplySpeed`
  3. 计算每个代币的比率：`ratio = compAccrued / totalSupply`
  4. 更新全局指数：`index = 旧index + ratio`
- **作用**：累积历史奖励比率，用于后续用户奖励计算

#### `updateCompBorrowIndex(address cToken, Exp marketBorrowIndex)`
- **功能**：更新借贷市场的 COMP 指数
- **计算逻辑**：类似供应指数，但基于总借贷量而非总供应量

#### `distributeSupplierComp(address cToken, address supplier)`
- **功能**：计算并累积供应者的 COMP 奖励
- **计算逻辑**：
  1. 获取当前全局指数和用户上次快照
  2. 计算指数增长：`deltaIndex = 当前指数 - 用户快照`
  3. 计算用户奖励：`supplierDelta = 持币数量 × deltaIndex`
  4. 累加到用户总债权：`compAccrued[supplier] += supplierDelta`
  5. 更新用户快照到最新指数

#### `distributeBorrowerComp(address cToken, address borrower, Exp marketBorrowIndex)`
- **功能**：计算并累积借款人的 COMP 奖励
- **计算逻辑**：类似供应者，但基于借款余额

#### `claimComp(address holder)`
- **功能**：领取用户在所有市场的所有 COMP 奖励
- **流程**：
  1. 遍历所有市场
  2. 更新供应和借贷指数
  3. 计算用户奖励并转账

#### `claimComp(address holder, CToken[] cTokens)`
- **功能**：领取用户在指定市场的 COMP 奖励

#### `claimComp(address[] holders, CToken[] cTokens, bool borrowers, bool suppliers)`
- **功能**：批量领取 COMP，可选择只领取供应奖励或借贷奖励

#### `grantCompInternal(address user, uint amount)`
- **功能**：内部函数，实际转账 COMP 给用户
- **注意**：如果合约余额不足，不会部分转账

### 3.5 管理员函数

#### 市场管理
- `_supportMarket(CToken cToken)` - 上架新市场
- `_setCollateralFactor(CToken cToken, uint newCollateralFactorMantissa)` - 设置抵押因子
- `_setMarketBorrowCaps(CToken[] cTokens, uint[] newBorrowCaps)` - 设置借贷上限
- `_setBorrowCapGuardian(address newBorrowCapGuardian)` - 设置借贷上限监护人

#### 风险参数设置
- `_setCloseFactor(uint newCloseFactorMantissa)` - 设置清算因子（0.05 ~ 0.9）
- `_setLiquidationIncentive(uint newLiquidationIncentiveMantissa)` - 设置清算激励

#### 暂停机制
- `_setPauseGuardian(address newPauseGuardian)` - 设置暂停监护人
- `_setMintPaused(CToken cToken, bool state)` - 暂停/恢复市场铸造
- `_setBorrowPaused(CToken cToken, bool state)` - 暂停/恢复市场借贷
- `_setTransferPaused(bool state)` - 暂停/恢复全局转账
- `_setSeizePaused(bool state)` - 暂停/恢复全局扣押

#### COMP 奖励管理
- `_setCompSpeed(CToken cToken, uint compSpeed)` - 设置市场的 COMP 发放速度
- `_setContributorCompSpeed(address contributor, uint compSpeed)` - 设置贡献者的 COMP 发放速度
- `_grantComp(address recipient, uint amount)` - 直接授予 COMP（管理员功能）
- `_setPriceOracle(PriceOracle newOracle)` - 设置价格预言机

## 四：重要机制详解

### 4.1 市场准入机制

#### 为什么需要进入市场？
用户存入资产（mint）后，默认**不参与市场**（除非主动调用 `enterMarkets`）。只有参与市场后：
- 该资产才会被计入流动性计算
- 该资产才能作为其他借贷的抵押品

#### 何时自动加入市场？
- 当用户首次借款（borrow）时，系统自动将借款市场加入用户的资产列表
- 用户需要手动调用 `enterMarkets` 来将存款市场加入

#### 退出市场的条件
- 用户在 market 中**没有未偿还的借款余额**
- 退出后，账户流动性仍然健康（不会导致清算风险）

### 4.2 流动性计算机制

#### 流动性计算公式

**总抵押品价值（sumCollateral）**：
```
对于每个用户资产：
  collateralValue = cTokenBalance × exchangeRate × oraclePrice × collateralFactor
  sumCollateral += collateralValue
```

**总借贷价值（sumBorrowPlusEffects）**：
```
对于每个用户资产：
  borrowValue = borrowBalance × oraclePrice
  sumBorrowPlusEffects += borrowValue
```

**最终结果**：
- 如果 `sumCollateral > sumBorrowPlusEffects`：
  - `liquidity = sumCollateral - sumBorrowPlusEffects`
  - `shortfall = 0`
- 如果 `sumCollateral < sumBorrowPlusEffects`：
  - `liquidity = 0`
  - `shortfall = sumBorrowPlusEffects - sumCollateral`

#### 抵押因子（Collateral Factor）
- 范围：0 ~ 0.9（90%）
- 作用：决定抵押品价值的多少比例可以用来借贷
- 例如：如果抵押因子是 0.8，价值 1000 美元的 ETH 最多可以借 800 美元的其他资产

#### 假设操作计算
`getHypotheticalAccountLiquidity` 函数可以在用户实际执行操作前，预测操作后的流动性：
- 赎回影响：`sumBorrowPlusEffects += redeemTokens × tokensToDenom`
- 借贷影响：`sumBorrowPlusEffects += borrowAmount × oraclePrice`

### 4.3 清算机制

#### 清算触发条件
1. 账户流动性缺口 > 0（`shortfall > 0`）
2. 清算金额不超过最大清算金额（`repayAmount <= maxClose`）

#### 清算因子（Close Factor）
- 范围：0.05 ~ 0.9
- 含义：每次清算最多可以清算用户总借款的百分比
- 例如：如果用户借款 1000 USDC，closeFactor = 0.5，则最多可以清算 500 USDC

#### 清算激励（Liquidation Incentive）
- 含义：清算人除了偿还借款外，还能额外获得抵押品作为奖励
- 计算：清算人获得的抵押品价值 = 偿还金额 × liquidationIncentive × priceBorrowed / priceCollateral

#### 扣押数量计算
```
seizeTokens = actualRepayAmount × (liquidationIncentive × priceBorrowed) / (priceCollateral × exchangeRate)
```

**举例**：
- 用户借款：1000 USDC（借入资产）
- 抵押品：1 ETH（抵押资产）
- USDC 价格：1 USD
- ETH 价格：3000 USD
- 清算激励：1.08（8% 奖励）
- 兑换率：1 cETH = 0.02 ETH

如果清算人偿还 500 USDC：
```
seizeTokens = 500 × (1.08 × 1) / (3000 × 0.02)
           = 500 × 1.08 / 60
           = 9 cETH
```

清算人实际获得：9 × 0.02 × 3000 = 540 USD 价值的 ETH
偿还：500 USDC
净收益：40 USD（8% 奖励）

## 五：COMP 奖励分发机制详解

### 5.1 指数机制原理

COMP 奖励采用**累积指数机制**，这是一个高效的奖励分发系统，类似于复利计算。

#### 核心思想
1. **全局指数（Index）**：记录每个市场的历史累积奖励比率
2. **用户快照（Snapshot）**：记录用户上次领取时的全局指数
3. **奖励计算**：`用户奖励 = 持币数 × (当前指数 - 用户快照)`

#### 为什么使用指数机制？
- **高效**：不需要遍历所有用户，只需维护一个全局指数
- **精确**：按块更新，精确计算每个区块的奖励
- **公平**：按持有比例和时间自动分配奖励
- **按需计算**：只在用户操作或领取时才计算，不消耗额外 gas

### 5.2 供应指数更新流程

```
updateCompSupplyIndex(cToken)
    ↓
1. 计算经过的区块数：deltaBlocks = 当前区块 - 上次更新区块
    ↓
2. 计算总应发奖励：compAccrued = deltaBlocks × supplySpeed
    ↓
3. 获取当前市场总供应量：supplyTokens = cToken.totalSupply()
    ↓
4. 计算每个代币的比率：ratio = compAccrued / supplyTokens
    ↓
5. 更新全局指数：index = 旧index + ratio
    ↓
6. 保存新状态（index 和 blockNumber）
```

### 5.3 用户奖励计算流程

```
distributeSupplierComp(cToken, supplier)
    ↓
1. 获取当前全局指数：supplyIndex = compSupplyState[cToken].index
    ↓
2. 获取用户上次快照：supplierIndex = compSupplierIndex[cToken][supplier]
    ↓
3. 更新用户快照到最新：compSupplierIndex[cToken][supplier] = supplyIndex
    ↓
4. 计算指数增长：deltaIndex = supplyIndex - supplierIndex
    ↓
5. 获取用户持币数：supplierTokens = cToken.balanceOf(supplier)
    ↓
6. 计算用户奖励：supplierDelta = supplierTokens × deltaIndex
    ↓
7. 累加到总债权：compAccrued[supplier] += supplierDelta
```

### 5.4 奖励分发触发时机

COMP 奖励在以下操作时自动计算和累积（但不立即转账）：

1. **存款（Mint）**：更新供应指数，计算存款者奖励
2. **赎回（Redeem）**：更新供应指数，计算赎回者奖励
3. **转账（Transfer）**：更新供应指数，计算发送方和接收方奖励
4. **清算扣押（Seize）**：更新抵押品市场供应指数，计算借款人和清算人奖励

奖励**不会**在以下操作时计算：
- 借款（Borrow）
- 偿还借款（Repay Borrow）

**注意**：奖励只是累积到 `compAccrued[user]`，需要用户手动调用 `claimComp()` 才会转账。

### 5.5 奖励领取流程

```
claimComp(holder)
    ↓
遍历所有市场（allMarkets）
    ↓
对于每个市场：
    1. 更新供应指数：updateCompSupplyIndex(cToken)
    2. 计算用户奖励：distributeSupplierComp(cToken, holder)
    3. 更新借贷指数：updateCompBorrowIndex(cToken, borrowIndex)
    4. 计算用户奖励：distributeBorrowerComp(cToken, holder, borrowIndex)
    ↓
转账 COMP：grantCompInternal(holder, compAccrued[holder])
    ↓
清空用户累积：compAccrued[holder] = 0（转账后余额为 0）
```

### 5.6 实际场景举例

#### 场景设置
- 市场：cDAI
- 发放速度：100 COMP/秒（supplySpeed = 100）
- 初始指数：1e36
- 市场总供应量：10,000 cDAI

#### 时间线

**区块 #1000：初始状态**
- 全局指数：1e36
- 用户 A：存入 1000 cDAI，快照 = 1e36

**区块 #1100：第 1 次更新（经过 100 个区块）**
- 经过区块数：100
- 总应发奖励：100 × 100 = 10,000 COMP
- 每个代币比率：10,000 / 10,000 = 1.0
- 新全局指数：1e36 + 1.0 = 1e36 + 1.0

**区块 #1200：第 2 次更新（经过 100 个区块）**
- 此时市场总供应量变为：15,000 cDAI
- 总应发奖励：100 × 100 = 10,000 COMP
- 每个代币比率：10,000 / 15,000 = 0.6667
- 新全局指数：1e36 + 1.0 + 0.6667

**区块 #1250：用户 A 领取奖励**
- 当前全局指数：1e36 + 1.6667
- 用户 A 快照：1e36
- 指数增长：1.6667
- 用户 A 持币：1000 cDAI
- **用户 A 应得奖励**：1000 × 1.6667 = **1,666.7 COMP**

**区块 #1300：第 3 次更新（经过 100 个区块）**
- 市场总供应量：12,000 cDAI
- 总应发奖励：100 × 100 = 10,000 COMP
- 每个代币比率：10,000 / 12,000 = 0.8333
- 新全局指数：1e36 + 1.0 + 0.6667 + 0.8333 = 1e36 + 2.5

**区块 #1350：用户 A 再次领取奖励**
- 当前全局指数：1e36 + 2.5
- 用户 A 上次快照（第 1 次领取后）：1e36 + 1.6667
- 指数增长：2.5 - 1.6667 = 0.8333
- 用户 A 持币：1000 cDAI
- **用户 A 应得奖励**：1000 × 0.8333 = **833.3 COMP**（只计算第 2、3 次之间的奖励）

## 六：流动性与清算机制

### 6.1 流动性检查应用场景

1. **赎回前检查**：确保赎回后账户仍然健康
2. **借贷前检查**：确保借贷后账户有足够的流动性
3. **转账前检查**：确保发送方可以赎回这么多代币
4. **清算判断**：检查账户是否有流动性缺口

### 6.2 清算完整流程

#### 清算人视角
1. 监控账户：发现某个账户 `shortfall > 0`
2. 调用 `liquidateBorrowAllowed()` 检查是否可以清算
3. 调用 `liquidateCalculateSeizeTokens()` 计算可以获得多少抵押品
4. 调用 CToken 的 `liquidateBorrow()` 执行清算：
   - 偿还借款人的部分借款
   - 获得抵押品作为奖励

#### 系统处理
1. `liquidateBorrowAllowed()` 验证：
   - 账户有流动性缺口
   - 清算金额不超过 closeFactor
2. `liquidateBorrowVerify()` 验证：
   - 清算金额和扣押数量匹配
3. `seizeAllowed()` 验证：
   - 可以扣押抵押品
   - 分发 COMP 奖励

### 6.3 风险参数限制

- **closeFactorMantissa**：0.05e18 ~ 0.9e18（5% ~ 90%）
- **collateralFactorMantissa**：0 ~ 0.9e18（0% ~ 90%）
- **liquidationIncentiveMantissa**：通常 > 1e18（给清算人奖励）

### 6.4 借贷上限（Borrow Cap）

- 管理员可以为每个市场设置借贷上限
- 借贷上限为 0 表示无限制
- 当市场总借贷达到上限时，新的借贷请求会被拒绝
- 用于控制市场风险，防止过度借贷

## 七：安全机制

### 7.1 暂停机制
- **市场级别暂停**：可以暂停特定市场的铸造或借贷
- **全局暂停**：可以暂停所有转账或扣押操作
- **用途**：应对紧急情况，保护用户资产

### 7.2 权限控制
- **admin**：拥有最高权限，可以修改所有参数
- **pauseGuardian**：只能暂停，不能恢复（恢复需要 admin）
- **borrowCapGuardian**：只能设置借贷上限

### 7.3 跨协议攻击防护
- `seizeAllowed()` 中检查两个市场的 comptroller 必须相同
- 防止恶意合约跨协议扣押资产

### 7.4 COMP 奖励安全
- `grantCompInternal()` 检查合约余额，余额不足时不会部分转账
- 防止奖励分发耗尽合约资金

## 八：事件（Events）

### 8.1 市场事件
- `MarketListed(CToken cToken)` - 市场上架
- `MarketEntered(CToken cToken, address account)` - 用户加入市场
- `MarketExited(CToken cToken, address account)` - 用户退出市场

### 8.2 参数变更事件
- `NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa)`
- `NewCollateralFactor(CToken cToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa)`
- `NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa)`
- `NewPriceOracle(PriceOracle oldOracle, PriceOracle newOracle)`

### 8.3 COMP 奖励事件
- `CompSpeedUpdated(CToken indexed cToken, uint newSpeed)`
- `ContributorCompSpeedUpdated(address indexed contributor, uint newSpeed)`
- `DistributedSupplierComp(CToken indexed cToken, address indexed supplier, uint compDelta, uint compSupplyIndex)`
- `DistributedBorrowerComp(CToken indexed cToken, address indexed borrower, uint compDelta, uint compBorrowIndex)`
- `CompGranted(address recipient, uint amount)`

### 8.4 暂停事件
- `ActionPaused(string action, bool pauseState)` - 全局操作暂停
- `ActionPaused(CToken cToken, string action, bool pauseState)` - 市场操作暂停

## 九：常见问题

### 9.1 为什么存入资产后需要调用 `enterMarkets`？
存入资产（mint）后，默认不参与市场。只有调用 `enterMarkets` 后，该资产才会被计入流动性计算，才能作为其他借贷的抵押品。

### 9.2 COMP 奖励什么时候发放？
COMP 奖励会在用户操作时自动计算和累积，但不会立即转账。需要用户手动调用 `claimComp()` 才能领取。

### 9.3 可以只领取供应奖励或借贷奖励吗？
可以。使用 `claimComp(address[] holders, CToken[] cTokens, bool borrowers, bool suppliers)` 函数，可以通过 `borrowers` 和 `suppliers` 参数控制。

### 9.4 清算时如何计算扣押数量？
使用 `liquidateCalculateSeizeTokens()` 函数，考虑：
- 偿还金额
- 清算激励
- 借入资产和抵押资产的价格比率
- 抵押品的兑换率

### 9.5 为什么需要累积指数而不是只保存每次的比率？
如果只保存每次的比率，用户领取时需要遍历所有历史比率求和，效率低。使用累积指数，只需一次减法即可计算出所有历史奖励。

### 9.6 如何查询用户的 COMP 奖励余额？
查询 `compAccrued[user]` 映射，但这只包括已累积但未领取的奖励。用户需要调用 `claimComp()` 才能实际收到 COMP 代币。

---

**文档版本**：v1.0  
**最后更新**：基于 ComptrollerG7.sol 合约代码

