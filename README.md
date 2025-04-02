
**AAVE** helps us to do a couple of things:  
flash loans allow batching together swaps in  
in a format which prevents sandwich attacks;  
“**levered swaps**” take extra time, but are  
**guaranteed to be profitable** for both the  
protocol, and the originators of the swaps  
(for them, in annualised terms, ~30% yield)

With almost negligible liquidation risk,  
providing an incentivised mechanism for  
slowly shifting liquidity from UniV3 to V4,  
the strategy reminds us of Allen Iverson’s  
signature basketball move: the cross-over.  

In order to save gas, rather than writing a hook  
we decided to build functionality into a router.  
It supports adding liquidity out-of-range, and  
also letting the range be managed for you:  

this provides optimal returns for LPs, except  
unlike the canonical USDC<>WETH pool, the  
dollar side is split between **multiple stables**.  

If a swap can't by satisfied by internal  
liquidity entirely, it gets split between  
our router and the legacy V3 router...

There is no IL for **single-sided provision**,  
by virtue of a "queue" (`PENDING_ETH`).  
There is only 1 PoolKey which represents  
ETH abstractly paired with (Some) dollar.  

In being abstract, swaps are performed  
using “virtual balances”; this is because  
ETH “on deposit” is in **a Morpho vault**,  
and not in the PoolManager, while various  
dollars are either in Morpho vaults or their  
native staking (e.g. GHO’s safety module).  

