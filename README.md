`forge install`  
`forge test -vv`  
`TODO`s are in *italic*

In order to save gas, rather than writing a hook  
we decided to build functionality into a router.  
*The router is embedded with a simple form of  
**ASS** (based on the Greedy Sequencing Rule:  
batch orders by type **prevents sandwiches**).*  

It supports adding liquidity out-of-range, as  
well as letting the range be managed for you:  
this provides optimal returns for LPs, except  
unlike the canonical USDC<>WETH pool, the  
dollar side is split between multiple stables.  

If a swap can't by satisfied by internal  
liquidity entirely, it gets split between  
our router and the V3 router (legacy).  

There is no IL for **single-sided provision**,  
by virtue of a "queue" (`PENDING_ETH`).  
There is only 1 PoolKey which represents  
ETH abstractly paired with (Some) dollar.  

*LP fees are split 50:50 between ETH and  
dollar depositors, pro rata to total liquidity  
(not what's virtually deployed in the pool).*  

A sort of **zero-coupon bond** feature is used  
to tokenise gains upfront (redeemable later),  
with flexible maturities: our **6909 extension**.

In being abstract, swaps are performed  
using “virtual balances”; this is because  
ETH “on deposit” is really in **Dinero’s LST**,  
and not in the PoolManager, while various  
dollars are either in Morpho vaults or their  
native staking (e.g. GHO’s safety module).  

**In order for this to be successful in prod**  
**Dinero DAO must vote to cut fees 100x**

The utility token, GD, is considered  
the LP token for our "stable basket" 🏀   
where dollars (8 in total) *are swappable  
interally through a **lAMMbert function***

AAVE allows us to do what we're calling  
“**levered swaps**”: they take time, but are  
**guaranteed to be profitable** for both the  
protocol, and the originators of the swaps  
(for them, in annualised terms, ~40% yield)

With almost negligible liquidation risk,  
providing an incentivised mechanism for  
slowly shifting liquidity from UniV3 to V4,  
the strategy reminds us of Allen Iverson’s  
signature basketball move: the cross-over.  
