
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol"; // TODO 

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
// import {HookFee} from "../src/examples/HookFee.sol";

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IUniswapV3Pool} from "../src/imports/V3/IUniswapV3Pool.sol";
import {ISwapRouter} from "../src/imports/V3/ISwapRouter.sol";
// import {IV3SwapRouter as ISwapRouter} from "../src/imports/V3/IV3SwapRouter.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";


import {Fixtures} from "./utils/Fixtures.sol";

import {MO} from "../src/Router.sol";
import {Good} from "../src/GD.sol";

contract RouterTest is Test, Fixtures {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint public constant WAD = 1e18;
    uint public constant USDC_PRECISION = 1e6;

    address public User01 = address(0x1);
    address public User02 = address(0x2);

    ISwapRouter public V3router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool public V3pool = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IERC20 public pxETH = IERC20(0x04C154b66CB340F3Ae24111CC767e0184Ed00Cc6); 
    
    address public aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public pirexETH = 0xD664b74274DfEB538d9baC494F3a4760828B02b0;
    // (deposit ETH -> receive pxETH, instantRedeem pxETH -> receive ETH)
    address public rexVault = 0x9Ba021B0a9b958B5E75cE9f6dff97C7eE52cb3E6;
    // stake pxETH in ^^^^^ to auto-compound the ethereal staking yield

    address[] public STABLECOINS;
    IERC20 public GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20 public USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    IERC20 public USDE = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IERC20 public CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public FRAX = IERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    
    address[] public VAULTS;
    IERC4626 public smokehouseUSDCvault = IERC4626(0xBEeFFF209270748ddd194831b3fa287a5386f5bC);
    IERC4626 public smokehouseUSDTvault = IERC4626(0xA0804346780b4c2e3bE118ac957D1DB82F9d7484);
    
    // unlike other vaults, SGHO has special interface (similar to ERC4626)
    IERC20 public SGHO = IERC20(0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d);
    IERC4626 public SDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    IERC4626 public SFRAX = IERC4626(0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32);
    IERC4626 public SUSDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC4626 public SUSDE = IERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    IERC4626 public SCRVUSD = IERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);    

    Good public quid; MO public V4router;
    function setUp() public {
        STABLECOINS = [
            address(USDC), address(USDT),
            address(DAI), address(USDS), 
            address(FRAX), address(USDE), 
            address(CRVUSD), address(GHO)
        ]; // ordering is very important!
        VAULTS = [
            address(smokehouseUSDCvault), 
            address(smokehouseUSDTvault),
            address(SDAI), address(SUSDS), 
            address(SFRAX), address(SUSDE), 
            address(SCRVUSD), address(SGHO)
        ];
        uint mainnetFork = vm.createFork(
            "https://ethereum-rpc.publicnode.com",
            22095900); vm.selectFork(mainnetFork);
        
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager); 
        vm.deal(address(this), 10000 ether);
        vm.deal(User01, 10000 ether);
        V4router = new MO(manager, 
        address(V3pool), 
        address(V3router),
        pirexETH, address(pxETH), 
        rexVault, aavePool); 
        quid = new Good(
            address(V4router), 
            STABLECOINS, VAULTS
        );
        vm.startPrank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
        USDC.transfer(address(this), 1 * USDC_PRECISION);
        USDC.transfer(User01, 1000000 * USDC_PRECISION); 
        vm.stopPrank();
        // the following transfer is necessary for setQuid()
        USDC.transfer(address(V4router), 1 * USDC_PRECISION);
        V4router.setQuid{value: 1 wei}(address(quid));
    }
 
    function testSwap() public {     
        uint stack = 10000 * USDC_PRECISION;
        uint USDCfee = 3 * USDC_PRECISION; // incl slippage
        uint ETHfee = 6 * 1e15; // incl Dinero fee + ^^^^^ 
        
        vm.startPrank(User01);
        USDC.approve(address(quid), 5 * stack);
        quid.mint(User01, 5 * stack, address(USDC), 0);
        
        V4router.deposit{value: 25 ether}();       
    
        uint price = V4router.getPrice(0, false);
        uint expectingToBuy = price / 1e12;
        uint USDCbalanceBefore = USDC.balanceOf(User01);

        V4router.swap{value: 1 ether}(address(USDC), false, 0);

        uint USDCbalanceAfter = USDC.balanceOf(User01);
        assertApproxEqAbs(USDCbalanceAfter - USDCbalanceBefore, 
                                expectingToBuy, USDCfee);
        
        price = V4router.getPrice(1, false);  
        uint balanceBefore = User01.balance;
        // note, we're not approving the router!
        USDC.approve(address(quid), price / 1e12); 
        // but GD, because quid does transferFrom

        V4router.swap(address(USDC), true, price / 1e12);

        uint balanceAfter = User01.balance;
        assertApproxEqAbs(balanceAfter - balanceBefore, 1 ether, ETHfee);

        USDCbalanceBefore = USDC.balanceOf(User01);
        
        V4router.swap{value: 100 ether}(address(USDC), false, 0);
        
        expectingToBuy = 100 ether * price / 1e30;

        USDCbalanceAfter = USDC.balanceOf(User01);

        assertApproxEqAbs(USDCbalanceAfter - USDCbalanceBefore, 
                            expectingToBuy, USDCfee * 100); 
                            // amount is 100x, so fee is too
        
        vm.stopPrank();
    }

    function testLeveragedSwapZeroForOne() public {

    }

    function testLeveragedSwapOneForZero() public {

    }

    function testOutOfRange() public {
        
    }
}
