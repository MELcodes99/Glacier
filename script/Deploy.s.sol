// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {CubeFactory} from "../src/CubeFactory.sol";
import {GlacierRouter} from "../src/GlacierRouter.sol";

interface IUniRouter {
    function factory() external view returns (address);
}

/// @notice Deploys Glacier on Base mainnet: registry (8 liquid stocks), factory, router.
contract Deploy is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;

    struct Stock {
        string name;
        address token;
        address feed;
        uint24 fee;
    }

    function stocks() internal pure returns (Stock[8] memory s) {
        s[0] = Stock("AAPLc",  0xb200000000000000000000C2e324d24d7eEcd1fb, 0x787f13dEa48Db0897CbCDD985de77809D837F988, 3000);
        s[1] = Stock("AMZNc",  0xb200000000000000000000d9192b6B456483C2E8, 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295, 10000);
        s[2] = Stock("GOOGLc", 0xb2000000000000000000002D0BA3164cc74f58B7, 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2, 10000);
        s[3] = Stock("METAc",  0xb2000000000000000000008bC8786B856E61707C, 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D, 3000);
        s[4] = Stock("MSFTc",  0xB200000000000000000000Ab99cFa739E253872B, 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c, 10000);
        s[5] = Stock("NVDAc",  0xb20000000000000000000078ee7ce2fE4908108C, 0x04689a41629776563E6822F76f2e57D148d28513, 3000);
        s[6] = Stock("SNDKc",  0xb200000000000000000000397293Cb8cda9a10c5, 0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA, 10000);
        s[7] = Stock("SPCXc",  0xb2000000000000000000007b9fcbd005511aCBd5, 0x6A634B235903C4ad6376892180d6fF8612e3Fa68, 10000);
    }

    function run() external {
        // Safety: the router we wire in must be Uniswap's, pointing at Uniswap's v3 factory.
        require(IUniRouter(SWAP_ROUTER_02).factory() == UNI_FACTORY, "not Uniswap SwapRouter02");

        vm.startBroadcast();
        address owner = msg.sender;

        StockRegistry registry = new StockRegistry(owner);
        CubeFactory factory = new CubeFactory(address(registry));
        GlacierRouter router = new GlacierRouter(owner, SWAP_ROUTER_02, USDC);

        Stock[8] memory s = stocks();
        for (uint256 i; i < s.length; ++i) {
            registry.setStock(s[i].token, s[i].feed);
            router.setPoolFee(s[i].token, s[i].fee);
        }
        vm.stopBroadcast();

        console.log("StockRegistry:", address(registry));
        console.log("CubeFactory:  ", address(factory));
        console.log("GlacierRouter:", address(router));
    }
}
