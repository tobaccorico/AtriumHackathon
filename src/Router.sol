
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Good} from "./GD.sol";
import {mockToken} from "./mockToken.sol";

import {IPirexETH} from "./imports/IPirexETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {IUniswapV3Pool} from "./imports/V3/IUniswapV3Pool.sol";
import {ISwapRouter} from "./imports/V3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/IV3SwapRouter.sol"; // base

import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract MO is SafeCallback, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint internal _ETH_PRICE; // TODO remove

    PoolKey vanillaKey; IUniswapV3Pool v3Pool;
    bool internal token1isWETH; // ^
    // for our v4 pool ETH is token1
    ISwapRouter v3Router; // fallback
    
    IERC20 pxETH; IERC4626 rexVault;
    IPirexETH rex; Good GD; // basket
    IERC20 USDC; WETH weth; IPool aave;
    mockToken mockETH; mockToken mockUSD;
    mapping(address => uint[]) positions;
    mapping(uint => SelfManaged) selfManaged;
    struct SelfManaged {
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }
    struct viaAAVE {
        uint supplied;
        uint borrowed;
        uint buffer;
        int price;
    }
    mapping(address => viaAAVE) pledgesOneForZero;
    mapping(address => viaAAVE) pledgesZeroForOne;
    mapping(address => uint) autoManaged; 
    // ^ price range handled by contract
    
    uint internal PENDING_ETH;
    // ^ single-sided liqudity
    // that is waiting for $
    // before it's deposited:
    uint internal POOLED_USD;
    // ^ currently "in-range"
    uint internal POOLED_ETH;
    // these define "in-range"
    int24 internal UPPER_TICK;
    int24 internal LOWER_TICK;    
    uint internal LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for:
    uint internal USD_FEES;
    uint internal ETH_FEES;
    uint internal YIELD; // TODO:
    // use ring buffer to average
    // out the yield over a week

    // _unlockCallback    
    enum Action { Swap, 
        Repack, ModLP, 
        OutsideRange
    } uint internal tokenId;
    // ^ always incrementing
    uint constant WAD = 1e18;

    bytes internal constant ZERO_BYTES = bytes("");
    constructor(IPoolManager _manager, address _v3pool,
        address _v3router, address _piREX, address _pxETH, 
        address _rexVault, address _aave) SafeCallback(_manager) 
            Ownable(msg.sender) { v3Pool = IUniswapV3Pool(_v3pool); 
                                  v3Router = ISwapRouter(_v3router);
            
            rexVault = IERC4626(_rexVault);
            rex = IPirexETH(_piREX); 
            pxETH = IERC20(_pxETH); 
            
            address token0 = v3Pool.token0();
            address token1 = v3Pool.token1();    

            if (IERC20(token1).decimals() > 
                IERC20(token0).decimals()) {
                weth = WETH(payable(token1));
                USDC = IERC20(token0); 
                token1isWETH = true; 
            } else {
                token1isWETH = false;
                weth = WETH(payable(token0));
                USDC = IERC20(token1);
            }   aave = IPool(_aave);
    }

    modifier isInitialised {
        require(address(GD) != address(0), "init"); _;
    }

    modifier onlyQuid {
        require(msg.sender == address(GD), "403"); _;
    }

    // must send $1 USDC to address(this) & attach msg.value 1 wei
    function setQuid(address _quid) external payable onlyOwner {
        // these virtual balances represent assets inside the curve
        mockToken temporaryToken = new mockToken(address(this), 18);
        mockToken tokenTemporary = new mockToken(address(this), 6);
        if (address(temporaryToken) > address(tokenTemporary)) {
            mockETH = temporaryToken; mockUSD = tokenTemporary;
        } else { 
            mockETH = tokenTemporary; mockUSD = temporaryToken;
        }
        require(mockUSD.decimals() == 6, "1e6");
        require(address(GD) == address(0), "GD"); 
        GD = Good(_quid); vanillaKey = PoolKey({
            currency0: Currency.wrap(address(mockUSD)),
            currency1: Currency.wrap(address(mockETH)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))
        }); renounceOwnership();    

        require(GD.Mindwill() == address(this), "!");
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        poolManager.initialize(vanillaKey, sqrtPriceX96);
        USDC.approve(address(GD), type(uint256).max);
        // ^ just for calling GD.deposit in unwind()

        mockUSD.approve(address(poolManager),
                        type(uint256).max);
        USDC.approve(address(v3Router),
                    type(uint256).max);
        mockETH.approve(address(poolManager), 
                        type(uint256).max);
        weth.approve(address(v3Router), 
                    type(uint256).max);
        // ^ max approvals considered safe
        // to make as we fully control code
        weth.approve(address(aave), 1 wei);
        weth.deposit{ value: 1 wei }();
        aave.supply(address(weth),
             1 wei, address(this), 0);
        aave.setUserUseReserveAsCollateral(
                        address(weth), true);

        USDC.approve(address(aave), 1e6);
        aave.supply(address(USDC),
           1000000, address(this), 0);
        aave.setUserUseReserveAsCollateral(
                        address(USDC), true);
    }

    // the protocol is net long, keeping 1ETH on deposit,
    // while levering dollar value of 1ETH to go short:
    // borrowing 70% on AAVE, then selling that for USDC
    function leverZeroForOne() public
        payable isInitialised {
        uint borrowing = msg.value * 7 / 10;
        uint buffer = msg.value - borrowing;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);
        uint totalValue = FullMath.mulDiv(msg.value,
                                         price, WAD);
        require(totalValue > 50 * WAD, "grant");
        totalValue /= 1e12; // 1e6 precision
        uint took = GD.take(address(this),
                totalValue, address(USDC));

        require(stdMath.delta(totalValue, took) <= 5, "0for1$");
        totalValue = took; USDC.approve(address(aave), totalValue);

        aave.supply(address(USDC), totalValue, address(this), 0);
        aave.borrow(address(weth), borrowing, 2, 0, address(this));

        uint amount = FullMath.mulDiv(borrowing, price, 1e12 * WAD);
        amount = v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(weth), uint24(500), address(USDC)),
            address(this), block.timestamp, borrowing, amount - amount / 200));
            require(amount == GD.deposit(address(this), address(USDC), amount));

        uint withProfit = totalValue + totalValue / 30;
        GD.mint(msg.sender, withProfit, address(GD), 0);
        pledgesZeroForOne[msg.sender] = viaAAVE({
            supplied: totalValue, borrowed: borrowing,
            buffer: buffer, price: int(price) });
    }

    function leverOneForZero(uint amount,
        address token) isInitialised external {
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);

        amount = GD.deposit(msg.sender, token, amount);
        uint withProfit = amount + amount / 30;

        uint inETH = FullMath.mulDiv(WAD,
                amount * 1e12, price);

        inETH = unRex(inETH);
        weth.deposit{value: inETH}(); 
        weth.approve(address(aave), inETH);

        aave.supply(address(weth), inETH, address(this), 0);
        amount = FullMath.mulDiv(inETH * 7 / 10, price, WAD * 1e12);
        aave.borrow(address(USDC), amount, 2, 0, address(this));
        
        require(amount == GD.deposit(address(this),
                address(USDC), amount));

        GD.mint(msg.sender, withProfit, address(GD), 0);
        pledgesOneForZero[msg.sender] = viaAAVE({ 
            supplied: inETH, borrowed: amount,
            buffer: 0, price: int(price) });
    }
    
    function outOfRange(uint amount, address token,
        uint price, uint range) isInitialised
        public payable { require(range > 100
            && range < 5000 && range % 50 == 0, "width");
        (,int24 lowerTick, int24 upperTick,) = _repack();
        uint160 sqrtPriceX96 = getSqrtPriceX96(price);
        
         int liquidity; bool isStable;
        (int24 tickLower, uint160 lower,
         int24 tickUpper, uint160 upper) = _updateTicks(
                                    sqrtPriceX96, range);
        if (token == address(0)) {
            require(tickLower > upperTick, "right");
            (amount, ) = rex.deposit{value: msg.value}
                            (address(this), true);
            
            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96, lower, upper, amount, 0
                )));
        } else { 
            require(lowerTick > tickUpper, "left");
            amount = GD.deposit(msg.sender,
                            token, amount);
            isStable = true;
            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96, lower, upper, 0, amount
                )));
        }
        SelfManaged memory newPosition = SelfManaged({
            owner: msg.sender, lower: tickLower, 
            upper: tickUpper, liq: liquidity
        });
        uint next = tokenId + 1;
        selfManaged[next] = newPosition;
        positions[msg.sender].push(next);
        tokenId = next;
        
        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(
                Action.OutsideRange, liquidity, 
                tickLower, tickUpper)), (BalanceDelta));

        /* require(-delta.amount0() == int(amount) || (isStable &&
                -delta.amount1() == int(amount)), "re-arrange"); */
    }

    function reclaim(uint id, int percent) 
        isInitialised external returns (BalanceDelta delta) {
        SelfManaged memory position = selfManaged[id];
        
        require(position.owner == msg.sender, "403");
        require(percent > 0 && percent < 101, "%");
        
        int liquidity = position.liq * percent / 100;
        uint[] storage myIds = positions[msg.sender];
        
        delta = abi.decode(poolManager.unlock(
                abi.encode(Action.OutsideRange,
                msg.sender, -liquidity, position.lower, 
                position.upper)), (BalanceDelta));
                uint lastIndex = myIds.length - 1;
                
        if (percent == 100) { delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) { 
                    if (i < lastIndex) {
                        myIds[i] = myIds[lastIndex];
                    }
                    myIds.pop(); break;
                }
            }
        } else {
            position.liq -= liquidity;
            selfManaged[id] = position;
        } // TODO unRex
    }

    function deposit() isInitialised external payable {
        (uint amount, ) = rex.deposit{value: msg.value}(address(this), true);
        autoManaged[msg.sender] = amount; _addLiquidity(POOLED_USD, amount);
    }

    function _addLiquidity(
        uint delta0, uint delta1) 
        internal { (uint160 sqrtPriceX96, 
        int24 tickLower, int24 tickUpper,) = _repack();
        uint price = getPrice(sqrtPriceX96, false);
        (delta0, delta1) = _addLiquidityHelper(delta0, delta1, price);
        if (delta0 > 0) { require(delta1 > 0, "_addLiquidity");
            BalanceDelta delta = abi.decode(poolManager.unlock(
                abi.encode(Action.ModLP, sqrtPriceX96, delta1, 
                delta0, tickLower, tickUpper)), (BalanceDelta));
        }
    }

    function _addLiquidityHelper(uint delta0, uint delta1, uint price) internal 
        returns (uint, uint) { uint pending = PENDING_ETH + delta1; // < queued
        uint surplus = GD.get_total_deposits(true) - delta0;
        delta1 = Math.min(pending,
             FullMath.mulDiv(surplus * 1e12, WAD, price));
        if (delta1 > 0) { 
            delta0 = FullMath.mulDiv(delta1, price, WAD * 1e12); 
            pending -= delta1; 
        }   
        PENDING_ETH = pending;
        return (delta0, delta1);
    }

    function getSqrtPriceX96(uint price) public
        pure returns (uint160 sqrtPriceX96) {
        uint ratioX128 = FullMath.mulDiv(price, 1 << 128, WAD);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(
            FullMath.mulDiv(ratioX128, 1 << 64, 1 << 128)
        ));
    } // ^ TODO double check implementation

    // TODO remove (for testing purposes only)
    function set_price_eth(bool up) external {
        uint _price = getPrice(0, true);
        uint delta = _price / 20;
        _ETH_PRICE = up ? _price + delta:
                          _price - delta;
    }

    function getPrice(uint160 sqrtPriceX96, bool v3)
        public /*view*/ returns (uint price) {
        if (_ETH_PRICE > 0) { // TODO pure
            return _ETH_PRICE; // remove
        }
        if (sqrtPriceX96 == 0) { // TODO remove
            if (v3) {
                (sqrtPriceX96,,,,,,) = v3Pool.slot0();
            } else {
                PoolId id = vanillaKey.toId();
                (sqrtPriceX96,,,) = poolManager.getSlot0(id);
            }
        }
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
                 casted, casted, 1 << 64);
        
        if (!v3 || (v3 && token1isWETH)) {
            price = FullMath.mulDiv(1 << 128, 
                WAD * 1e12, ratioX128);
        } else {
            price = FullMath.mulDiv(ratioX128, 
                WAD * 1e12, 1 << 128);
        } 
    }

    // amount specifies only how much we are trying to sell...
    function swap(address token, bool zeroForOne, uint amount)
        isInitialised public payable returns (BalanceDelta) { 
        (uint160 sqrtPriceX96,,,) = _repack();
        uint price = getPrice(sqrtPriceX96, false);
        bool isStable = GD.isStable(token);
        // if this is true ^ user cares
        // about their output being all
        // in 1 specific token, so they 
        // won't get a balanced quantity 
        uint value; uint remains;
        if (!zeroForOne) { 
            require(token == address(GD) || isStable, "$!");
            value = FullMath.mulDiv(msg.value, price, WAD); 
            require(value >= 50 * WAD, "grant");
            if (value > POOLED_USD * 1e12) { 
                value = FullMath.mulDiv(WAD,
                    POOLED_USD * 1e12, price);
                remains = msg.value - value;

                weth.deposit{ value: remains }(); amount = value; // < max v4 can swap
                address receiver = token == address(USDC) ? msg.sender : address(this);

                value = FullMath.mulDiv(remains, price, WAD * 1e12);
                v3Router.exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(weth), uint24(500), address(USDC)),
                    receiver, block.timestamp, remains, value - value / 200));

                if (receiver == address(this)) {
                    // TODO swap USDC for desired token, send to msg.sender
                }

            } else {
                amount = msg.value;
            }
            (amount, ) = rex.deposit{value: amount}(address(this), true);
        } else {
            amount = GD.deposit(msg.sender, token, amount);
            uint scale = 18 - IERC20(token).decimals();
            value = scale > 0 ? amount * 10 ** scale : amount;
            // value is in ETH, and amount is in dollars
            value = FullMath.mulDiv(WAD, value, price);
            if (value > POOLED_ETH) {
                value = FullMath.mulDiv(POOLED_ETH,
                                 price, WAD * 1e12);

                remains = amount - value; amount = value;
                value = FullMath.mulDiv(WAD, remains, price);

                require(stdMath.delta(remains, GD.take(address(this),
                        remains, address(USDC))) <= 5, "$swap");

                weth.withdraw(v3Router.exactInput(ISwapRouter.ExactInputParams(
                    abi.encodePacked(address(USDC), uint24(500), address(weth)),
                    address(this), block.timestamp, remains, value - value / 200)));
            }
        } if (amount > 0) {
            BalanceDelta delta = abi.decode(
                poolManager.unlock(abi.encode(
                    Action.Swap, sqrtPriceX96,
                    msg.sender, zeroForOne, amount, 
                    token)), (BalanceDelta));

            uint ethBalance = address(this).balance;
            if (ethBalance > 0) { 
                CurrencyLibrary.ADDRESS_ZERO.transfer(
                               msg.sender, ethBalance); }
        }
    }

    function _unlockCallback(bytes calldata data) 
        internal override returns (bytes memory) {
        uint8 firstByte; BalanceDelta delta; 
        address who = address(this); assembly { 
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        } Action discriminant = Action(firstByte);
        bool inRange = true; address out;
        if (discriminant == Action.Swap) {
            (uint160 sqrtPriceX96, address sender, 
            bool zeroForOne, uint amount, address token) = abi.decode(
                    data[32:], (uint160, address, bool, uint, address));
            delta = poolManager.swap(vanillaKey, IPoolManager.SwapParams({ 
                zeroForOne: zeroForOne, amountSpecified: -int(amount),
                sqrtPriceLimitX96: _paddedSqrtPrice(sqrtPriceX96, 
                    !zeroForOne, 500) }), ZERO_BYTES); 
                    who = sender; out = token;
        } 
        else if (discriminant == Action.Repack) { 
            (uint128 myLiquidity, uint160 sqrtPriceX96,
            int24 tickLower, int24 tickUpper) = abi.decode(
                data[32:], (uint128, uint160, int24, int24));
                uint price = getPrice(sqrtPriceX96, false);

            BalanceDelta fees; POOLED_ETH = 0; POOLED_USD = 0;
            (delta, // helper resets  ^^^^^^^^^^^^^^^^^^^^^^^
             fees) = _modifyLiquidity(
                -int(uint(myLiquidity)),
                 tickLower, tickUpper);

            uint delta0 = uint(int(delta.amount0())); 
            uint delta1 = uint(int(delta.amount1()));
            vanillaKey.currency0.take(poolManager,
                    address(this), delta0, false);
                    mockUSD.burn(delta0);
            vanillaKey.currency1.take(poolManager,
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
             tickUpper,) = _updateTicks(sqrtPriceX96, 200);
            UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            (delta0, delta1) = _addLiquidityHelper(
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
            delta = _modLP(delta0, delta1, tickLower,
                            tickUpper, sqrtPriceX96);
        } 
        if (delta.amount0() > 0) { uint delta0 = uint(int(delta.amount0()));
            vanillaKey.currency0.take(poolManager, address(this), delta0, false);
            require(stdMath.delta(delta0, GD.take(who, delta0, out)) <= 5, "$0");
            mockUSD.burn(delta0); if (inRange) POOLED_USD -= delta0;
        }
        else if (delta.amount0() < 0) { 
            uint delta0 = uint(int(-delta.amount0())); mockUSD.mint(delta0); 
            vanillaKey.currency0.settle(poolManager, address(this), delta0, false);
            if (inRange) POOLED_USD += delta0;
        }
        if (delta.amount1() > 0) { uint delta1 = uint(int(delta.amount1()));
            vanillaKey.currency1.take(poolManager, address(this), delta1, false);
            mockETH.burn(delta1); unRex(delta1); if (inRange) POOLED_ETH -= delta1;
        }
        else if (delta.amount1() < 0) { 
            uint delta1 = uint(int(-delta.amount1())); mockETH.mint(delta1); 
            vanillaKey.currency1.settle(poolManager, address(this), delta1, false);
            if (inRange) POOLED_ETH += delta1;
        }
        return abi.encode(delta);
    }

    fallback() external payable {} // redeem triggers this, but it's
    // fine to leave the implementation blank; swap() handles transfer
    function unRex(uint howMuch) internal returns (uint amount) {
        uint fee = 2 * rex.fees(IPirexETH.Fees.InstantRedemption);
        amount = Math.min(rexVault.balanceOf(address(this)),
                          rexVault.convertToShares(howMuch +
                          FullMath.mulDiv(howMuch, fee, 1e6)));

        amount = rexVault.redeem(amount, address(this), address(this));
        (amount,) = rex.instantRedeemWithPxEth(amount, address(this));
        if (amount > howMuch) {rex.deposit{value: amount - howMuch}
                                            (address(this), true);
            amount = howMuch;
        }
    }

    // TODO address[] calldata whose 
    // include if 0for1 or both
    // if there is more liquidity
    // managed by our router than 
    // the v3 pool, use range orders
    function unwind(bool zeroForOne,
        address who) isInitialised external {
        viaAAVE memory pledge; uint buffer; uint reUP;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true));
        if (zeroForOne) {
            pledge = pledgesZeroForOne[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                // supplied is in USDC...
                if (pledge.borrowed > 0) {
                    weth.deposit{ value: unRex(pledge.borrowed) }();
                    _unwind(address(weth), address(USDC),
                        pledge.borrowed, pledge.supplied);
                        // debt gets paid off regardless

                    require(stdMath.delta(USDC.balanceOf(address(this)),
                          pledge.supplied) <= 5, "$supplied0for1");
                        // ^ we got collateral back from unwinding
                        // will be spent to buy dip or redeposited

                    if (delta <= -49) { // use all of the dollars we possibly can to buy the dip
                        buffer = FullMath.mulDiv(pledge.borrowed, uint(pledge.price), WAD * 1e12);
                        // recovered USDC we got from selling the borrowed ETH
                        reUP = GD.take(address(this), buffer, address(USDC));

                        require(stdMath.delta(reUP, buffer) <= 5,
                        "$buffer0for1"); buffer = reUP + pledge.supplied;
                        reUP = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                        buffer = v3Router.exactInput(ISwapRouter.ExactInputParams(
                            abi.encodePacked(address(USDC), uint24(500), address(weth)),
                            address(this), block.timestamp, buffer, reUP - reUP / 200));
                        weth.withdraw(buffer); // TODO PENDING_ETH ?
                        (pledge.supplied, ) = rex.deposit{value: buffer}
                                                (address(this), true);
                        pledge.price = price; // < so we may know when to sell later
                    } else { // the buffer will be saved in USDC, used to pivot later
                        buffer = unRex(pledge.buffer); weth.deposit{ value: buffer }();
                        reUP = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        buffer = v3Router.exactInput(ISwapRouter.ExactInputParams(
                            abi.encodePacked(address(weth), uint24(500), address(USDC)),
                            address(this), block.timestamp, buffer, reUP - reUP / 200));

                        reUP = buffer + pledge.supplied; pledge.supplied = 0;
                        require(reUP == GD.deposit(address(this), address(USDC), reUP));
                        pledge.buffer = reUP + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                    }
                    pledge.borrowed = 0;
                    pledgesZeroForOne[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.buffer > 0) { // try to buy the dip
                    buffer = GD.take(address(this), pledge.buffer, address(USDC));
                    require(stdMath.delta(buffer, pledge.buffer) <= 5, "buffer0for1$");

                    reUP = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = v3Router.exactInput(ISwapRouter.ExactInputParams(
                        abi.encodePacked(address(USDC), uint24(500), address(weth)),
                        address(this), block.timestamp, buffer, reUP - reUP / 200));

                    weth.withdraw(buffer);
                    (pledge.supplied, ) = rex.deposit{value: buffer}
                                            (address(this), true);

                    pledge.price = price; // < so we know when to sell
                    pledgesZeroForOne[who] = pledge; // later for profit
                }
                else if (delta >= 49 && pledge.supplied > 0) { // supplied is ETH
                    buffer = unRex(pledge.supplied); weth.deposit{ value: buffer }();
                    reUP = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                    reUP = v3Router.exactInput(ISwapRouter.ExactInputParams(
                        abi.encodePacked(address(weth), uint24(500), address(USDC)),
                        address(this), block.timestamp, buffer, reUP - reUP / 200));
                    require(reUP == GD.deposit(address(this), address(USDC), reUP));
                    delete pledgesZeroForOne[who]; // we completed the cross-over 🏀
                    // TODO measure gain somehow?
                } 
            }
        } else {
            pledge = pledgesOneForZero[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                if (pledge.borrowed > 0) {
                    require(stdMath.delta(pledge.borrowed,
                        GD.take(address(this), pledge.borrowed,
                        address(USDC))) <= 5, "unwind1for0$");

                    _unwind(address(USDC), address(weth),
                        pledge.borrowed, pledge.supplied);

                    if (delta >= 49) { // after this, supplied will be stored in USDC...
                        reUP = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = v3Router.exactInput(ISwapRouter.ExactInputParams(
                            abi.encodePacked(address(weth), uint24(500), address(USDC)),
                            address(this), block.timestamp, pledge.supplied, reUP - reUP / 200));

                        require(pledge.supplied == GD.deposit(address(this),
                                address(USDC), pledge.supplied));

                        pledge.price = price;
                    } else { // buffer is in ETH
                        weth.withdraw(pledge.supplied);
                        (pledge.buffer,) = rex.deposit{value: buffer}
                                            (address(this), true);
                        pledge.supplied = 0;
                    }
                    pledge.borrowed = 0;
                    pledgesOneForZero[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.supplied > 0) { // supplied in USDC
                    require(stdMath.delta(pledge.supplied, GD.take(address(this),
                        pledge.supplied, address(USDC))) <= 5, "$unwind1for0");
                    reUP = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer = v3Router.exactInput(ISwapRouter.ExactInputParams(
                        abi.encodePacked(address(USDC), uint24(500), address(weth)),
                        address(this), block.timestamp, pledge.supplied, reUP - reUP / 200));

                    pledge.supplied = 0;
                    pledge.price = price;
                    weth.withdraw(pledge.buffer);
                    rex.deposit{value: pledge.buffer}
                                (address(this), true);
                    pledgesOneForZero[who] = pledge;
                }
                else if (delta >= 49 && pledge.buffer > 0) {
                    buffer = unRex(pledge.buffer);
                    reUP = FullMath.mulDiv(uint(price),
                                    buffer, 1e12 * WAD);

                    reUP = v3Router.exactInput(ISwapRouter.ExactInputParams(
                        abi.encodePacked(address(weth), uint24(500), address(USDC)),
                        address(this), block.timestamp, buffer, reUP - reUP / 200));
                        require(reUP == GD.deposit(address(this), address(USDC), reUP));

                    delete pledgesOneForZero[who];
                }
            }
        }
    }

    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        IERC20(repay).approve(address(aave), borrowed);
        aave.repay(repay, borrowed, 2, address(this));  
        aave.withdraw(out, supplied, address(this));
    }

    function withdraw(uint amount) external { 
        (uint160 sqrtPriceX96, 
        int24 tickLower, int24 tickUpper,) = _repack(); 
        autoManaged[msg.sender] -= amount;
        uint pending = PENDING_ETH; 
        uint remains = amount;
        if (pending > 0) { 
            uint pulling = Math.min(pending, amount); 
            PENDING_ETH = pending - pulling;
            remains -= pulling; unRex(pulling); 
        }
        if (remains > 0) {
            require(mockETH.balanceOf(address(this)) > remains, "rm");
            BalanceDelta delta = abi.decode(poolManager.unlock(
                abi.encode(Action.ModLP, sqrtPriceX96, remains, 
                0, tickLower, tickUpper)), (BalanceDelta));
            uint ethBalance = address(this).balance;
            if (ethBalance > 0) { 
                CurrencyLibrary.ADDRESS_ZERO.transfer(
                               msg.sender, ethBalance); }
        } // TODO P&L
    }

    function _modifyLiquidity(int delta, // liquidity delta
        int24 lowerTick, int24 upperTick) internal returns 
        (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            vanillaKey, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }
    
    function _modLP(uint deltaZero, uint deltaOne, int24 tickLower, 
        int24 tickUpper, uint160 sqrtPriceX96) internal returns
        (BalanceDelta) {  int flip = deltaZero > 0 ? int(1) : int(-1);
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

    // "if you feel the urge to freak...do the jitterbug" ~ tribe
    function _updateTicks(uint160 sqrtPriceX96, uint delta) internal returns 
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

    function _repack() internal returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) { 
        int24 currentTick; PoolId id = vanillaKey.toId();
        myLiquidity = poolManager.getLiquidity(id);
        (sqrtPriceX96, 
        currentTick,,) = poolManager.getSlot0(id);
        
            tickUpper = UPPER_TICK;     tickLower = LOWER_TICK; 
        if (currentTick > tickUpper || currentTick < tickLower) {
            if (myLiquidity > 0) { // remove, then add liquidity
                poolManager.unlock(abi.encode(Action.Repack, 
                                  myLiquidity, sqrtPriceX96, 
                                    tickLower, tickUpper));
            } else {
                (tickLower,, 
                tickUpper,) = _updateTicks(sqrtPriceX96, 200);
                // 1% delta up, 1% down from ^^^^^^^^^^ total 2
                UPPER_TICK = tickUpper; LOWER_TICK = tickLower;
            }            
        }
    }
}
