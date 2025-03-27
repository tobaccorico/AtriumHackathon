
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IPirexETH
 * @notice Interface for the PirexEth contract
 * @dev    This interface defines the methods for interacting with PirexEth.
 * @author redactedcartel.finance
 */
interface IPirexETH {

     enum Fees {
        // Fee type for deposit
        Deposit,
        // Fee type for redemption
        Redemption,
        // Fee type for instant redemption
        InstantRedemption
    }
    function fees(Fees) external view returns (uint32);

    /**
     * @notice Handle pxETH minting in return for ETH deposits.
     * @dev    This function handles the minting of pxETH in return for ETH deposits.
     * @param  receiver        address  Receiver of the minted pxETH or apxEth
     * @param  shouldCompound  bool     Whether to also compound into the vault
     * @return postFeeAmount   uint256  pxETH minted for the receiver
     * @return feeAmount       uint256  pxETH distributed as fees
     */
    function deposit(
        address receiver,
        bool shouldCompound
    ) external payable returns (uint256 postFeeAmount, uint256 feeAmount);

     /**
     * @notice Instant redeem back ETH using pxETH
     * @dev    This function burns pxETH, calculates fees, and transfers ETH to the receiver.
     * @param  _assets        uint256   Amount of pxETH to redeem.
     * @param  _receiver      address   Address of the ETH receiver.
     * @return postFeeAmount  uint256   Post-fee amount for the receiver.
     * @return feeAmount      uinit256  Fee amount sent to the PirexFees.
     */
    function instantRedeemWithPxEth(
        uint256 _assets,
        address _receiver
    ) external returns (uint256 postFeeAmount, uint256 feeAmount);
}
