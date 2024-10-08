pragma solidity ^0.8.19;

import "../../src/core/ExoCapsule.sol";
import "../../src/core/ExocoreGateway.sol";

import {IExoCapsule} from "../../src/interfaces/IExoCapsule.sol";
import {ILSTRestakingController} from "../../src/interfaces/ILSTRestakingController.sol";

import "../../src/storage/GatewayStorage.sol";
import "./ExocoreDeployer.t.sol";
import "forge-std/Test.sol";

import "@layerzero-v2/protocol/contracts/libs/AddressCast.sol";
import "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/GUID.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

contract DepositWithdrawPrincipalTest is ExocoreDeployer {

    using AddressCast for address;
    using stdStorage for StdStorage;

    event DepositResult(bool indexed success, bytes32 indexed token, bytes32 indexed depositor, uint256 amount);
    event WithdrawPrincipalResult(
        bool indexed success, bytes32 indexed token, bytes32 indexed withdrawer, uint256 amount
    );
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event CapsuleCreated(address owner, address capsule);
    event StakedWithCapsule(address staker, address capsule);

    uint256 constant DEFAULT_ENDPOINT_CALL_GAS_LIMIT = 200_000;
    uint64 public constant MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR = 32e9;

    function test_LSTDepositWithdrawByLayerZero() public {
        Player memory depositor = players[0];
        vm.startPrank(exocoreValidatorSet.addr);
        restakeToken.transfer(depositor.addr, 1_000_000);
        vm.stopPrank();

        // transfer some gas fee to depositor
        deal(depositor.addr, 1e22);
        // transfer some gas fee to exocore gateway as it has to pay for the relay fee to layerzero endpoint when
        // sending back response
        deal(address(exocoreGateway), 1e22);

        uint256 depositAmount = 10_000;
        uint256 withdrawAmount = 100;
        uint256 lastlyUpdatedPrincipalBalance;

        // before deposit we should add whitelist tokens
        test_AddWhitelistTokens();

        uint256 principalBalanceBefore = vault.principalBalances(depositor.addr);
        uint256 withdrawableBefore = vault.getWithdrawableBalance(depositor.addr);
        _testLSTDeposit(depositor, depositAmount, lastlyUpdatedPrincipalBalance);
        assertEq(principalBalanceBefore + depositAmount, vault.principalBalances(depositor.addr));
        assertEq(withdrawableBefore, vault.getWithdrawableBalance(depositor.addr));

        lastlyUpdatedPrincipalBalance += depositAmount;

        principalBalanceBefore = vault.principalBalances(depositor.addr);
        withdrawableBefore = vault.getWithdrawableBalance(depositor.addr);
        _testLSTWithdraw(depositor, withdrawAmount, lastlyUpdatedPrincipalBalance);

        assertEq(principalBalanceBefore - withdrawAmount, vault.principalBalances(depositor.addr));
        assertEq(withdrawableBefore + withdrawAmount, vault.getWithdrawableBalance(depositor.addr));
        _validateNonces();
    }

    function _testLSTDeposit(Player memory depositor, uint256 depositAmount, uint256 lastlyUpdatedPrincipalBalance)
        internal
    {
        // -- deposit workflow test --

        vm.startPrank(depositor.addr);
        restakeToken.approve(address(vault), type(uint256).max);

        // first user call client chain gateway to deposit

        // estimate l0 relay fee that the user should pay
        bytes memory depositRequestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            bytes32(bytes20(address(restakeToken))),
            bytes32(bytes20(depositor.addr)),
            depositAmount
        );
        uint256 depositRequestNativeFee = clientGateway.quote(depositRequestPayload);
        bytes32 depositRequestId = generateUID(outboundNonces[clientChainId], true);
        // depositor should transfer deposited token to vault
        vm.expectEmit(true, true, false, true, address(restakeToken));
        emit Transfer(depositor.addr, address(vault), depositAmount);
        // client chain layerzero endpoint should emit the message packet including deposit payload.
        vm.expectEmit(true, true, true, true, address(clientChainLzEndpoint));
        emit NewPacket(
            exocoreChainId,
            address(clientGateway),
            address(exocoreGateway).toBytes32(),
            outboundNonces[clientChainId],
            depositRequestPayload
        );
        // client chain gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            depositRequestId,
            outboundNonces[clientChainId]++,
            depositRequestNativeFee
        );
        clientGateway.deposit{value: depositRequestNativeFee}(address(restakeToken), depositAmount);

        // second layerzero relayers should watch the request message packet and relay the message to destination
        // endpoint

        // exocore gateway should return response message to exocore network layerzero endpoint
        //
        lastlyUpdatedPrincipalBalance += depositAmount;
        bytes memory depositResponsePayload = abi.encodePacked(
            GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, lastlyUpdatedPrincipalBalance
        );
        uint256 depositResponseNativeFee = exocoreGateway.quote(clientChainId, depositResponsePayload);
        bytes32 depositResponseId = generateUID(outboundNonces[exocoreChainId], false);
        vm.expectEmit(address(exocoreLzEndpoint));
        emit NewPacket(
            clientChainId,
            address(exocoreGateway),
            address(clientGateway).toBytes32(),
            outboundNonces[exocoreChainId],
            depositResponsePayload
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND, depositResponseId, outboundNonces[exocoreChainId]++, depositResponseNativeFee
        );
        vm.expectEmit(address(exocoreGateway));
        emit DepositResult(
            true, bytes32(bytes20(address(restakeToken))), bytes32(bytes20(depositor.addr)), depositAmount
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(GatewayStorage.Action.REQUEST_DEPOSIT, inboundNonces[exocoreChainId]++);
        // inboundNonces[exocoreChainId]++;
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            depositRequestId,
            depositRequestPayload,
            bytes("")
        );

        // third layerzero relayers should watch the response message packet and relay the message to source chain
        // endpoint

        // client chain gateway should execute the response hook and emit RequestFinished event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit RequestFinished(GatewayStorage.Action.REQUEST_DEPOSIT, outboundNonces[clientChainId] - 1, true);
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            depositResponseId,
            depositResponsePayload,
            bytes("")
        );
    }

    function _testLSTWithdraw(Player memory withdrawer, uint256 withdrawAmount, uint256 lastlyUpdatedPrincipalBalance)
        internal
    {
        // -- withdraw principal workflow --

        // first user call client chain gateway to withdraw

        // estimate l0 relay fee that the user should pay
        bytes memory withdrawRequestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            bytes32(bytes20(address(restakeToken))),
            bytes32(bytes20(withdrawer.addr)),
            withdrawAmount
        );
        uint256 withdrawRequestNativeFee = clientGateway.quote(withdrawRequestPayload);
        bytes32 withdrawRequestId = generateUID(outboundNonces[clientChainId], true);
        // client chain layerzero endpoint should emit the message packet including withdraw payload.
        vm.expectEmit(true, true, true, true, address(clientChainLzEndpoint));
        emit NewPacket(
            exocoreChainId,
            address(clientGateway),
            address(exocoreGateway).toBytes32(),
            outboundNonces[clientChainId],
            withdrawRequestPayload
        );
        // client chain gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            withdrawRequestId,
            outboundNonces[clientChainId]++,
            withdrawRequestNativeFee
        );
        clientGateway.withdrawPrincipalFromExocore{value: withdrawRequestNativeFee}(
            address(restakeToken), withdrawAmount
        );

        // second layerzero relayers should watch the request message packet and relay the message to destination
        // endpoint

        lastlyUpdatedPrincipalBalance -= withdrawAmount;
        bytes memory withdrawResponsePayload = abi.encodePacked(
            GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, lastlyUpdatedPrincipalBalance
        );
        uint256 withdrawResponseNativeFee = exocoreGateway.quote(clientChainId, withdrawResponsePayload);
        bytes32 withdrawResponseId = generateUID(outboundNonces[exocoreChainId], false);

        // exocore gateway should return response message to exocore network layerzero endpoint
        vm.expectEmit(true, true, true, true, address(exocoreLzEndpoint));
        emit NewPacket(
            clientChainId,
            address(exocoreGateway),
            address(clientGateway).toBytes32(),
            outboundNonces[exocoreChainId],
            withdrawResponsePayload
        );
        // exocore gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            withdrawResponseId,
            outboundNonces[exocoreChainId]++,
            withdrawResponseNativeFee
        );
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit WithdrawPrincipalResult(
            true, bytes32(bytes20(address(restakeToken))), bytes32(bytes20(withdrawer.addr)), withdrawAmount
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, inboundNonces[exocoreChainId]++
        );
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            withdrawRequestId,
            withdrawRequestPayload,
            bytes("")
        );

        // third layerzero relayers should watch the response message packet and relay the message to source chain
        // endpoint

        // client chain gateway should execute the response hook and emit RequestFinished event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit RequestFinished(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, outboundNonces[clientChainId] - 1, true
        );
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            withdrawResponseId,
            withdrawResponsePayload,
            bytes("")
        );
    }

    function test_NativeDepositWithdraw() public {
        Player memory depositor = players[0];
        Player memory relayer = players[1];

        uint256 lastlyUpdatedPrincipalBalance;

        uint256 depositAmount = uint256(_getEffectiveBalance(validatorContainer)) * GWEI_TO_WEI;
        // Cap to 32 ether
        if (depositAmount >= 32 ether) {
            depositAmount = 32 ether;
        }

        // transfer some ETH to depositor for staking and paying for gas fee
        deal(depositor.addr, 1e22);
        // transfer some gas fee to relayer for paying for onboarding cross-chain message packet
        deal(relayer.addr, 1e22);
        // transfer some gas fee to exocore gateway as it has to pay for the relay fee to layerzero endpoint when
        // sending back response
        deal(address(exocoreGateway), 1e22);

        // before deposit we should add whitelist tokens
        test_AddWhitelistTokens();

        _stakeAndPrepareCapsuleBeforeDeposit(depositor);

        uint256 principalBalanceBefore = capsule.principalBalance();
        uint256 withdrawableBefore = capsule.withdrawableBalance();
        _testNativeDeposit(depositor, relayer, lastlyUpdatedPrincipalBalance);
        assertEq(principalBalanceBefore + depositAmount, capsule.principalBalance());
        assertEq(withdrawableBefore, capsule.withdrawableBalance());

        lastlyUpdatedPrincipalBalance += 32 ether;

        // before native withdraw, we simulate proper block environment states to make proof valid
        _simulateBlockEnvironmentForNativeWithdraw();
        deal(address(capsule), 1 ether); // Deposit 1 ether to handle excess amount withdraw
        uint64 withdrawalAmountGwei = _getWithdrawalAmount(withdrawalContainer);
        uint256 withdrawalAmount;
        if (withdrawalAmountGwei > MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR) {
            withdrawalAmount = MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR * GWEI_TO_WEI;
        } else {
            withdrawalAmount = withdrawalAmountGwei * GWEI_TO_WEI;
        }

        console.log("deposit amount:", depositAmount);
        console.log("withdrawal amount:", withdrawalAmount);

        principalBalanceBefore = capsule.principalBalance();
        withdrawableBefore = capsule.withdrawableBalance();
        _testNativeWithdraw(depositor, relayer, lastlyUpdatedPrincipalBalance);
        assertEq(principalBalanceBefore - withdrawalAmount, capsule.principalBalance());
        assertEq(withdrawableBefore + withdrawalAmount, capsule.withdrawableBalance());
        _validateNonces();
    }

    function _testNativeDeposit(Player memory depositor, Player memory relayer, uint256 lastlyUpdatedPrincipalBalance)
        internal
    {
        // 1. next depositor call clientGateway.depositBeaconChainValidator to deposit into Exocore from client chain
        // through layerzero

        /// client chain layerzero endpoint should emit the message packet including deposit payload.
        uint256 depositAmount = uint256(_getEffectiveBalance(validatorContainer)) * GWEI_TO_WEI;
        // Cap to 32 ether
        if (depositAmount >= 32 ether) {
            depositAmount = 32 ether;
        }

        bytes memory depositRequestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)),
            bytes32(bytes20(depositor.addr)),
            depositAmount
        );
        uint256 depositRequestNativeFee = clientGateway.quote(depositRequestPayload);
        bytes32 depositRequestId = generateUID(outboundNonces[clientChainId], true);

        vm.expectEmit(true, true, true, true, address(clientChainLzEndpoint));
        emit NewPacket(
            exocoreChainId,
            address(clientGateway),
            address(exocoreGateway).toBytes32(),
            outboundNonces[clientChainId],
            depositRequestPayload
        );
        /// client chain gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            depositRequestId,
            outboundNonces[clientChainId]++,
            depositRequestNativeFee
        );

        /// call depositBeaconChainValidator to see if these events are emitted as expected
        vm.startPrank(depositor.addr);
        clientGateway.depositBeaconChainValidator{value: depositRequestNativeFee}(validatorContainer, validatorProof);
        vm.stopPrank();

        // 2. thirdly layerzero relayers should watch the request message packet and relay the message to destination
        // endpoint

        /// exocore gateway should return response message to exocore network layerzero endpoint
        lastlyUpdatedPrincipalBalance += depositAmount;
        bytes memory depositResponsePayload = abi.encodePacked(
            GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, lastlyUpdatedPrincipalBalance
        );
        uint256 depositResponseNativeFee = exocoreGateway.quote(clientChainId, depositResponsePayload);
        bytes32 depositResponseId = generateUID(outboundNonces[exocoreChainId], false);

        vm.expectEmit(true, true, true, true, address(exocoreLzEndpoint));
        emit NewPacket(
            clientChainId,
            address(exocoreGateway),
            address(clientGateway).toBytes32(),
            outboundNonces[exocoreChainId],
            depositResponsePayload
        );

        /// exocore gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND, depositResponseId, outboundNonces[exocoreChainId]++, depositResponseNativeFee
        );

        /// exocore gateway should emit DepositResult event
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit DepositResult(
            true, bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)), bytes32(bytes20(depositor.addr)), depositAmount
        );

        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(GatewayStorage.Action.REQUEST_DEPOSIT, inboundNonces[exocoreChainId]++);

        /// relayer catches the request message packet by listening to client chain event and feed it to Exocore network
        vm.startPrank(relayer.addr);
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            depositRequestId,
            depositRequestPayload,
            bytes("")
        );
        vm.stopPrank();

        // At last layerzero relayers should watch the response message packet and relay the message back to source
        // chain endpoint

        /// client chain gateway should execute the response hook and emit RequestFinished event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit RequestFinished(GatewayStorage.Action.REQUEST_DEPOSIT, outboundNonces[clientChainId] - 1, true);

        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);

        /// relayer catches the response message packet by listening to Exocore event and feed it to client chain
        vm.startPrank(relayer.addr);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            depositResponseId,
            depositResponsePayload,
            bytes("")
        );
        vm.stopPrank();
    }

    function _stakeAndPrepareCapsuleBeforeDeposit(Player memory depositor) internal {
        // before native stake and deposit, we simulate proper block environment states to make proof valid
        _simulateBlockEnvironmentForNativeDeposit();

        // 1. firstly depositor should stake to beacon chain by depositing 32 ETH to ETHPOS contract
        IExoCapsule expectedCapsule = IExoCapsule(
            Create2.computeAddress(
                bytes32(uint256(uint160(depositor.addr))),
                keccak256(abi.encodePacked(BEACON_PROXY_BYTECODE, abi.encode(address(capsuleBeacon), ""))),
                address(clientGateway)
            )
        );
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit CapsuleCreated(depositor.addr, address(expectedCapsule));
        vm.expectEmit(address(clientGateway));
        emit StakedWithCapsule(depositor.addr, address(expectedCapsule));

        vm.startPrank(depositor.addr);
        clientGateway.stake{value: 32 ether}(abi.encodePacked(_getPubkey(validatorContainer)), bytes(""), bytes32(0));
        vm.stopPrank();

        // do some hack to replace expectedCapsule address with capsule address loaded from proof file
        // because capsule address is expected to be compatible with validator container withdrawal credentails
        _attachCapsuleToWithdrawalCredentials(expectedCapsule, depositor);
    }

    function _simulateBlockEnvironmentForNativeDeposit() internal {
        /// we set the timestamp of proof to be exactly the timestamp that the validator container get activated on
        /// beacon chain
        activationTimestamp = BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        /// we set current block timestamp to be exactly one slot after the proof generation timestamp
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);

        /// we mock the call beaconOracle.timestampToBlockRoot to return the expected block root in proof file
        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector),
            abi.encode(beaconBlockRoot)
        );
    }

    function _attachCapsuleToWithdrawalCredentials(IExoCapsule createdCapsule, Player memory depositor) internal {
        address capsuleAddress = _getCapsuleFromWithdrawalCredentials(_getWithdrawalCredentials(validatorContainer));
        vm.etch(capsuleAddress, address(createdCapsule).code);
        capsule = ExoCapsule(payable(capsuleAddress));
        stdstore.target(capsuleAddress).sig("_beacon()").checked_write(address(capsuleBeacon));
        assertEq(stdstore.target(capsuleAddress).sig("_beacon()").read_address(), address(capsuleBeacon));

        /// replace expectedCapsule with capsule
        bytes32 capsuleSlotInGateway = bytes32(
            stdstore.target(address(clientGatewayLogic)).sig("ownerToCapsule(address)").with_key(depositor.addr).find()
        );
        vm.store(address(clientGateway), capsuleSlotInGateway, bytes32(uint256(uint160(address(capsule)))));
        assertEq(address(clientGateway.ownerToCapsule(depositor.addr)), address(capsule));

        /// initialize replaced capsule
        capsule.initialize(address(clientGateway), payable(depositor.addr), address(beaconOracle));
    }

    function _testNativeWithdraw(Player memory withdrawer, Player memory relayer, uint256 lastlyUpdatedPrincipalBalance)
        internal
    {
        // 1. withdrawer will call clientGateway.processBeaconChainWithdrawal to withdraw from Exocore thru layerzero

        /// client chain layerzero endpoint should emit the message packet including deposit payload.
        uint64 withdrawalAmountGwei = _getWithdrawalAmount(withdrawalContainer);
        uint256 withdrawalAmount;
        if (withdrawalAmountGwei > MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR) {
            withdrawalAmount = MAX_RESTAKED_BALANCE_GWEI_PER_VALIDATOR * GWEI_TO_WEI;
        } else {
            withdrawalAmount = withdrawalAmountGwei * GWEI_TO_WEI;
        }
        bytes memory withdrawRequestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)),
            bytes32(bytes20(withdrawer.addr)),
            withdrawalAmount
        );
        uint256 withdrawRequestNativeFee = clientGateway.quote(withdrawRequestPayload);
        bytes32 withdrawRequestId = generateUID(outboundNonces[clientChainId], true);

        // client chain layerzero endpoint should emit the message packet including withdraw payload.
        vm.expectEmit(true, true, true, true, address(clientChainLzEndpoint));
        emit NewPacket(
            exocoreChainId,
            address(clientGateway),
            address(exocoreGateway).toBytes32(),
            outboundNonces[clientChainId],
            withdrawRequestPayload
        );
        // client chain gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            withdrawRequestId,
            outboundNonces[clientChainId]++,
            withdrawRequestNativeFee
        );

        vm.startPrank(withdrawer.addr);
        clientGateway.processBeaconChainWithdrawal{value: withdrawRequestNativeFee}(
            validatorContainer, validatorProof, withdrawalContainer, withdrawalProof
        );
        vm.stopPrank();

        /// exocore gateway should return response message to exocore network layerzero endpoint
        lastlyUpdatedPrincipalBalance -= withdrawalAmount;
        bytes memory withdrawResponsePayload = abi.encodePacked(
            GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, lastlyUpdatedPrincipalBalance
        );
        uint256 withdrawResponseNativeFee = exocoreGateway.quote(clientChainId, withdrawResponsePayload);
        bytes32 withdrawResponseId = generateUID(outboundNonces[exocoreChainId], false);

        // exocore gateway should return response message to exocore network layerzero endpoint
        vm.expectEmit(true, true, true, true, address(exocoreLzEndpoint));
        emit NewPacket(
            clientChainId,
            address(exocoreGateway),
            address(clientGateway).toBytes32(),
            outboundNonces[exocoreChainId],
            withdrawResponsePayload
        );
        // exocore gateway should emit MessageSent event
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            withdrawResponseId,
            outboundNonces[exocoreChainId]++,
            withdrawResponseNativeFee
        );

        // exocore gateway should emit WithdrawPrincipalResult event
        vm.expectEmit(true, true, true, true, address(exocoreGateway));
        emit WithdrawPrincipalResult(
            true, bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)), bytes32(bytes20(withdrawer.addr)), withdrawalAmount
        );

        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, inboundNonces[exocoreChainId]++
        );

        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            withdrawRequestId,
            withdrawRequestPayload,
            bytes("")
        );

        // client chain gateway should execute the response hook and emit RequestFinished event
        vm.expectEmit(true, true, true, true, address(clientGateway));
        emit RequestFinished(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, outboundNonces[clientChainId] - 1, true
        );

        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);

        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            withdrawResponseId,
            withdrawResponsePayload,
            bytes("")
        );
    }

    function _simulateBlockEnvironmentForNativeWithdraw() internal {
        // load beacon chain validator container and proof from json file
        string memory withdrawalInfo = vm.readFile("test/foundry/test-data/full_withdrawal_proof.json");
        _loadValidatorContainer(withdrawalInfo);
        // load withdrawal proof
        _loadWithdrawalContainer(withdrawalInfo);

        activationTimestamp = BEACON_CHAIN_GENESIS_TIME + _getActivationEpoch(validatorContainer) * SECONDS_PER_EPOCH;
        mockProofTimestamp = activationTimestamp;
        validatorProof.beaconBlockTimestamp = mockProofTimestamp;

        /// we set current block timestamp to be exactly one slot after the proof generation timestamp
        mockCurrentBlockTimestamp = mockProofTimestamp + SECONDS_PER_SLOT;
        vm.warp(mockCurrentBlockTimestamp);

        vm.mockCall(
            address(beaconOracle),
            abi.encodeWithSelector(beaconOracle.timestampToBlockRoot.selector, validatorProof.beaconBlockTimestamp),
            abi.encode(beaconBlockRoot)
        );
    }

    function test_DepositTvlLimits() public {
        test_AddWhitelistTokens();

        address addr = players[0].addr;
        deal(addr, 1e22); // for gas
        vm.startPrank(exocoreValidatorSet.addr);
        restakeToken.transfer(addr, 1_000_000);
        vm.stopPrank();

        uint256 depositAmount = restakeToken.balanceOf(addr);
        uint256 principalBalance = 0;
        uint256 withdrawAmount = depositAmount / 4;
        uint256 consumedTvl = 0;
        assertEq(withdrawAmount * 4, depositAmount); // must be divisble by 4

        vm.startPrank(addr);
        restakeToken.approve(address(vault), type(uint256).max);
        bytes memory requestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            abi.encodePacked(bytes32(bytes20(address(restakeToken))), bytes32(bytes20(addr)), depositAmount)
        );
        bytes32 requestId = generateUID(outboundNonces[clientChainId], true);
        uint256 nativeFee = clientGateway.quote(requestPayload);
        vm.expectEmit(address(restakeToken));
        emit Transfer(addr, address(vault), depositAmount);
        vm.expectEmit(address(clientGateway));
        emit MessageSent(GatewayStorage.Action.REQUEST_DEPOSIT, requestId, outboundNonces[clientChainId]++, nativeFee);
        clientGateway.deposit{value: nativeFee}(address(restakeToken), depositAmount);
        consumedTvl += depositAmount;
        vm.stopPrank();

        // deposit succeeded on client chain
        assertTrue(vault.getConsumedTvl() == consumedTvl);

        deal(address(exocoreGateway), 1e22); // for lz fees

        // run the message on the Exocore gateway
        principalBalance += depositAmount;
        bytes memory responsePayload =
            abi.encodePacked(GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, principalBalance);
        bytes32 responseId = generateUID(outboundNonces[exocoreChainId], false);
        vm.expectEmit(address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            responseId,
            outboundNonces[exocoreChainId]++,
            exocoreGateway.quote(clientChainId, responsePayload)
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(GatewayStorage.Action.REQUEST_DEPOSIT, inboundNonces[exocoreChainId]++);
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            requestId,
            requestPayload,
            bytes("")
        );
        // given that the above transaction went through, the deposit succeeded on Exocore

        // run the response on the client chain
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            responseId,
            responsePayload,
            bytes("")
        );

        uint256 newTvlLimit = depositAmount / 2; // divisible by 4 so no need to check for 2
        vm.startPrank(exocoreValidatorSet.addr);
        // a reduction is always allowed
        clientGateway.updateTvlLimit(address(restakeToken), newTvlLimit);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // now attempt to withdraw, which should go through
        vm.startPrank(addr);
        requestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            abi.encodePacked(bytes32(bytes20(address(restakeToken))), bytes32(bytes20(addr)), withdrawAmount)
        );
        requestId = generateUID(outboundNonces[clientChainId], true);
        nativeFee = clientGateway.quote(requestPayload);
        vm.expectEmit(address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            requestId,
            outboundNonces[clientChainId]++,
            nativeFee
        );
        clientGateway.withdrawPrincipalFromExocore{value: nativeFee}(address(restakeToken), withdrawAmount);
        vm.stopPrank();

        principalBalance -= withdrawAmount;
        responsePayload =
            abi.encodePacked(GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, principalBalance);
        responseId = generateUID(outboundNonces[exocoreChainId], false);
        vm.expectEmit(address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            responseId,
            outboundNonces[exocoreChainId]++,
            exocoreGateway.quote(clientChainId, responsePayload)
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, inboundNonces[exocoreChainId]++
        );
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            requestId,
            requestPayload,
            bytes("")
        );
        // run the response on the client chain
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            responseId,
            responsePayload,
            bytes("")
        );
        vm.stopPrank();
        // until claimed, the consumed tvl does not change
        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        vm.startPrank(addr);
        vm.expectEmit(address(restakeToken));
        emit Transfer(address(vault), addr, withdrawAmount);
        clientGateway.claim(address(restakeToken), withdrawAmount, addr);
        vm.stopPrank();

        consumedTvl -= withdrawAmount;
        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // try to deposit, which will fail
        vm.startPrank(addr);
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        clientGateway.deposit(address(restakeToken), withdrawAmount);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // withdraw to get just below tvl limit
        withdrawAmount = vault.getConsumedTvl() - vault.getTvlLimit() + 1;
        principalBalance -= withdrawAmount;
        vm.startPrank(addr);
        requestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            abi.encodePacked(bytes32(bytes20(address(restakeToken))), bytes32(bytes20(addr)), withdrawAmount)
        );
        requestId = generateUID(outboundNonces[clientChainId], true);
        nativeFee = clientGateway.quote(requestPayload);
        vm.expectEmit(address(clientGateway));
        emit MessageSent(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE,
            requestId,
            outboundNonces[clientChainId]++,
            nativeFee
        );
        clientGateway.withdrawPrincipalFromExocore{value: nativeFee}(address(restakeToken), withdrawAmount);

        // obtain the response
        responsePayload =
            abi.encodePacked(GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, principalBalance);
        responseId = generateUID(outboundNonces[exocoreChainId], false);
        vm.expectEmit(address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            responseId,
            outboundNonces[exocoreChainId]++,
            exocoreGateway.quote(clientChainId, responsePayload)
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(
            GatewayStorage.Action.REQUEST_WITHDRAW_PRINCIPAL_FROM_EXOCORE, inboundNonces[exocoreChainId]++
        );
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            requestId,
            requestPayload,
            bytes("")
        );

        // execute the response
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            responseId,
            responsePayload,
            bytes("")
        );
        vm.stopPrank();

        // until claimed, the tvl limit does not change
        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // claim now
        vm.startPrank(addr);
        vm.expectEmit(address(restakeToken));
        emit Transfer(address(vault), addr, withdrawAmount);
        clientGateway.claim(address(restakeToken), withdrawAmount, addr);
        consumedTvl -= withdrawAmount;
        vm.stopPrank();

        assertTrue(consumedTvl == vault.getTvlLimit() - 1);
        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // then deposit a single unit, which should go through
        depositAmount = 1;
        vm.startPrank(addr);
        requestPayload = abi.encodePacked(
            GatewayStorage.Action.REQUEST_DEPOSIT,
            abi.encodePacked(bytes32(bytes20(address(restakeToken))), bytes32(bytes20(addr)), depositAmount)
        );
        requestId = generateUID(outboundNonces[clientChainId], true);
        nativeFee = clientGateway.quote(requestPayload);
        vm.expectEmit(address(restakeToken));
        emit Transfer(addr, address(vault), depositAmount);
        vm.expectEmit(address(clientGateway));
        emit MessageSent(GatewayStorage.Action.REQUEST_DEPOSIT, requestId, outboundNonces[clientChainId]++, nativeFee);
        clientGateway.deposit{value: nativeFee}(address(restakeToken), depositAmount);
        consumedTvl += depositAmount;
        vm.stopPrank();

        // execute the deposit request on Exocore
        principalBalance += depositAmount;
        responsePayload =
            abi.encodePacked(GatewayStorage.Action.RESPOND, outboundNonces[clientChainId] - 1, true, principalBalance);
        responseId = generateUID(outboundNonces[exocoreChainId], false);
        vm.expectEmit(address(exocoreGateway));
        emit MessageSent(
            GatewayStorage.Action.RESPOND,
            responseId,
            outboundNonces[exocoreChainId]++,
            exocoreGateway.quote(clientChainId, responsePayload)
        );
        vm.expectEmit(address(exocoreGateway));
        emit MessageExecuted(GatewayStorage.Action.REQUEST_DEPOSIT, inboundNonces[exocoreChainId]++);
        exocoreLzEndpoint.lzReceive(
            Origin(clientChainId, address(clientGateway).toBytes32(), inboundNonces[exocoreChainId] - 1),
            address(exocoreGateway),
            requestId,
            requestPayload,
            bytes("")
        );

        // handle the response on the client chain
        vm.expectEmit(address(clientGateway));
        emit MessageExecuted(GatewayStorage.Action.RESPOND, inboundNonces[clientChainId]++);
        clientChainLzEndpoint.lzReceive(
            Origin(exocoreChainId, address(exocoreGateway).toBytes32(), inboundNonces[clientChainId] - 1),
            address(clientGateway),
            responseId,
            responsePayload,
            bytes("")
        );

        assertTrue(vault.getConsumedTvl() == consumedTvl);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        // no more deposits should be allowed
        vm.startPrank(addr);
        vm.expectRevert(Errors.VaultTvlLimitExceeded.selector);
        // no need to provide fee here because it will fail before the fee check
        clientGateway.deposit(address(restakeToken), 1);
        vm.stopPrank();

        assertTrue(vault.getConsumedTvl() == newTvlLimit);
        assertTrue(vault.getTvlLimit() == newTvlLimit);

        _validateNonces();
    }

}
