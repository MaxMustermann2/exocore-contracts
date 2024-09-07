pragma solidity ^0.8.19;

import {GatewayStorage} from "../src/storage/GatewayStorage.sol";

import "../src/interfaces/IClientChainGateway.sol";
import "../src/interfaces/IExocoreGateway.sol";
import "../src/interfaces/IVault.sol";

import {NonShortCircuitEndpointV2Mock} from "../test/mocks/NonShortCircuitEndpointV2Mock.sol";

import {BaseScript} from "./BaseScript.sol";
import "@layerzero-v2/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "@layerzero-v2/protocol/contracts/libs/AddressCast.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "forge-std/Script.sol";

contract SetupScript is BaseScript {

    using AddressCast for address;

    function setUp() public virtual override {
        super.setUp();

        string memory deployedContracts = vm.readFile("script/deployedContracts.json");

        clientGateway =
            IClientChainGateway(payable(stdJson.readAddress(deployedContracts, ".clientChain.clientChainGateway")));
        require(address(clientGateway) != address(0), "clientGateway address should not be empty");

        clientChainLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(deployedContracts, ".clientChain.lzEndpoint"));
        require(address(clientChainLzEndpoint) != address(0), "clientChainLzEndpoint address should not be empty");

        restakeToken = ERC20PresetFixedSupply(stdJson.readAddress(deployedContracts, ".clientChain.erc20Token"));
        require(address(restakeToken) != address(0), "restakeToken address should not be empty");

        vault = IVault(stdJson.readAddress(deployedContracts, ".clientChain.resVault"));
        require(address(vault) != address(0), "vault address should not be empty");

        exocoreGateway = IExocoreGateway(payable(stdJson.readAddress(deployedContracts, ".exocore.exocoreGateway")));
        require(address(exocoreGateway) != address(0), "exocoreGateway address should not be empty");

        exocoreLzEndpoint = ILayerZeroEndpointV2(stdJson.readAddress(deployedContracts, ".exocore.lzEndpoint"));
        require(address(exocoreLzEndpoint) != address(0), "exocoreLzEndpoint address should not be empty");

        if (!useExocorePrecompileMock) {
            _bindPrecompileMocks();
        }

        // transfer some gas fee to contract owner
        clientChain = vm.createSelectFork(clientChainRPCURL);
        _topUpPlayer(clientChain, address(0), deployer, exocoreValidatorSet.addr, 0.2 ether);

        exocore = vm.createSelectFork(exocoreRPCURL);
        _topUpPlayer(exocore, address(0), exocoreGenesis, exocoreValidatorSet.addr, 0.2 ether);
    }

    function run() public {
        // 1. setup client chain contracts to make them ready for sending and receiving messages from exocore gateway

        vm.selectFork(clientChain);
        // Set owner of these contracts and only owner could setup contracts state
        vm.startBroadcast(exocoreValidatorSet.privateKey);
        // set the destination endpoint for corresponding destinations in endpoint mock if USE_ENDPOINT_MOCK is true
        if (useEndpointMock) {
            NonShortCircuitEndpointV2Mock(address(clientChainLzEndpoint)).setDestLzEndpoint(
                address(exocoreGateway), address(exocoreLzEndpoint)
            );
        }

        // as LzReceivers, client chain gateway should set exocoreGateway as trusted remote to receive messages from it
        clientGateway.setPeer(exocoreChainId, address(exocoreGateway).toBytes32());
        vm.stopBroadcast();

        // 2. setup Exocore contracts to make them ready for sending and receiving messages from client chain
        // gateway, and register client chain meta data to Exocore native module

        vm.selectFork(exocore);
        // Set the owner of these contracts and only owner could setup contracts state
        vm.startBroadcast(exocoreValidatorSet.privateKey);
        // set the destination endpoint for corresponding destinations in endpoint mock if USE_ENDPOINT_MOCK is true
        if (useEndpointMock) {
            NonShortCircuitEndpointV2Mock(address(exocoreLzEndpoint)).setDestLzEndpoint(
                address(clientGateway), address(clientChainLzEndpoint)
            );
        }
        // register clientChainId to Exocore native module and set peer for client chain gateway to be ready for
        // messaging
        exocoreGateway.registerOrUpdateClientChain(
            clientChainId, address(clientGateway).toBytes32(), 20, "ClientChain", "EVM compatible network", "secp256k1"
        );

        // 3. adding tokens to the whtielist of both Exocore and client chain gateway to enable restaking

        // first we read decimals from client chain ERC20 token contract to prepare for token data
        bytes32[] memory whitelistTokensBytes32 = new bytes32[](2);
        uint8[] memory decimals = new uint8[](2);
        uint256[] memory supplies = new uint256[](2);
        string[] memory names = new string[](2);
        string[] memory metaDatas = new string[](2);
        string[] memory oracleInfos = new string[](2);
        uint256[] memory tvlLimits = new uint256[](2);

        // this stands for LST restaking for restakeToken
        whitelistTokensBytes32[0] = bytes32(bytes20(address(restakeToken)));
        decimals[0] = restakeToken.decimals();
        supplies[0] = restakeToken.totalSupply();
        names[0] = "RestakeToken";
        metaDatas[0] = "ERC20 LST token";
        oracleInfos[0] = "{'a': 'b'}";
        tvlLimits[0] = supplies[0] / 5; // in phases of 20%

        // this stands for Native Restaking for ETH
        whitelistTokensBytes32[1] = bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS));
        decimals[1] = 18;
        supplies[1] = 0; // irrelevant for native restaking
        names[1] = "StakedETH";
        metaDatas[1] = "natively staked ETH on Ethereum";
        oracleInfos[1] = "{'b': 'a'}";
        tvlLimits[1] = 0; // irrelevant for native restaking

        // second add whitelist tokens and their meta data on Exocore side to enable LST Restaking and Native Restaking,
        // and this would also add token addresses to client chain gateway's whitelist
        uint256 nativeFee;
        for (uint256 i = 0; i < whitelistTokensBytes32.length; i++) {
            nativeFee = exocoreGateway.quote(
                clientChainId,
                abi.encodePacked(
                    GatewayStorage.Action.REQUEST_ADD_WHITELIST_TOKEN, abi.encodePacked(whitelistTokensBytes32[i])
                )
            );
            exocoreGateway.addWhitelistToken{value: nativeFee}(
                clientChainId,
                whitelistTokensBytes32[i],
                decimals[i],
                supplies[i],
                names[i],
                metaDatas[i],
                oracleInfos[i],
                tvlLimits[i]
            );
        }
        vm.stopBroadcast();
    }

}
