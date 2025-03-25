// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.4 <0.9.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract mockToken is ERC20 {
    address public router;
    modifier onlyRouter {
        require(msg.sender == address(router), "403"); _;
    }
    constructor(address _router, uint8 _decimals) 
        ERC20("mock", "mock", _decimals) {
        router = _router;
    }
    function mint(uint amount) onlyRouter external {
        _mint(msg.sender, amount);
    }
    function burn(uint amount) onlyRouter external {
        _burn(msg.sender, amount);   
    }
}
