// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./InterestRateModel.sol";

/**
  * @title Compound 的 JumpRateModel 合约
  * @author Compound
  */
contract JumpRateModel is InterestRateModel {
    event NewInterestParams(uint baseRatePerBlock, uint multiplierPerBlock, uint jumpMultiplierPerBlock, uint kink);

    uint256 private constant BASE = 1e18;

    /**
     * @notice The approximate number of blocks per year that is assumed by the interest rate model
     */
    uint public constant blocksPerYear = 2102400;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    uint public multiplierPerBlock;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    uint public baseRatePerBlock;

    /**
     * @notice The multiplierPerBlock after hitting a specified utilization point
     */
    uint public jumpMultiplierPerBlock;

    /**
     * @notice The utilization point at which the jump multiplier is applied
     */
    uint public kink;

    /**
     * @notice Construct an interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by BASE)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by BASE)
     * @param jumpMultiplierPerYear The multiplierPerBlock after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) public {
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;

        emit NewInterestParams(baseRatePerBlock, multiplierPerBlock, jumpMultiplierPerBlock, kink);
    }

    /**
     * @notice 计算市场利用率：`借入/（现金+借入-准备金）`
     * @param cash 市场上的底层资产
     * @param Borrows 市场上借贷总额(含利息)
     * @param Reserves 市场上的储备金（当前未使用）
     * @return 利用率作为[0, BASE]之间的尾数
     */
    function utilizationRate(uint cash, uint borrows, uint reserves) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return borrows * BASE / (cash + borrows - reserves);
    }

    /**
     * @notice 计算当前每个区块的借贷利率，以及市场预期的错误代码
     * @param cash 市场上的底层资产
     * @param Borrows 市场上借贷总额(含利息)
     * @param Reserves 市场上的储备金
     * @return 每个区块的借入率百分比作为尾数（按 BASE 缩放）
     */
    function getBorrowRate(uint cash, uint borrows, uint reserves) override public view returns (uint) {
        // 获取资金使用率
        uint util = utilizationRate(cash, borrows, reserves);

        // 判断 资金使用率 与 临界点 大小,从而决定使用那个公式
        if (util <= kink) {
            // 资金使用率 < 临界值: 借贷利率缓慢增长
            return (util * multiplierPerBlock / BASE) + baseRatePerBlock;
        } else {
            // 资金使用率 > 临界值: 借贷利率快速增长
            uint normalRate = (kink * multiplierPerBlock / BASE) + baseRatePerBlock;
            uint excessUtil = util - kink;
            return (excessUtil * jumpMultiplierPerBlock/ BASE) + normalRate;
        }
    }

    /**
     * @notice Calculates the current supply rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per block as a mantissa (scaled by BASE)
     */
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) override public view returns (uint) {
        uint oneMinusReserveFactor = BASE - reserveFactorMantissa;
        uint borrowRate = getBorrowRate(cash, borrows, reserves);
        uint rateToPool = borrowRate * oneMinusReserveFactor / BASE;
        return utilizationRate(cash, borrows, reserves) * rateToPool / BASE;
    }
}
