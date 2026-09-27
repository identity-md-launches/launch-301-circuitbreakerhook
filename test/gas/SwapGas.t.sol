// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasFixture} from "./GasFixture.sol";

abstract contract GasSwapRunner is GasFixture {
    function runMeasurement(bool withHook, bool buy, bool exactOut) external {
        measureSwap(withHook, buy, exactOut);
    }
}

contract GasSwapFirstEverTest is GasSwapRunner {
    function setUp() public {
        setupPools(false, false);
    }

    function test_gas_swap_hook_buy_exactIn() public {
        this.runMeasurement(true, true, false);
    }

    function test_gas_swap_noHook_buy_exactIn() public {
        this.runMeasurement(false, true, false);
    }

    function test_gas_swap_hook_buy_exactOut() public {
        this.runMeasurement(true, true, true);
    }

    function test_gas_swap_noHook_buy_exactOut() public {
        this.runMeasurement(false, true, true);
    }
}

abstract contract GasSwapMatrix is GasSwapRunner {
    function test_gas_swap_hook_buy_exactIn() public {
        this.runMeasurement(true, true, false);
    }

    function test_gas_swap_noHook_buy_exactIn() public {
        this.runMeasurement(false, true, false);
    }

    function test_gas_swap_hook_buy_exactOut() public {
        this.runMeasurement(true, true, true);
    }

    function test_gas_swap_noHook_buy_exactOut() public {
        this.runMeasurement(false, true, true);
    }

    function test_gas_swap_hook_sell_exactIn() public {
        this.runMeasurement(true, false, false);
    }

    function test_gas_swap_noHook_sell_exactIn() public {
        this.runMeasurement(false, false, false);
    }

    function test_gas_swap_hook_sell_exactOut() public {
        this.runMeasurement(true, false, true);
    }

    function test_gas_swap_noHook_sell_exactOut() public {
        this.runMeasurement(false, false, true);
    }
}

contract GasSwapFirstInBlockTest is GasSwapMatrix {
    function setUp() public {
        setupPools(true, true);
    }
}

contract GasSwapLaterInBlockTest is GasSwapMatrix {
    function setUp() public {
        setupPools(true, false);
    }
}
