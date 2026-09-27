// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// @notice The launch parameters the rehearsal mirrors. They are assumptions about what the factory will
/// do and are documented in README.md ("Deployment parameters"); change them there and here together.
library LaunchParams {
    /// @notice Pool fee, 0.30%. A static fee: the hook never overrides it.
    uint24 internal constant FEE = 3000;

    /// @notice Tick spacing that goes with the 0.30% tier.
    int24 internal constant TICK_SPACING = 60;

    /// @notice The tick the pool opens at. Price is CBRK per ETH (currency1 per currency0):
    /// 1.0001^152040 is about 4,005,700 CBRK per ETH, so the whole 1e9 supply is worth about 250 ETH.
    /// Aligned to the tick spacing so a position may end exactly here.
    int24 internal constant INITIAL_TICK = 152_040;

    /// @notice Lower end of the one-sided seed range: 60,000 ticks below the opening tick, about 9,900
    /// CBRK per ETH, i.e. CBRK can appreciate roughly 400x before buys run out of seeded liquidity.
    int24 internal constant SEED_TICK_LOWER = INITIAL_TICK - 60 * 1000;

    /// @notice CBRK committed to the seed position: half the supply.
    uint256 internal constant SEED_AMOUNT = 500_000_000 ether;

    function initialSqrtPriceX96() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(INITIAL_TICK);
    }

    /// @notice The liquidity `SEED_AMOUNT` of CBRK buys in [SEED_TICK_LOWER, INITIAL_TICK] when the pool
    /// price sits at the top of the range. Rounded down so the pool never asks for more than the seed.
    function seedLiquidity() internal pure returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(SEED_TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        uint256 liquidity = FullMath.mulDiv(SEED_AMOUNT, FixedPoint96.Q96, sqrtUpper - sqrtLower);
        return uint128(liquidity);
    }
}
