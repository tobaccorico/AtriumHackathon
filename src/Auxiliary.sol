

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Basket} from "./Basket.sol";
import {Router} from "./Router.sol";
import {Auxiliary} from "./Auxiliary.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {ISwapRouter} from "./imports/v3/ISwapRouter.sol"; // on L1 and Arbitrum
// import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol"; // base
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "lib/forge-std/src/console.sol"; // TODO remove

contract Auxiliary is Ownable { 
    bool internal token1isWETH;
    ISwapRouter v3Router; // ^
    IUniswapV3Pool v3Pool;
    Router V4; IPool AAVE;
    IERC20 USDC; WETH9 WETH;
    IERC4626 wethVault;
    Basket QUID;

    uint internal _ETH_PRICE; // TODO remove

    uint public LEVER_YIELD;
    // ^ in raw terms
    // uint public LEVER_MARGIN;
    // ^ TODO measure the rate
    // of change of LEVER_YIELD

    uint public SWAP_COST;
    uint public GAS_BUDGET;
    uint public PENDING_ETH;
    // ^ single-sided liqudity
    // that is waiting for $
    // before it's deposited

    struct Deposit {
        uint pooled_eth;
        uint eth_shares;
        uint usd_owed;
        // Masterchef-style
        // snapshots of fees:
        uint fees_eth;
        uint fees_usd;
    }

    mapping(address => uint[]) positions;
    // ^ allows several selfManaged positions
    mapping(address => Deposit) autoManaged;
    // ^ price range gets handled by contract
    mapping(uint => SelfManaged) selfManaged;
    struct SelfManaged {
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }
    struct viaAAVE {
        uint breakeven;
        uint supplied;
        uint borrowed;
        uint buffer;
        int price;
    }
    mapping(address => viaAAVE) pledgesOneForZero;
    mapping(address => viaAAVE) pledgesZeroForOne;

    // _unlockCallback
    enum Action { Swap,
        Repack, ModLP,
        OutsideRange
    } uint internal tokenId;
    // ^ always incrementing
    uint constant WAD = 1e18;

    modifier onlyRouter {
        require(msg.sender == address(V4), "403"); _;
    }

    constructor(address _router, address _v3pool, 
        address _v3router, address _wethVault, 
        address _aave) Ownable(msg.sender) {
        V4 = Router(_router); 
        v3Pool = IUniswapV3Pool(_v3pool);
        v3Router = ISwapRouter(_v3router);
        wethVault = IERC4626(_wethVault);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true; 
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        }   AAVE = IPool(_aave);
        SWAP_COST = 1817119;
        // ^ gas for one swap
    }

    function getPrice(uint160 sqrtPriceX96, bool v3)
        public /*view*/ returns (uint price) {
        if (_ETH_PRICE > 0) { // TODO pure
            return _ETH_PRICE; // remove
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
        _ETH_PRICE = price;
    }

    // must send $1 USDC to address(this) & attach msg.value 1 wei
    function setQuid(address _quid) external payable onlyOwner {    
        require(address(QUID) == address(0), "QUID");
        QUID = Basket(_quid); renounceOwnership();
        
        USDC.approve(address(QUID), 
                type(uint256).max);                    
        USDC.approve(address(v3Router),
                    type(uint256).max);
        WETH.approve(address(wethVault),
                    type(uint256).max);
        WETH.approve(address(v3Router),
                    type(uint256).max);

        // ^ max approvals considered safe
        // to make as we fully control code
        WETH.approve(address(AAVE), 1 wei);
        WETH.deposit{value: 1 wei}();
        AAVE.supply(address(WETH),
             1 wei, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(
                        address(WETH), true);

        USDC.approve(address(AAVE), 1e6);
        AAVE.supply(address(USDC),
           1000000, address(this), 0);
        AAVE.setUserUseReserveAsCollateral(
                        address(USDC), true);
    }

    // amount specifies only how much we are trying to sell...
    function swap(address token, bool zeroForOne, 
        uint amount) public payable {
        (uint160 sqrtPriceX96,,,) = V4.repack();
        uint price = getPrice(sqrtPriceX96, false);
        bool isStable = QUID.isStable(token);
        // if this is true ^ user cares
        // about their output being all
        // in 1 specific token, so they
        // won't get balanced quantity...
        uint value; uint remains; uint got;
        if (!zeroForOne) {
            require(token == address(QUID) || isStable, "$!");
            if (amount > 0) {
                WETH.transferFrom(msg.sender,
                    address(this), amount);
            }
            if (msg.value > 0) {
                WETH.deposit{value: msg.value}();
                amount += msg.value;
            }
            amount -= SWAP_COST;
            GAS_BUDGET += SWAP_COST;
            value = FullMath.mulDiv(
                  amount, price, WAD);
            require(value >= 50 * WAD, "grant");
            uint pooled_usd = V4.POOLED_USD();
            if (value > pooled_usd * 1e12) {
                remains = value - pooled_usd * 1e12;

                value = FullMath.mulDiv(WAD,
                              remains, price);
                              amount -= value;

                value = _getUSDC(value,
                (remains - remains / 200) / 1e12);
                USDC.transfer(msg.sender, value);
            }
            wethVault.deposit(amount,
                      address(this));
        }
        else {
            amount = QUID.deposit(msg.sender, token, amount);
            uint scale = 18 - IERC20(token).decimals();
            value = scale > 0 ? amount * (10 ** scale) : amount;
            // value is in ETH, and amount is in dollars
            value = FullMath.mulDiv(WAD, value, price);
            uint pooled_eth = V4.POOLED_ETH();
            if (value > pooled_eth) {
                value = FullMath.mulDiv(pooled_eth,
                                 price, WAD * 1e12);

                remains = amount - value; amount = value;
                value = FullMath.mulDiv(WAD, remains, price);
                require(stdMath.delta(remains, QUID.take(
                    address(this), remains, address(USDC))) <= 5);
                    got = _getWETH(remains, value - value / 200);

                WETH.withdraw(got); 
                (bool _success, ) = payable(msg.sender).call{value: got}("");
                assert(_success);
            }
        } if (amount > 0) { // TODO assembly call with gas 
            V4.swap(msg.sender, zeroForOne, 
                sqrtPriceX96, amount, token);
        }
    }    

    function leverZeroForOne() public payable {
        uint borrowing = msg.value * 7 / 10;
        uint buffer = msg.value - borrowing;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);
        uint totalValue = FullMath.mulDiv(msg.value,
                                         price, WAD);
        require(totalValue > 50 * WAD, "grant");
        uint took = QUID.take(address(this),
            totalValue / 1e12, address(USDC));

        require(stdMath.delta(totalValue / 1e12, took) <= 5, "0for1$");
        USDC.approve(address(AAVE), took);
        AAVE.supply(address(USDC), took, address(this), 0);
        AAVE.borrow(address(WETH), borrowing, 2, 0, address(this));
        uint amount = FullMath.mulDiv(borrowing, price, 1e12 * WAD);
        amount = _getUSDC(borrowing, amount - amount / 200);
        require(amount == QUID.deposit(address(this),
                            address(USDC), amount));

        uint withProfit = totalValue + totalValue / 42;
        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesZeroForOne[msg.sender] = viaAAVE({
            breakeven: totalValue, // < supplied gets
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: took, borrowed: borrowing,
            buffer: buffer, price: int(price) });
    }

    function leverOneForZero(uint amount, address token) external {
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        uint price = getPrice(sqrtPriceX96, true);

        amount = QUID.deposit(msg.sender, token, amount);
        uint scaled = 18 - IERC20(token).decimals();
        scaled = scaled > 0 ? amount * (10 ** scaled) : amount;

        uint withProfit = scaled + scaled / 42;
        uint inETH = FullMath.mulDiv(WAD,
                        scaled, price);

        inETH = _takeWETH(inETH);
        WETH.approve(address(AAVE), inETH);
        AAVE.supply(address(WETH), inETH, address(this), 0);
        amount = FullMath.mulDiv(inETH * 7 / 10, price, WAD * 1e12);
        AAVE.borrow(address(USDC), amount, 2, 0, address(this));
        require(amount == QUID.deposit(address(this),
                 address(USDC), amount));

        QUID.mint(msg.sender, withProfit, address(QUID), 0);
        pledgesOneForZero[msg.sender] = viaAAVE({
            breakeven: scaled, // < supplied gets
            // reset; need to remember original value
            // in order to calculate gains eventually
            supplied: inETH, borrowed: amount,
            buffer: 0, price: int(price) });
    }

    // "distance" is how far away from current price
    // measured in ticks (100 = 1%); negative = add
    function outOfRange(uint amount, address token,
        int24 distance, uint range) public
        payable returns (uint next) {

        require(distance % 200 == 0 && distance != 0
            && (distance >= -5000 || distance <= 5000), "distance");
        require(range >= 100 && range <= 1000 && range % 50 == 0, "width");

        (uint160 sqrtPriceX96,
        int24 lowerTick, int24 upperTick,) = V4.repack();
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(
            TickMath.getTickAtSqrtPrice(sqrtPriceX96)
            - int24(distance) // shift away from current
            // price using tick value +/- 2-50% going in
            // increments of 1 % (half a % for the range)
        );
         int liquidity; bool isStable;
        (int24 tickLower, uint160 lower,
         int24 tickUpper, uint160 upper) = V4.updateTicks(
                                      sqrtPriceX96, range);
        if (token == address(0)) {
            require(lowerTick > tickUpper, "right");
            if (amount > 0) {
                WETH.transferFrom(msg.sender,
                    address(this), amount);
            }
            if (msg.value > 0) {
                WETH.deposit{value: msg.value}();
                amount += msg.value;
            }
            wethVault.deposit(amount, address(this));

            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmount1(
                    lower, upper, amount
                )));
        } else {
            require(tickLower > upperTick, "left");
            amount = QUID.deposit(msg.sender,
                                token, amount);
            uint scale = IERC20(token).decimals() - 6;
            amount /= scale > 0 ? (10 ** scale) : 1;
            isStable = true;
            liquidity = int(uint(
                LiquidityAmounts.getLiquidityForAmount0(
                    lower, upper, amount
                )));
        }
        SelfManaged memory newPosition = SelfManaged({
            owner: msg.sender, lower: tickLower, 
            upper: tickUpper, liq: liquidity
        });
        next = tokenId + 1;
        selfManaged[next] = newPosition;
        positions[msg.sender].push(next);
        tokenId = next;
        V4.outOfRange(msg.sender, liquidity, 
                      tickLower, tickUpper);
    }

    function reclaim(uint id, int percent) external {
        SelfManaged memory position = selfManaged[id];
        require(position.owner == msg.sender, "403");
        require(percent > 0 && percent < 101, "%");
        int liquidity = position.liq * percent / 100;
        uint[] storage myIds = positions[msg.sender];
        uint lastIndex = myIds.length - 1;
        if (percent == 100) { delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) {
                        myIds[i] = myIds[lastIndex];
                    }   myIds.pop(); break;
                }
            }
        } else {    position.liq -= liquidity;
            require(position.liq > 0, "reclaim");
            selfManaged[id] = position;
        }
        V4.outOfRange(msg.sender, -liquidity, 
            position.lower, position.upper);
    } 

    function redeem(uint amount) external { // TODO add caps
        // to not exceed matureWhen(batch) for maximum -- ^
        require(amount >= WAD, "will round down to nothing");
        amount = QUID.turn(msg.sender, amount);
        (uint total, ) = QUID.get_metrics(false);
        if (amount > 0) {
            uint gains = FullMath.mulDiv(LEVER_YIELD,
                                        amount, total);
            LEVER_YIELD -= gains; amount += gains;
            QUID.take(msg.sender, amount, address(QUID));
        }
    }

    // TODO spread over time for huge withdraws
    function withdraw(uint amount) external { 
        Deposit memory LP = autoManaged[msg.sender]; 
        uint eth_fees = V4.ETH_FEES(); uint usd_fees = V4.USD_FEES();
        // swap fee yield, which uses ^^^^^^^^^^ to buy into unwind
        // instead of V3, which doesn't get more than half, future
        uint pending = PENDING_ETH; uint pooled_eth = V4.POOLED_ETH();
        uint fees_eth = FullMath.mulDiv((eth_fees - LP.fees_eth),
                                      LP.pooled_eth, pooled_eth);

        uint fees_usd = FullMath.mulDiv((usd_fees - LP.fees_usd),
                                      LP.pooled_eth, pooled_eth);
        LP.pooled_eth += fees_eth;

        QUID.mint(msg.sender, LP.usd_owed + fees_usd,
                  address(QUID), 0); LP.usd_owed = 0;
        pooled_eth = Math.min(amount, LP.pooled_eth);

        if (pooled_eth > 0) {
            uint pulled; uint pulling;
            LP.pooled_eth -= pooled_eth;
            amount = LP.pooled_eth == 0 ? LP.eth_shares :
                     wethVault.convertToShares(amount);
                              LP.eth_shares -= amount;
            pulled = wethVault.convertToAssets(amount) - pooled_eth;
            if (pending > 0) { pulling = Math.min(pending, pooled_eth);
                PENDING_ETH = pending - pulling;
                pooled_eth -= pulling;
                pulled += pulling;
            }
            if (pooled_eth > 0) {
                (uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper,) = V4.repack();
                V4.modLP(sqrtPriceX96, pooled_eth, 0, tickLower, tickUpper);
            } 
            _sendETH(pulled, msg.sender);
        }
        if (LP.eth_shares == 0) { delete autoManaged[msg.sender]; }
        else { LP.fees_eth = eth_fees; LP.fees_usd = usd_fees; }
    }

    function deposit(uint amount)
        external payable {
        if (amount > 0) {
            WETH.transferFrom(msg.sender,
                address(this), amount);
        }
        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            amount += msg.value;
        }
        uint pooled_eth = V4.POOLED_ETH();
        Deposit memory LP = autoManaged[msg.sender];

        uint eth_fees = V4.ETH_FEES(); 
        uint usd_fees = V4.USD_FEES();
        
        if (LP.fees_eth > 0 || LP.fees_usd > 0) {
            LP.usd_owed += FullMath.mulDiv((usd_fees - LP.fees_usd),
                                          LP.pooled_eth, pooled_eth);

            LP.pooled_eth += FullMath.mulDiv((eth_fees - LP.fees_eth),
                                           LP.pooled_eth, pooled_eth);
        }
        LP.fees_eth = eth_fees; LP.fees_usd = usd_fees;
        LP.eth_shares += wethVault.deposit(amount,
                                    address(this));
        LP.pooled_eth += amount;
        _addLiquidity(V4.POOLED_USD(), amount);
        autoManaged[msg.sender] = LP;
    }

    function _addLiquidity(uint delta0, 
        uint delta1) internal { (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper,) = V4.repack();
        uint price = getPrice(sqrtPriceX96, false);
        (delta0, delta1) = _addLiquidityHelper(
                         delta0, delta1, price);
        if (delta0 > 0) { 
            require(delta1 > 0, "_add");
            V4.modLP(sqrtPriceX96, delta1,
            delta0, tickLower, tickUpper);
        }
    }

    function addLiquidityHelper(uint delta0, uint delta1, uint price) public 
        onlyRouter returns (uint, uint) { return _addLiquidityHelper(
                                               delta0, delta1, price); }

    function _addLiquidityHelper(uint delta0, uint delta1, 
        uint price) internal returns (uint, uint) {
        uint pending = PENDING_ETH + delta1;
      
        (uint total, ) = QUID.get_metrics(false);
        uint surplus = (total / 1e12) - delta0;
       
        delta1 = Math.min(pending,
            FullMath.mulDiv(surplus *
                    1e12, WAD, price));
      
        if (delta1 > 0) { pending -= delta1; 
            delta0 = FullMath.mulDiv(delta1,
                        price, WAD * 1e12);
        } PENDING_ETH = pending;
        return (delta0, delta1);
    }

    // TODO remove (for testing purposes only)
    function set_price_eth(bool up) external {
        uint _price = getPrice(0, true);
        uint delta = _price / 20;
        _ETH_PRICE = up ? _price + delta:
                          _price - delta;
    }

    function _getUSDC(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(WETH), uint24(500), address(USDC)),
            address(this), block.timestamp, howMuch, minExpected));
    }

    function _getWETH(uint howMuch, uint minExpected) internal returns (uint) {
        return v3Router.exactInput(ISwapRouter.ExactInputParams(
            abi.encodePacked(address(USDC), uint24(500), address(WETH)),
            address(this), block.timestamp, howMuch, minExpected));
    }

    function _takeWETH(uint howMuch) internal returns (uint withdrawn) {
        uint amount = Math.min(wethVault.balanceOf(address(this)),
                               wethVault.convertToShares(howMuch));
        withdrawn = wethVault.redeem(amount, address(this), address(this));
    }   fallback() external payable {} // weth.withdraw() triggers this...

    function sendETH(uint howMuch, address toWhom) 
        public onlyRouter { _sendETH(howMuch, toWhom); }

    function _sendETH(uint howMuch, address toWhom) internal {
        howMuch = _takeWETH(howMuch); WETH.withdraw(howMuch);
        (bool _success, ) = payable(toWhom).call{value: howMuch}("");
        assert(_success);
    }
    
    function unwindZeroForOne(address[] calldata whose) external {
        viaAAVE memory pledge; uint buffer; uint reUP;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true));
        // we always take profits (fully exit) in USDC
        for (uint i = 0; i < whose.length; i++) {
            address who = whose[i];
            pledge = pledgesZeroForOne[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                if (pledge.borrowed > 0) { // supplied is in USDC
                    _takeWETH(pledge.borrowed); // so we can repay
                    _unwind(address(WETH), address(USDC),
                        pledge.borrowed, pledge.supplied);
                        // debt gets paid off regardless

                    require(stdMath.delta(USDC.balanceOf(address(this)),
                          pledge.supplied) <= 5, "$supplied0for1");
                        // ^ we got collateral back from unwinding
                        // will be spent to buy dip or redeposited

                    if (delta <= -49) { // use all of the dollars we possibly can to buy the dip
                        buffer = FullMath.mulDiv(pledge.borrowed, uint(pledge.price), WAD * 1e12);
                        // recovered USDC we got from selling the borrowed ETH
                        reUP = QUID.take(address(this), buffer, address(USDC));

                        require(stdMath.delta(reUP, buffer) <= 5,
                        "$buffer0for1"); buffer = reUP + pledge.supplied;
                        reUP = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                        buffer = _getWETH(buffer, reUP - reUP / 200);
                        pledge.supplied = buffer; wethVault.deposit(buffer,
                                                            address(this));
                        pledge.price = price; // < so we may know when to sell later
                    } else { // the buffer will be saved in USDC, used to pivot later
                        buffer = _takeWETH(pledge.buffer);
                        reUP = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        reUP = _getUSDC(buffer, reUP - reUP / 200) + pledge.supplied;
                        require(reUP == QUID.deposit(address(this), address(USDC), reUP));
                        pledge.buffer = reUP + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                        pledge.supplied = 0;
                    }
                    pledge.borrowed = 0;
                    pledgesZeroForOne[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.buffer > 0) { // try to buy the dip
                    buffer = QUID.take(address(this), pledge.buffer, address(USDC));
                    require(stdMath.delta(buffer, pledge.buffer) <= 5);

                    reUP = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = _getWETH(buffer, reUP - reUP / 200);
                    pledge.supplied = buffer; wethVault.deposit(buffer,
                                                         address(this));
                    pledge.price = price; // < so we know when to sell
                    pledgesZeroForOne[who] = pledge; // later for profit
                }
                else if (delta >= 49 && pledge.supplied > 0) {
                    buffer = _takeWETH(pledge.supplied); // supplied is ETH
                    reUP = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                    reUP = _getUSDC(buffer, reUP - reUP / 200);

                    require(reUP == QUID.deposit(address(this), address(USDC), reUP));
                    delete pledgesZeroForOne[who]; // we completed the cross-over 🏀
                    LEVER_YIELD += (reUP - pledge.breakeven / 1e12) * 1e12;
                }
            }
        }
    }

    function unwindOneForZero(address[] calldata whose) external {
        viaAAVE memory pledge; uint buffer; uint reUP;
        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        int price = int(getPrice(sqrtPriceX96, true));
        // we always take profits (fully exit) in USDC
        for (uint i = 0; i < whose.length; i++) {
            address who = whose[i];
            pledge = pledgesOneForZero[who];
            int delta = (price - pledge.price)
                        * 1000 / pledge.price;
            if (delta <= -49 || delta >= 49) {
                if (pledge.borrowed > 0) {
                    require(stdMath.delta(pledge.borrowed,
                        QUID.take(address(this), pledge.borrowed,
                        address(USDC))) <= 5, "unwind1for0$");

                    _unwind(address(USDC), address(WETH),
                        pledge.borrowed, pledge.supplied);

                    if (delta >= 49) { // after this, supplied will be stored in USDC...
                        reUP = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = _getUSDC(pledge.supplied, reUP - reUP / 200);

                        require(pledge.supplied == QUID.deposit(address(this),
                                            address(USDC), pledge.supplied));

                        pledge.price = price;
                    } else { // buffer is in ETH
                        pledge.buffer = pledge.supplied;
                        wethVault.deposit(pledge.supplied,
                                          address(this));
                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledgesOneForZero[who] = pledge;
                }
                // the following condition is our initial pivot
                else if (delta <= -49 && pledge.supplied > 0) {
                    require(stdMath.delta(pledge.supplied, QUID.take(
                        address(this), pledge.supplied, address(USDC))) <= 5);
                    reUP = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer =_getWETH(pledge.supplied, reUP - reUP / 200);

                    wethVault.deposit(pledge.buffer,
                                      address(this));
                    pledge.supplied = 0;
                    pledge.price = price;
                    pledgesOneForZero[who] = pledge;
                }
                else if (delta >= 49 && pledge.buffer > 0) {
                    buffer = _takeWETH(pledge.buffer);
                    reUP = FullMath.mulDiv(uint(price),
                                    buffer, 1e12 * WAD);

                    reUP = _getUSDC(buffer, reUP - reUP / 200);
                    require(reUP == QUID.deposit(address(this),
                                        address(USDC), reUP));

                    LEVER_YIELD += (reUP - pledge.breakeven / 1e12) * 1e12;
                    delete pledgesOneForZero[who];
                }
            }
        }
    }

    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        IERC20(repay).approve(address(AAVE), borrowed);
        AAVE.repay(repay, borrowed, 2, address(this));
        AAVE.withdraw(out, supplied, address(this));
    }
}
