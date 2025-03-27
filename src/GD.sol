
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "lib/forge-std/src/console.sol";
// TODO delete logging before mainnet...

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {wadLn, wadExp} from "solmate/src/utils/SignedWadMath.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";
import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface IStakeToken is IERC20 { // StkGHO (safety module)
    function stake(address to, uint256 amount) external;
    // here the amount is in underlying, not in shares...
    function redeem(address to, uint256 amount) external;
    // the amount param is in shares, not underlying...
    function claimRewards(address to, uint256 amount) external;
    function previewStake(uint256 assets) 
             external view returns (uint256);
    function previewRedeem(uint256 shares) 
             external view returns (uint256);
}

import {MO} from  "./Router.sol"; 
contract Good is // stable basket
    ReentrancyGuard, ERC6909 { 
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IERC4626;
    using SortedSetLib for SortedSetLib.Set;
    
    uint constant WAD = 1e18;
    address[] public stables;
    
    address _deployer; 
    uint private _deployed;
    uint private _totalSupply;
    Metrics private coreMetrics;
    string private _name = "QU!D";
    string private _symbol = "GD";
    address payable public Mindwill;
    
    struct Metrics { 
        uint last; uint total; uint yield;
    }
    struct Pod { uint credit; uint debit; }
    mapping(address => Pod) public perVault;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStable;
    mapping(address => address) public vaults;
    
    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) public totalBalances;
    
    mapping(address => SortedSetLib.Set) private perMonth;
    mapping(address => mapping(// legacy IERC20 version
            address => uint256)) private _allowances;

    modifier onlyUs { 
        address sender = msg.sender;
        require(sender == Mindwill ||
                sender == address(this), "!?"); _;
    }

    /**
     * @dev Returns the current reading of our internal clock.
     */
    function currentMonth() public view returns
        (uint month) { month = (block.timestamp - 
                        _deployed) / 2420000; // ~28 days
    } 
    /**
     * @dev Returns the name of our token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of our token.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Tokens usually opt for a value of 18, 
     * imitating the relationship between Ether and Wei. 
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public 
        view returns (uint) {
        return _totalSupply;
    }

    function transfer(address to, // receiver
        uint amount) public returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, 
        uint256 value) public returns (bool) {
        require(spender != address(0), "suspender");
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function _til(uint when) 
        internal view returns (uint til) {
        uint current = currentMonth();
        if (when == 0) { 
            til = current + 1;
        } else { 
            til = Math.max(when,
                    current + 1);
            til = Math.min(when, 
                    current + 33);
        } 
    }

    function matureBatches(uint[] memory batches)
        public view returns (uint i) { 
        for (i = batches.length; i > 0; --i) {
            if (batches[i] <= currentMonth()) 
                break;
        }
    } 

    constructor(address _mo, 
        address[] memory _stables, 
        address[] memory _vaults) { 
        _deployed = block.timestamp; _deployer = msg.sender;
        require(_stables.length == _vaults.length, "align"); 
        address stable; address vault; stables = _stables;
        for (uint i = 0; i < _vaults.length; i++) {
            stable = _stables[i]; vault = _vaults[i];
            isVault[vault] = true; vaults[stable] = vault;
            isStable[stable] = true;
        }   Mindwill = payable(_mo); 
    }
    
    function get_total_deposits(bool force) 
        public returns (uint) { Metrics memory stats = coreMetrics;
        if (force || block.timestamp - stats.last > 10 minutes) {
            // give credit to this calculation often, lest stale
            uint[10] memory amounts = get_deposits();
            stats.last = block.timestamp;
            stats.total = amounts[0] / 1e12;
            stats.yield = FullMath.mulDiv(10000, 
               amounts[9], amounts[0] - amounts[8]) - 10000;
            coreMetrics = stats; // exclude sGHO "yield" as this
        }   return stats.total; // goes to the contract deployer
    } 

    function claim() external {
        address vault = vaults[
            stables[stables.length-1]];
        IStakeToken(vault).claimRewards(
            _deployer, type(uint256).max);
    }

    function get_deposits() public 
        returns (uint[10] memory amounts) {
        address vault; uint shares; // 4626
        uint ghoIndex = stables.length - 1;
        for (uint i = 0; i < ghoIndex; i++) { 
            uint multiplier = i > 1 ? 1 : 1e12;
            // ^ scale precision for USDC/USDT 
            vault = vaults[stables[i]];
            shares = perVault[vault].debit;
            if (shares > 0) { 
                shares = IERC4626(vault).convertToAssets(shares) * multiplier;
                amounts[i + 1] = shares; amounts[0] += shares; // track total;
                amounts[9] += FullMath.mulDiv(shares, // < weighted sum of 
                    IERC4626(vault).totalAssets() * multiplier, // APY 
                    IERC4626(vault).totalSupply()); // for staking...
            }
        } vault = vaults[stables[ghoIndex]]; 
        
        shares = IStakeToken(vault).previewRedeem( 
                 IStakeToken(vault).balanceOf(
                                address(this))); 

        amounts[stables.length] = shares; 
        amounts[0] += shares; // our total
    }

    function take(address who, // on whose behalf $ exiting the basket
        uint amount, address token) public onlyUs returns (uint sent) {
        if (token == address(this)) { // evenly distributed disbursement
            uint[10] memory amounts = get_deposits();
            uint total = amounts[0]; address vault;
            uint ghoIndex = stables.length;
            for (uint i = 1; i < ghoIndex; i++) { 
                uint divisor = i > 1 ? 1 : 1e12;
                amounts[i] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                        WAD, amounts[i], total), WAD);
                amounts[i] /= divisor;
                if (amounts[i] > 0) { vault = vaults[stables[i - 1]]; 
                    amounts[i] = withdraw(who, vault, amounts[i]);
                    sent += amounts[i];  
                } 
            } vault = vaults[stables[stables.length - 1]]; 
            
            amounts[ghoIndex] = FullMath.mulDiv(amount, FullMath.mulDiv(
                                    WAD, amounts[ghoIndex], total), WAD);
            
            if (amounts[ghoIndex] > 0) { 
                // exchange rate is 1:1, but just to be safe we calculate
                amount = IStakeToken(vault).previewStake(amounts[ghoIndex]);
                require(IStakeToken(vault).previewRedeem(amount) == amounts[ghoIndex], "sgho");
                IStakeToken(vault).redeem(who, amount); sent += amounts[ghoIndex];
            }
        } else { // TODO swap through Curve if we don't have enough of the token we need?
            return withdraw(who, vaults[token], amount);
        }   
    }

    function withdraw(address to, address vault, uint amount) internal returns (uint sent) {
        uint sharesWithdrawn = Math.min(IERC4626(vault).balanceOf(address(this)),
                                        IERC4626(vault).convertToShares(amount));
        
        sent = IERC4626(vault).convertToAssets(sharesWithdrawn);
        require(sent == IERC4626(vault).redeem(sharesWithdrawn, to,
                                            address(this)), "take");
        perVault[vault].credit -= sent;
        perVault[vault].debit -= sharesWithdrawn;
    }

    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        address GHO = stables[stables.length - 1]; 
        address SGHO = vaults[GHO]; address vault;
        if (isVault[token] && token != SGHO) { 
            amount = Math.min(
                IERC4626(token).allowance(from, address(this)),
                 IERC4626(token).convertToShares(amount));
            usd = IERC4626(token).convertToAssets(amount);
                   IERC4626(token).transferFrom(msg.sender,
                                    address(this), amount);
            require(usd >= 50 * 
            (10 ** IERC20(IERC4626(token).asset()).decimals()) , "grant");
            perVault[token].debit += amount; perVault[token].credit += usd;
        }    
        else if (isStable[token] || token == SGHO) {
            usd = Math.min(amount, 
            IERC20(token).allowance(
                from, address(this)));
            IERC20(token).transferFrom(
                from, address(this), usd);
            require(usd >= 50 * (10 ** 
                IERC20(token).decimals()), "grant");
            if (token == GHO) { vault = SGHO;
                IERC20(token).approve(vault, usd);
                amount = IStakeToken(vault).previewStake(usd);
                IStakeToken(vault).stake(address(this), usd);
            } 
            else if (token != SGHO) { 
                vault = vaults[token];
                IERC20(token).approve(vault, usd);
                amount = IERC4626(vault).deposit(usd, 
                                    address(this));
            } perVault[vault].debit += amount;
              perVault[vault].credit += usd;
        } else {
            require(false, "unsupported token");
        }
    }

    // overriding standard 6909 code
    function _mint(address receiver,
        uint256 id, uint256 amount
    ) internal override {
        _totalSupply += amount; 
        totalSupplies[id] += amount; 
        perMonth[receiver].insert(id);
        
        totalBalances[receiver] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, 
            address(0), receiver,
            id, amount);
    }

    /**
     * @dev the cost of minting depends on
     * how much risk is encumbered in MO,
     * as well as total demand to mint,
     * and, finally, bonding duration
     * @param pledge is on whose behalf...
     * @param amount is the amount to mint
     * @param token is what will be bonded
     * @param when is when amount matures
     */
    function mint(address pledge, uint amount, 
        address token, uint when) public 
        nonReentrant { uint month = _til(when);
        if (token == address(this)) {
            require(msg.sender == Mindwill, "403");
            _mint(pledge, month, amount);
        }   
        else { 
            // uint cost = amount / 2; // TODO math
            uint paid = deposit(pledge, token, amount);
            _mint(pledge, month, amount);
            // MO(Mindwill).mint(pledge, cost, amount);
        }
    }

    function transferFrom(address from, 
        address to, uint amount) public 
        returns (bool) {
        if (msg.sender != from 
            && !isOperator[from][msg.sender]) {
            if (to == Mindwill) {
                require(msg.sender == Mindwill, "403");
            }    
            uint256 allowed = _allowances[from][msg.sender];
            if (allowed != type(uint256).max) {
                _allowances[from][msg.sender] = allowed - amount;
            }
        } return _transfer(from, to, amount);
    }

    function turn(address from, // whose balance
        uint value) public returns (uint) {
        require(msg.sender == Mindwill, "403");
        uint oldBalanceFrom = totalBalances[from];
        uint sent = _transferHelper(
        from, address(0), value);
        // carry.debit will be untouched here...
        // return MO(Mindwill).transferHelper(from,
        //     address(0), sent, oldBalanceFrom);
    }

    // eventually a balance may be spread
    // over enough batches that this will
    // run out of gas, so there will be
    // no choice other than to use the 
    // more granular version of transfer
    function _transferHelper(address from, 
        address to, uint amount) 
        internal returns (uint sent) {
        // must be int or tx reverts when we go below 0 in loop
        uint[] memory batches = perMonth[from].getSortedSet();
        // if i = 0 then this will either give us one iteration,
        // or exit with index out of bounds, both make sense...
        bool toZero = to == address(0);
        bool burning = toZero || to == Mindwill;
        int i = toZero ? 
            int(matureBatches(batches)) :
            int(batches.length - 1);
            // if length is zero this
            // may cause error code 11
            // which is totally legal
        while (amount > 0 && i >= 0) { 
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) { 
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!burning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else {
                    totalSupplies[k] -= sent;
                }
                if (balanceOf[from][k] == 0) {
                    perMonth[from].remove(k);
                }
                amount -= amt; 
                sent += amt;
            }   i -= 1; 
        } 
        totalBalances[from] -= sent;
        if (burning) {
            _totalSupply -= sent;
        } else {
            totalBalances[to] += sent;
        }
    }

    /**
     * @dev A transfer which doesn't specifying the 
     * batch will proceed backwards from most recent
     * to oldest batch until the transfer amount is 
     * fulfilled entirely. Tokenholders that desire 
     * a more granular result should use the other
     * transfer function (we do not override 6909)
     */
    function _transfer(address from, address to,
        uint amount) internal returns (bool) {
        // uint senderVote = feeVotes[from]; // TODO
        // ^ this variable allows us to only
        // read from storage once to save gas
        uint oldBalanceFrom = totalBalances[from];
        uint oldBalanceTo = totalBalances[to];
        uint value = _transferHelper(
                from, to, amount);
        
        uint sent = 0;
        // uint sent = MO(Mindwill).transferHelper(
        //      from, to, value, oldBalanceFrom);
        
        if (value != sent) { // this is only for
        // the situation where to == address(MO): 
        // burning debt, and in the case where we 
        // tried to burn more than was available
            value -= sent; // value is now excess
            // which is the amount we can't burn;
            // _transfeHelper displaced the entire 
            // value from various maturities, to 
            // undo this perfectly would be too much
            // work, so we just mint delta as current 
            _mint(from, currentMonth() + 2, value);
            value = sent; // mint increases supply
        } 
        // _calculateMedian(oldBalanceFrom, senderVote, 
        //          oldBalanceFrom - value, senderVote);
        // rebalace the median with updated stake...
        if (to != address(0)) {
            // uint receiverVote = feeVotes[to];
            // _calculateMedian(oldBalanceTo, receiverVote, 
            //          oldBalanceTo + value, receiverVote);
        } return true; // TODO delegation of voting power...
    }
}