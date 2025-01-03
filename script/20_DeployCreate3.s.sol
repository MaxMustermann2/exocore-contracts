// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

/// @title DeployCreate3
/// @author ExocoreNetwork
/// @notice This script is used to deploy the deterministic Create2 and Create3 factories to any network.
/// The Create2 factory is deployed using a raw transaction and the Create3 factory is deployed using a Create2 call.
/// @dev The advantage of using the Create3 factory over the Create2 factory for further deployments is that the
/// contract address for Create3-deployments is only dependent on the salt and the sender and not the code. This allows
/// for omni-chain deployments at the same address regardless of the contract code version that is deployed.
contract DeployCreate3 is Script {

    bytes public constant CREATE2_RAW_TRANSACTION =
    // solhint-disable-next-line
        hex"f8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222";
    address public constant CREATE2_DEPLOYER = address(0x3fAB184622Dc19b6109349B94811493BF2a45362);
    // this param is contained in the signed transaction already
    uint256 public constant CREATE2_BALANCE = 100 gwei * 100_000;
    address public constant CREATE2_DESTINATION = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    // https://github.com/ZeframLou/create3-factory
    bytes public constant CREATE3_CODE =
    // solhint-disable-next-line
        hex"608060405234801561001057600080fd5b5061063b806100206000396000f3fe6080604052600436106100295760003560e01c806350f1c4641461002e578063cdcb760a14610077575b600080fd5b34801561003a57600080fd5b5061004e610049366004610489565b61008a565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b61004e6100853660046104fd565b6100ee565b6040517fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606084901b166020820152603481018290526000906054016040516020818303038152906040528051906020012091506100e78261014c565b9392505050565b6040517fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003360601b166020820152603481018390526000906054016040516020818303038152906040528051906020012092506100e78383346102b2565b604080518082018252601081527f67363d3d37363d34f03d5260086018f30000000000000000000000000000000060209182015290517fff00000000000000000000000000000000000000000000000000000000000000918101919091527fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003060601b166021820152603581018290527f21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f60558201526000908190610228906075015b6040516020818303038152906040528051906020012090565b6040517fd69400000000000000000000000000000000000000000000000000000000000060208201527fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606083901b1660228201527f010000000000000000000000000000000000000000000000000000000000000060368201529091506100e79060370161020f565b6000806040518060400160405280601081526020017f67363d3d37363d34f03d5260086018f30000000000000000000000000000000081525090506000858251602084016000f5905073ffffffffffffffffffffffffffffffffffffffff811661037d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601160248201527f4445504c4f594d454e545f4641494c454400000000000000000000000000000060448201526064015b60405180910390fd5b6103868661014c565b925060008173ffffffffffffffffffffffffffffffffffffffff1685876040516103b091906105d6565b60006040518083038185875af1925050503d80600081146103ed576040519150601f19603f3d011682016040523d82523d6000602084013e6103f2565b606091505b50509050808015610419575073ffffffffffffffffffffffffffffffffffffffff84163b15155b61047f576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601560248201527f494e495449414c495a4154494f4e5f4641494c454400000000000000000000006044820152606401610374565b5050509392505050565b6000806040838503121561049c57600080fd5b823573ffffffffffffffffffffffffffffffffffffffff811681146104c057600080fd5b946020939093013593505050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6000806040838503121561051057600080fd5b82359150602083013567ffffffffffffffff8082111561052f57600080fd5b818501915085601f83011261054357600080fd5b813581811115610555576105556104ce565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561059b5761059b6104ce565b816040528281528860208487010111156105b457600080fd5b8260208601602083013760006020848301015280955050505050509250929050565b6000825160005b818110156105f757602081860181015185830152016105dd565b50600092019182525091905056fea2646970667358221220fd377c185926b3110b7e8a544f897646caf36a0e82b2629de851045e2a5f937764736f6c63430008100033";
    bytes32 public constant CREATE3_SALT = bytes32(0);
    address public constant CREATE3_DESTINATION = address(0x6aA3D87e99286946161dCA02B97C5806fC5eD46F);

    function setUp() public virtual {
        // do nothing
    }

    function run() public {
        vm.startBroadcast();
        // only deploy if the destination is not already deployed
        // with Anvil, pass `--disable-default-create2-deployer` to test this case
        if (CREATE2_DESTINATION.code.length == 0) {
            deployCreate2Factory();
            console.log("Deployed create2 factory");
        } else {
            console.log("Create2 factory already deployed");
        }
        // only deploy if the destination i1s not already deployed
        if (CREATE3_DESTINATION.code.length == 0) {
            deployCreate3Factory();
            console.log("Deployed create3 factory");
        } else {
            console.log("Create3 factory already deployed");
        }
        vm.stopBroadcast();
    }

    function deployCreate2Factory() public {
        // provide gas funds to the deployer
        if (CREATE2_DEPLOYER.balance < CREATE2_BALANCE) {
            payable(CREATE2_DEPLOYER).transfer(CREATE2_BALANCE);
        }
        // forge-std lib added this function in newer versions
        vm.broadcastRawTransaction(CREATE2_RAW_TRANSACTION);
    }

    function deployCreate3Factory() public {
        // any sender can deploy the create3 factory because it is deployed via create2
        // the address will be the same across all chains as long as the code and
        // the salt are the same. that is why we use a constant code instead of compilation.
        (bool success,) = CREATE2_DESTINATION.call(abi.encodePacked(CREATE3_SALT, CREATE3_CODE));
        require(success, "DeployCreate3: failed to deploy create3 factory");
    }

}
