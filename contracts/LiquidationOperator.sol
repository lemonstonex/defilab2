//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function getUserReserveData(address asset, address user) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);


    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    
    function transfer(address to, uint256 value) external returns (bool);
}


interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}


interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}


interface IUniswapV2Factory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface IUniswapV2Pair {
   function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */

    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IUniswapV2Factory constant uniswapV2Factory =
        IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Pair immutable uniswapV2Pair_WETH_USDT; // Pool1
    IUniswapV2Pair immutable uniswapV2Pair_WBTC_WETH; // Pool2
    IUniswapV2Pair immutable uniswapV2Pair_WBTC_USDT; // Pool3
    IUniswapV2Pair immutable uniswapV2Pair_WETH_USDC; // Pool4
    IUniswapV2Pair immutable uniswapV2Pair_USDC_WETH; // Pool5

    ILendingPool constant lendingPool =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // address constant liquidationTarget =
    //     // 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    address constant liquidationTarget =
        0x63f6037d3e9d51ad865056BF7792029803b6eEfD; //Q3
    uint debt_USDT;

    // END TODO

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract

        uniswapV2Pair_WETH_USDT = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(WETH), address(USDT))
        ); // Pool1
        uniswapV2Pair_WBTC_WETH = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(WBTC), address(WETH))
        ); // Pool2
        uniswapV2Pair_WBTC_USDT = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(WBTC), address(USDT))
        ); // Pool3
        uniswapV2Pair_WETH_USDC = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(WETH), address(USDC))
        ); // Pool4
        uniswapV2Pair_USDC_WETH = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(USDC), address(WETH))
        ); // Pool5

        // debt_USDT = 2916378221684; //2916378.221684
        debt_USDT = 8_128_956343;

        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH

    receive() external payable {}

    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        uint256 totalCollateralETH;
        uint256 totalDebtETH;
        uint256 availableBorrowsETH;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
        (
            totalCollateralETH,
            totalDebtETH,
            availableBorrowsETH,
            currentLiquidationThreshold,
            ltv,
            healthFactor
        ) = lendingPool.getUserAccountData(liquidationTarget);

        require(
            healthFactor < (10 ** health_factor_decimals),
            "Cannot liquidate; health factor must be below 1"
        );

        uniswapV2Pair_WETH_USDC.swap(debt_USDT, 0, address(this), "$");

        uint balance = WETH.balanceOf(address(this));
        WETH.withdraw(balance);
        payable(msg.sender).transfer(address(this).balance);

        // END TODO
    }
    function uniswapV2Call(
        address,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        assert(msg.sender == address(uniswapV2Pair_WETH_USDC));

        (
            uint256 reserve_USDC_Pool4,
            uint256 reserve_WETH_Pool4,

        ) = uniswapV2Pair_WETH_USDC.getReserves(); 
    
        console.log("USDC Balance: %s", USDC.balanceOf(address(this)));
        console.log("BEFORE : WETH Balance : %s", WETH.balanceOf(address(this)));

        uint debtToCover = amount0;
        USDC.approve(address(lendingPool), debtToCover);
        lendingPool.liquidationCall(
            address(WETH),
            address(USDC),
            liquidationTarget,
            debtToCover,
            false
        );

        console.log("AFTER : WETH Balance : %s", WETH.balanceOf(address(this)));
        uint repay_WETH = getAmountIn(
            debtToCover,
            reserve_WETH_Pool4,
            reserve_USDC_Pool4
        );
        WETH.transfer(address(uniswapV2Pair_WETH_USDC), repay_WETH);
        console.log("WETH Balance After Repay: %s", WETH.balanceOf(address(this)));

        // END TODO
    }
}

