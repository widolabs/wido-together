// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.7;

import "forge-std/Script.sol";
import "../contracts/WidoCollateralSwap.sol";

contract WidoFlashLoanScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        WidoCollateralSwap wfl = new WidoCollateralSwap(
            IERC3156FlashLender(0x4EAF187ad4cE325bF6C84070b51c2f7224A51321) // Equalizer
        );

        vm.stopBroadcast();
    }
}
