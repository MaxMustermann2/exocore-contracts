pragma solidity ^0.8.19;

contract GatewayStorage {

    enum Action {
        REQUEST_DEPOSIT,
        REQUEST_WITHDRAW_PRINCIPLE_FROM_EXOCORE,
        REQUEST_WITHDRAW_REWARD_FROM_EXOCORE,
        REQUEST_DELEGATE_TO,
        REQUEST_UNDELEGATE_FROM,
        REQUEST_DEPOSIT_THEN_DELEGATE_TO,
        REQUEST_MARK_BOOTSTRAP,
        RESPOND,
        UPDATE_USERS_BALANCES
    }

    mapping(Action => bytes4) public _whiteListFunctionSelectors;
    address payable public exocoreValidatorSetAddress;

    event MessageSent(Action indexed act, bytes32 packetId, uint64 nonce, uint256 nativeFee);

    error UnsupportedRequest(Action act);
    error UnexpectedSourceChain(uint32 unexpectedSrcEndpointId);
    error UnexpectedInboundNonce(uint64 expectedNonce, uint64 actualNonce);

    uint256[40] private __gap;

}
