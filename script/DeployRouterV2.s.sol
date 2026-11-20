// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GlacierRouterV2, ICLPool} from "../src/GlacierRouterV2.sol";
import {StockRegistry} from "../src/StockRegistry.sol";

/// @notice Deploys GlacierRouterV2 next to the live StockRegistry / CubeFactory and wires the
///         deepest Aerodrome CL pool for each stock. Nothing already deployed is changed.
/// Dry run:  forge script script/DeployRouterV2.s.sol --rpc-url https://mainnet.base.org --sender <owner>
/// Deploy:   add --account glacier-deployer --broadcast
contract DeployRouterV2 is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERODROME_CL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    StockRegistry constant REGISTRY = StockRegistry(0x4A68A731741C9253CA6293Dbe1b28078Ac58998b);

    function run() external {
        address[10] memory tokens = [
            0xb20000000000000000000078ee7ce2fE4908108C, // NVDAc
            0xb200000000000000000000C2e324d24d7eEcd1fb, // AAPLc
            0xB200000000000000000000Ab99cFa739E253872B, // MSFTc
            0xb2000000000000000000001e800a7f5189430cD0, // TSLAc
            0xb2000000000000000000002D0BA3164cc74f58B7, // GOOGLc
            0xb200000000000000000000d9192b6B456483C2E8, // AMZNc
            0xb2000000000000000000008bC8786B856E61707C, // METAc
            0xb2000000000000000000004884b426556b92883d, // MSTRc
            0xb2000000000000000000007b9fcbd005511aCBd5, // SPCXc
            0xb200000000000000000000397293Cb8cda9a10c5 // SNDKc
        ];
        address[10] memory pools = [
            0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC,
            0xF5FCB9CDAFcE67d50AfEf298F88E709d2B946BA6,
            0x2740C0faAb738F6e346e545fDE02aEF9B1A01ee7,
            0x7A33000372f3F028f074182CCb9d16cBEEfBF920,
            0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3,
            0x532e0F46d1e528507FC9454d5847C231f23bDDf6,
            0xd072410fa13D242e1d53721Bcf7AF02e3455DC96,
            0x66DCd42E6314B287110922AE36cB2a8bdEECc153,
            0x880dB7Dda4407D99508574E680d067D1164B3cFE,
            0x2836e062a3fe75943a7F4A552E2365b98E414E75
        ];

        vm.startBroadcast();
        GlacierRouterV2 router = new GlacierRouterV2(msg.sender, USDC);
        router.setPoolFactory(AERODROME_CL_FACTORY, true);
        for (uint256 i; i < tokens.length; ++i) {
            router.setPool(tokens[i], ICLPool(pools[i]));
        }
        vm.stopBroadcast();

        // Read-only checks: every route set, and which stocks the live registry lists.
        for (uint256 i; i < tokens.length; ++i) {
            require(router.poolOf(tokens[i]) == pools[i], "pool not set");
            console2.log(tokens[i], "pool ok | listed in registry:", REGISTRY.isListed(tokens[i]));
        }
        address[] memory listed = REGISTRY.listedTokens();
        for (uint256 i; i < listed.length; ++i) {
            if (router.poolOf(listed[i]) == address(0)) {
                console2.log("listed but NO USDC route (in-kind only):", listed[i]);
            }
        }
        console2.log("owner           ", msg.sender);
        console2.log("GlacierRouterV2 ", address(router));
    }
}
