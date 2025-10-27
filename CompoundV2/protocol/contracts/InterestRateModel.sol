// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

/**
  * @title 复合的利率模型接口
  * @author Compound
  */
abstract contract InterestRateModel {
    /// @notice Indicator that this is an InterestRateModel contract (for inspection)
    bool public constant isInterestRateModel = true;

    /**
      * @notice 计算当前每个区块的借入利率
      * @param cash 市场拥有的现金总量
      * @param borrows 市场借款总额(含利息)
      * @param reserves 市场储备金
      * @return 每个区块的借贷利率 (以百分比表示，并按 1e18 缩放)
      */
    function getBorrowRate(uint cash, uint borrows, uint reserves) virtual external view returns (uint);

    /**
      * @notice Calculates the current supply interest rate per block
      * @param cash The total amount of cash the market has
      * @param borrows The total amount of borrows the market has outstanding
      * @param reserves The total amount of reserves the market has
      * @param reserveFactorMantissa The current reserve factor the market has
      * @return The supply rate per block (as a percentage, and scaled by 1e18)
      */
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) virtual external view returns (uint);
}
