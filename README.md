`forge install`  
`forge test -vv`  

In order to save gas, rather than writing a hook  
we decided to build functionality into a router.  
The router is embedded with a simple form of  
ASS (based on the Greedy Sequencing Rule:  
batch orders by type to prevent sandwiches).  

It supports adding liquidity out-of-range, as  
well as letting the range be managed for you:  
this provides optimal returns for LPs, except  
unlike the canonical USDC<>WETH pool, the  
dollar side is split between multiple stables...  

There is no IL for single-sided provision,  
by virtue of a "queue" (`PENDING_ETH`).  
There is only 1 PoolKey which represents  
ETH abstractly paired with (Some) dollar.  
LP fees are split 50:50 between ETH and  
dollar depositors, pro rata to total liquidity  
(not what's virtually deployed in the pool).  

In being abstract, swaps are performed  
using “virtual balances”; this is because  
ETH “on deposit” is really in Dinero’s LST,  
and not in the PoolManager, while various  
dollars are either in Morpho vaults or their  
native staking (e.g. GHO’s safety module).  

The utility token, GD, is considered  
the LP token for our "stable basket" 🏀   
where dollars (8 in total) are swappable  
interally (lAMMbert function). Thanks to  
AAVE, it’s also possible to do “leveraged  
swaps”: these take a bit of time, but are  
guaranteed to be profitable for both the  
protocol and the originators of the swap;  

it provides an incentivised mechanism for   
slowly shifting liquidity from UniV3 to V4.  
The strategy reminds us of Allen Iverson’s  
signature basketball move, the cross-over;  
through a weighted median function, the  
dollar LPs are able to vote on their % rake.  

