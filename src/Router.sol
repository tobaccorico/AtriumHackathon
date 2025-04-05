
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Basket} from "./Basket.sol";
import {Auxiliary} from "./Auxiliary.sol";
import {mockToken} from "./mockToken.sol";

import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract Router is SafeCallback, Ownable {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;


    PoolKey public VANILLA;
    mockToken private mockETH; 
    mockToken private mockUSD;
    Basket QUID; Auxiliary AUX;

    enum Action { Swap,
        Repack, ModLP,
        OutsideRange
    } // from AUX
    
    uint public POOLED_USD;
    // ^ currently "in-range"
    uint public POOLED_ETH;
    // these define "in-range"
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for:
    uint public USD_FEES;
    uint public ETH_FEES;
    uint public YIELD; // TODO:
    // use ring buffer to average
    // out the yield over a week
    
    uint constant WAD = 1e18;

    bytes internal constant ZERO_BYTES = bytes("");
    constructor(IPoolManager _manager) 
        SafeCallback(_manager) 
        Ownable(msg.sender) {}

    modifier onlyAux {
        require(msg.sender == address(AUX), "403"); _;
    }
    
    // must send $1 USDC to address(this) & attach msg.value 1 wei
    function setup(address _quid, address _aux, address _pool) external payable onlyOwner {
        // these virtual balances represent assets inside the curve
        mockToken temporaryToken = new mockToken(address(this), 18);
        mockToken tokenTemporary = new mockToken(address(this), 6);
        if (address(temporaryToken) > address(tokenTemporary)) {
            mockETH = temporaryToken; mockUSD = tokenTemporary;
        } else { 
            mockETH = tokenTemporary; mockUSD = temporaryToken;
        }
        require(mockUSD.decimals() == 6, "1e6");
        require(address(QUID) == address(0), "QUID");
        QUID = Basket(_quid); VANILLA = PoolKey({
            currency0: Currency.wrap(address(mockUSD)),
            currency1: Currency.wrap(address(mockETH)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))
        }); 
        renounceOwnership(); require(QUID.V4() == address(this), "!");
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(_pool).slot0();
        poolManager.initialize(VANILLA, sqrtPriceX96);
        
        AUX = Auxiliary(payable(_aux));
        mockUSD.approve(address(poolManager),
                        type(uint256).max);
        mockETH.approve(address(poolManager),
                        type(uint256).max);
    }

    function outOfRange(address sender, int liquidity, int24 tickLower, 
        int24 tickUpper) public onlyAux returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, sender, liquidity,
            tickLower, tickUpper)), (BalanceDelta));
    }

    function modLP(uint160 sqrtPriceX96, uint delta1, 
        uint delta0, int24 tickLower, int24 tickUpper) 
        public onlyAux returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(
            abi.encode(Action.ModLP, sqrtPriceX96, delta1,
            delta0, tickLower, tickUpper)), (BalanceDelta));
    }
    
    function swap(address sender, bool zeroForOne, uint160 sqrtPriceX96, 
        uint amount, address token) public onlyAux returns (BalanceDelta delta) {
            delta = abi.decode(poolManager.unlock(abi.encode(Action.Swap, 
            sqrtPriceX96, sender, zeroForOne, amount, token)), (BalanceDelta));
    }

    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte; BalanceDelta delta;
        address who = address(this); assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminant = Action(firstByte);
        address out = address(QUID);
        bool inRange = true; bool keep;
        if (discriminant == Action.Swap) {
            (uint160 sqrtPriceX96, address sender, 
            bool zeroForOne, uint amount, address token) = abi.decode(
                    data[32:], (uint160, address, bool, uint, address));
            delta = poolManager.swap(VANILLA, IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int(amount),
                sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                    !zeroForOne, 500) }), ZERO_BYTES); 
                    who = sender; out = token;
        } 
        else if (discriminant == Action.Repack) {
            (uint128 myLiquidity, uint160 sqrtPriceX96,
            int24 tickLower, int24 tickUpper) = abi.decode(
                data[32:], (uint128, uint160, int24, int24));
                uint price = AUX.getPrice(sqrtPriceX96, false);

            BalanceDelta fees; POOLED_ETH = 0; POOLED_USD = 0;
            (delta, // helper resets ^^^^^^^^^^^^^^^^^^^^^^^^
             fees) = _modifyLiquidity(
                -int(uint(myLiquidity)),
                 tickLower, tickUpper);

            uint delta0 = uint(int(delta.amount0()));
            uint delta1 = uint(int(delta.amount1()));
            VANILLA.currency0.take(poolManager,
                    address(this), delta0, false);
                    mockUSD.burn(delta0);
            VANILLA.currency1.take(poolManager,
                    address(this), delta1, false);
                    mockETH.burn(delta1);
            
            if (LAST_REPACK > 0) { // extrapolate (guestimate) an annual % yield... 
                // based on the % fee yield of the last period (in between repacks)
                YIELD = FullMath.mulDiv(365 days / (block.timestamp - LAST_REPACK),
                    uint(int(fees.amount0())) * 1e12 + FullMath.mulDiv(price, 
                    uint(int(fees.amount1())), WAD), // < total fees in $
                    delta0 * 1e12 + FullMath.mulDiv(price, delta1, WAD));
            }
            USD_FEES += uint(int(fees.amount1()));
            ETH_FEES += uint(int(fees.amount0()));
            LAST_REPACK = block.timestamp;
            
            (tickLower,, 
             tickUpper,) = updateTicks(sqrtPriceX96, 200);
            UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            (delta0, delta1) = AUX.addLiquidityHelper(
                                     0, delta1, price);

            delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96);
        } 
        else if (discriminant == Action.OutsideRange) {
            (address sender, int liquidity, 
            int24 tickLower, int24 tickUpper) = abi.decode(
                    data[32:], (address, int, int24, int24));

            who = sender; inRange = false;
            (delta, ) = _modifyLiquidity(liquidity,
                            tickLower, tickUpper);
        }
        else if (discriminant == Action.ModLP) {
            (uint160 sqrtPriceX96, uint delta1, uint delta0,
            int24 tickLower, int24 tickUpper) = abi.decode(
                data[32:], (uint160, uint, uint, int24, int24));

            keep = delta0 > 0;
            delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96);
        }
        if (delta.amount0() > 0) {
            uint delta0 = uint(int(delta.amount0()));
            VANILLA.currency0.take(poolManager,
                address(this), delta0, false);
                         mockUSD.burn(delta0);
            if (inRange) POOLED_USD -= delta0;
            if (!keep) {
                uint scale = IERC20(out).decimals() - 6;
                delta0 *= scale > 0 ? (10 ** scale) : 1;
                require(stdMath.delta(delta0, QUID.take(
                                who, delta0, out)) <= 5);
            }
        }
        else if (delta.amount0() < 0) {
            uint delta0 = uint(int(-delta.amount0())); mockUSD.mint(delta0);
            VANILLA.currency0.settle(poolManager, address(this), delta0, false);
            if (inRange) POOLED_USD += delta0;
        }
        if (delta.amount1() > 0) { uint delta1 = uint(int(delta.amount1()));
            VANILLA.currency1.take(poolManager, address(this), delta1, false);
            mockETH.burn(delta1); AUX.sendETH(delta1, who);
            if (inRange) POOLED_ETH -= delta1;
        }
        else if (delta.amount1() < 0) {
            uint delta1 = uint(int(-delta.amount1())); mockETH.mint(delta1);
            VANILLA.currency1.settle(poolManager, address(this), delta1, false);
            if (inRange) POOLED_ETH += delta1;
        }
        return abi.encode(delta);
    }


    function _modifyLiquidity(int delta, // liquidity delta
        int24 lowerTick, int24 upperTick) internal returns 
        (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            VANILLA, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }
    
    function _modLP(uint deltaZero, uint deltaOne, int24 tickLower,
        int24 tickUpper, uint160 sqrtPriceX96) internal returns
        (BalanceDelta) {  int flip = deltaOne > 0 ? int(1) : int(-1);
        (BalanceDelta totalDelta,
         BalanceDelta feesAccrued) = _modifyLiquidity(flip * int(uint(
               _calculateLiquidity(tickLower, sqrtPriceX96, deltaOne))),
                                   tickLower, tickUpper);
        return totalDelta;
    }

    function _calculateLiquidity(int24 tickLower, uint160 sqrtPriceX96, 
        uint delta) internal pure returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, delta);
    }

    function _alignTick(int24 tick)
        internal pure returns (int24) {
        if (tick < 0 && tick % 10 != 0) {
            return ((tick - 10 + 1) / 10) * 10;
        }   return (tick / 10) * 10;
    }

    function updateTicks(uint160 sqrtPriceX96, uint delta) public pure returns
        (int24 tickLower, uint160 lower, int24 tickUpper, uint160 upper) {
        lower = _paddedSqrtPrice(sqrtPriceX96, false, delta);
        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minSqrtPrice");
        tickLower = _alignTick(TickMath.getTickAtSqrtPrice(lower));
        upper = _paddedSqrtPrice(sqrtPriceX96, true, delta);
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxSqrtPrice");
        tickUpper = _alignTick(TickMath.getTickAtSqrtPrice(upper));
    }

    function _paddedSqrtPrice(uint160 sqrtPriceX96, 
        bool up, uint delta) internal pure returns (uint160) { 
        uint x = up ? FixedPointMathLib.sqrt(1e18 + delta * 1e14):
                      FixedPointMathLib.sqrt(1e18 - delta * 1e14);
        return uint160(FixedPointMathLib.mulDivDown(x, uint(sqrtPriceX96),
                       FixedPointMathLib.sqrt(1e18)));
    }

    function repack() public onlyAux returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) { 
        int24 currentTick; PoolId id = VANILLA.toId();
        myLiquidity = poolManager.getLiquidity(id);
        (sqrtPriceX96, currentTick,,) = poolManager.getSlot0(id);
            tickUpper = UPPER_TICK;     tickLower = LOWER_TICK;
        if (currentTick > tickUpper || currentTick < tickLower) {
            if (myLiquidity > 0) { // remove, then add liquidity
                poolManager.unlock(abi.encode(Action.Repack,
                                  myLiquidity, sqrtPriceX96, 
                                    tickLower, tickUpper));
            } else {
                (tickLower,, 
                tickUpper,) = updateTicks(sqrtPriceX96, 200);
                // 1% delta up, 1% down from ^^^^^^^^^^ total 2
                UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            }            
        }
    }
}
