pragma solidity ^0.4.17;

import "./Token.sol";
import "./lib/ECVerify.sol";

/// @title Raiden MicroTransfer Channels Contract.
contract RaidenMicroTransferChannels {

    /*
     *  Data structures
     */

    address public owner_address;
    address public token_address;
    uint8 public challenge_period;

    // Contract semantic version
    string public constant version = '1.0.0';

    // Address of the latest deployed version of the contract. This is set
    // by the owner during a new contract deployment for all outdated contracts.
    // Outdated contracts can still be used.
    address public latest_version_address;

    string constant prefix = "\x19Ethereum Signed Message:\n";

    Token token;

    mapping (bytes32 => Channel) channels;
    mapping (bytes32 => ClosingRequest) closing_requests;

    // 28 (deposit) + 4 (block no settlement)
    struct Channel {
        // uint192 is the maximum uint size needed for deposit based on a
        // 10^8 * 10^18 token totalSupply.
        uint192 deposit;

        // Used in creating a unique identifier for the channel between a sender and receiver.
        // Supports creation of multiple channels between the 2 parties and prevents
        // replay of messages in later channels.
        uint32 open_block_number;
    }

    struct ClosingRequest {
        uint32 settle_block_number;
        uint192 closing_balance;
    }

    /*
     *  Modifiers
     */

    modifier isToken() {
        require(msg.sender == token_address);
        _;
    }

    modifier isOwner() {
        require(msg.sender == owner_address);
        _;
    }

    /*
     *  Events
     */

    event ChannelCreated(
        address indexed _sender,
        address indexed _receiver,
        uint192 _deposit);
    event ChannelToppedUp (
        address indexed _sender,
        address indexed _receiver,
        uint32 indexed _open_block_number,
        uint192 _added_deposit,
        uint192 _deposit);
    event ChannelCloseRequested(
        address indexed _sender,
        address indexed _receiver,
        uint32 indexed _open_block_number,
        uint192 _balance);
    event ChannelSettled(
        address indexed _sender,
        address indexed _receiver,
        uint32 indexed _open_block_number,
        uint192 _balance);


    /*
     *  Constructor
     */

    /// @dev Constructor for creating the uRaiden microtransfer channels contract.
    /// @param _token_address The address of the Token used by the uRaiden contract.
    /// @param _challenge_period A fixed number of blocks representing the challenge period
    /// after a sender requests the closing of the channel without the receiver's signature.
    function RaidenMicroTransferChannels(address _token_address, uint8 _challenge_period) public {
        require(_token_address != 0x0);
        require(addressHasCode(_token_address));
        require(_challenge_period > 0);

        owner_address = msg.sender;
        token_address = _token_address;
        token = Token(_token_address);

        challenge_period = _challenge_period;
    }

    /// @dev Sets the address for the latest contract version
    /// @param _latest_version_address The address for the latest contract version.
    function setLatestVersionAddress(address _latest_version_address) public isOwner {
        require(addressHasCode(_latest_version_address));
        latest_version_address = _latest_version_address;
    }

    /*
     *  Public helper functions (constant)
     */
    /// @dev Returns the unique channel identifier used in the contract.
    /// @param _sender_address The address that sends tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @return Unique channel identifier.
    function getKey(
        address _sender_address,
        address _receiver_address,
        uint32 _open_block_number)
        public
        pure
        returns (bytes32 data)
    {
        return keccak256(_sender_address, _receiver_address, _open_block_number);
    }

    /// @dev Returns a hash of the balance message needed to be signed by the sender.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    /// @return Hash of the balance message.
    function getBalanceMessage(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance)
        public
        pure
        returns (string)
    {
        string memory str = concat("Receiver: 0x", addressToString(_receiver_address));
        str = concat(str, ", Balance: ");
        str = concat(str, uintToString(uint256(_balance)));
        str = concat(str, ", Channel ID: ");
        str = concat(str, uintToString(uint256(_open_block_number)));
        return str;
    }

    /*
     *  Temporary implementation of verifyBalanceProof.
     *  Message string reproduction is a workaround
     *  until https://github.com/ethereum/EIPs/pull/712 is implemented.
     *  Reason: offer the sender security that the Dapp sends the same balance as in
     *  the signed message
     */

    /// @dev Returns the sender address extracted from the balance proof.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    /// @param _balance_msg_sig The balance message signed by the sender.
    /// @return Address of the balance proof signer.
    function verifyBalanceProof(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance,
        bytes _balance_msg_sig)
        public
        constant
        returns (address)
    {
        // Create message which should be signed by sender
        string memory message = getBalanceMessage(_receiver_address, _open_block_number, _balance);
        uint message_length = bytes(message).length;
        string memory message_length_string = uintToString(message_length);

        // Prefix the message
        string memory prefixed_message = concat(prefix, message_length_string);
        prefixed_message = concat(prefixed_message, message);


        // Hash the prefixed message string
        bytes32 prefixed_message_hash = keccak256(prefixed_message);

        // Derive address from signature
        address signer = ECVerify.ecverify(prefixed_message_hash, _balance_msg_sig);
        return signer;
    }

    /*
     *  External functions
     */

    /// @dev Opens a new channel or tops up an existing one, compatibility with ERC 223;
    /// msg.sender is Token contract.
    /// @param _sender_address The address that sends the tokens.
    /// @param _deposit The amount of tokens that the sender escrows.
    /// @param _data Receiver address in bytes.
    function tokenFallback(address _sender_address, uint256 _deposit, bytes _data) external {
        // Make sure we trust the token
        require(msg.sender == token_address);
        uint length = _data.length;

        // createChannel - receiver address (20 bytes + padding = 32 bytes)
        // topUp - receiver address (32 bytes) + open_block_number (4 bytes + padding = 32 bytes)
        require(length == 20 || length == 24);

        address receiver = addressFromData(_data);

        if(length == 20) {
            createChannelPrivate(_sender_address, receiver, uint192(_deposit));
        } else {
            uint32 open_block_number = blockNumberFromData(_data);
            topUpPrivate(_sender_address, receiver, open_block_number, uint192(_deposit));
        }
    }

    /// @dev Creates a new channel between a sender and a receiver and transfers
    /// the sender's token deposit to this contract, compatibility with ERC20 tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _deposit The amount of tokens that the sender escrows.
    function createChannelERC20(address _receiver_address, uint192 _deposit) external {
        createChannelPrivate(msg.sender, _receiver_address, _deposit);

        // transferFrom deposit from sender to contract
        // ! needs prior approval from user
        require(token.transferFrom(msg.sender, address(this), _deposit));
    }

    /// @dev Increase the sender's current deposit.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _added_deposit The added token deposit with which the current deposit is increased.
    function topUpERC20(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _added_deposit)
        external
    {
        // transferFrom deposit from msg.sender to contract
        // ! needs prior approval from user
        require(token.transferFrom(msg.sender, address(this), _added_deposit));
        topUpPrivate(msg.sender, _receiver_address, _open_block_number, _added_deposit);
    }

    /// @dev Function called when any of the parties wants to close the channel and settle;
    /// receiver needs a balance proof to immediately settle, sender triggers a challenge period.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    /// @param _balance_msg_sig The balance message signed by the sender.
    function uncooperativeClose(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance,
        bytes _balance_msg_sig)
        external
    {
        require(_balance_msg_sig.length == 65);
        address sender = verifyBalanceProof(_receiver_address, _open_block_number, _balance, _balance_msg_sig);

        if(msg.sender == _receiver_address) {
            settleChannel(sender, _receiver_address, _open_block_number, _balance);
        } else {
            require(msg.sender == sender);
            initChallengePeriod(_receiver_address, _open_block_number, _balance);
        }
    }

    /// @dev Function called by the sender, when he has a closing signature from the receiver;
    /// channel is closed immediately.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    /// @param _balance_msg_sig The balance message signed by the sender.
    /// @param _closing_sig The hash of the signed balance message, signed by the receiver.
    function cooperativeClose(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance,
        bytes _balance_msg_sig,
        bytes _closing_sig)
        external
    {
        require(_balance_msg_sig.length == 65);
        require(_closing_sig.length == 65);

        // Derive address from signature
        address receiver = verifyBalanceProof(_receiver_address, _open_block_number, _balance, _closing_sig);
        require(receiver == _receiver_address);

        address sender = verifyBalanceProof(_receiver_address, _open_block_number, _balance, _balance_msg_sig);
        require(msg.sender == sender);
        settleChannel(sender, receiver, _open_block_number, _balance);
    }

    /// @dev Function for getting information about a channel.
    /// @param _sender_address The address that sends tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @return Channel information (unique_identifier, deposit, settle_block_number, closing_balance).
    function getChannelInfo(
        address _sender_address,
        address _receiver_address,
        uint32 _open_block_number)
        external
        constant
        returns (bytes32, uint192, uint32, uint192)
    {
        bytes32 key = getKey(_sender_address, _receiver_address, _open_block_number);
        require(channels[key].open_block_number > 0);

        return (
            key, channels[key].deposit,
            closing_requests[key].settle_block_number,
            closing_requests[key].closing_balance
        );
    }

    /// @dev Function called by the sender after the challenge period has ended,
    /// in case the receiver has not closed the channel.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between
    /// the sender and receiver was created.
    function settle(address _receiver_address, uint32 _open_block_number) external {
        bytes32 key = getKey(msg.sender, _receiver_address, _open_block_number);

        // Make sure an uncooperativeClose has been initiated
        require(closing_requests[key].settle_block_number > 0);

        // Make sure the challenge_period has ended
	    require(block.number > closing_requests[key].settle_block_number);

        settleChannel(msg.sender, _receiver_address, _open_block_number,
            closing_requests[key].closing_balance
        );
    }

    /*
     *  Private functions
     */

    /// @dev Creates a new channel between a sender and a receiver,
    /// only callable by the Token contract.
    /// @param _sender_address The address that sends tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _deposit The amount of tokens that the sender escrows.
    function createChannelPrivate(address _sender_address, address _receiver_address, uint192 _deposit) private {
        uint32 open_block_number = uint32(block.number);

        // Create unique identifier from sender, receiver and current block number
        bytes32 key = getKey(_sender_address, _receiver_address, open_block_number);

        require(channels[key].deposit == 0);
        require(channels[key].open_block_number == 0);
        require(closing_requests[key].settle_block_number == 0);

        // Store channel information
        channels[key] = Channel({deposit: _deposit, open_block_number: open_block_number});
        ChannelCreated(_sender_address, _receiver_address, _deposit);
    }

    /// @dev Funds channel with an additional deposit of tokens, only callable by the Token contract.
    /// @param _sender_address The address that sends tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _added_deposit The added token deposit with which the current deposit is increased.
    function topUpPrivate(
        address _sender_address,
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _added_deposit)
        private
    {
        require(_added_deposit > 0);
        require(_open_block_number > 0);

        bytes32 key = getKey(_sender_address, _receiver_address, _open_block_number);

        require(channels[key].deposit > 0);
        require(closing_requests[key].settle_block_number == 0);

        channels[key].deposit += _added_deposit;
        assert(channels[key].deposit > _added_deposit);
        ChannelToppedUp(_sender_address, _receiver_address, _open_block_number, _added_deposit, channels[key].deposit);
    }


    /// @dev Sender starts the challenge period; this can only happen once.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between
    /// the sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    function initChallengePeriod(
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance)
        private
    {
        bytes32 key = getKey(msg.sender, _receiver_address, _open_block_number);

        require(closing_requests[key].settle_block_number == 0);
        require(_balance <= channels[key].deposit);

        // Mark channel as closed
        closing_requests[key].settle_block_number = uint32(block.number) + challenge_period;
        closing_requests[key].closing_balance = _balance;
        ChannelCloseRequested(msg.sender, _receiver_address, _open_block_number, _balance);
    }

    /// @dev Deletes the channel and settles by transfering the balance to the receiver
    /// and the rest of the deposit back to the sender.
    /// @param _sender_address The address that sends tokens.
    /// @param _receiver_address The address that receives tokens.
    /// @param _open_block_number The block number at which a channel between the
    /// sender and receiver was created.
    /// @param _balance The amount of tokens owed by the sender to the receiver.
    function settleChannel(
        address _sender_address,
        address _receiver_address,
        uint32 _open_block_number,
        uint192 _balance)
        private
    {
        bytes32 key = getKey(_sender_address, _receiver_address, _open_block_number);
        Channel memory channel = channels[key];

        require(channel.open_block_number > 0);
        require(_balance <= channel.deposit);

        // Send _balance to the receiver, as it is always <= deposit
        require(token.transfer(_receiver_address, _balance));

        // Send deposit - balance back to sender
        require(token.transfer(_sender_address, channel.deposit - _balance));

        // remove closed channel structures
        delete channels[key];
        delete closing_requests[key];

        ChannelSettled(_sender_address, _receiver_address, _open_block_number, _balance);
    }

    /*
     *  Internal functions
     */

    /// @dev Internal function for getting an address from tokenFallback data bytes.
    /// @param b Bytes received.
    /// @return Address resulted.
    function addressFromData (bytes b) internal pure returns (address) {
        bytes20 addr;
        assembly {
            // Read address bytes
            // Offset of 32 bytes, representing b.length
            addr := mload(add(b, 0x20))
        }
        return address(addr);
    }

    /// @dev Internal function for getting the block number from tokenFallback data bytes.
    /// @param b Bytes received.
    /// @return Block number.
    function blockNumberFromData(bytes b) internal pure returns (uint32) {
        bytes4 block_number;
        assembly {
            // Read block number bytes
            // Offset of 32 bytes (b.length) + 20 bytes (address)
            block_number := mload(add(b, 0x34))
        }
        return uint32(block_number);
    }

    /// @notice Check if a contract exists
    /// @param _contract The address of the contract to check for.
    /// @return True if a contract exists, false otherwise
    function addressHasCode(address _contract) internal constant returns (bool) {
        uint size;
        assembly {
            size := extcodesize(_contract)
        }

        return size > 0;
    }

    /*
     *  Temporary functions.
     *  Workaround until https://github.com/ethereum/EIPs/pull/712 is done.
     *  We use these for verifyBalanceProof.
     */

    function memcpy(uint dest, uint src, uint len) private pure {
        // Copy word-length chunks while possible
        for(; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            dest += 32;
            src += 32;
        }

        // Copy remaining bytes
        uint mask = 256 ** (32 - len) - 1;
        assembly {
            let srcpart := and(mload(src), not(mask))
            let destpart := and(mload(dest), mask)
            mstore(dest, or(destpart, srcpart))
        }
    }

    function concat(string _self, string _other) internal pure returns (string)
    {
        uint self_len = bytes(_self).length;
        uint other_len = bytes(_other).length;
        uint self_ptr;
        uint other_ptr;

        assembly {
            self_ptr := add(_self, 0x20)
            other_ptr := add(_other, 0x20)
        }

        var ret = new string(self_len + other_len);
        uint retptr;
        assembly { retptr := add(ret, 32) }
        memcpy(retptr, self_ptr, self_len);
        memcpy(retptr + self_len, other_ptr, other_len);
        return ret;
    }

    function uintToString(uint v) internal pure returns (string) {
        bytes32 ret;
        if (v == 0) {
            ret = '0';
        } else {
             while (v > 0) {
                ret = bytes32(uint(ret) / (2 ** 8));
                ret |= bytes32(((v % 10) + 48) * 2 ** (8 * 31));
                v /= 10;
            }
        }

        bytes memory bytesString = new bytes(32);
        uint charCount = 0;
        for (uint j=0; j<32; j++) {
            byte char = byte(bytes32(uint(ret) * 2 ** (8 * j)));
            if (char != 0) {
                bytesString[j] = char;
                charCount++;
            }
        }
        bytes memory bytesStringTrimmed = new bytes(charCount);
        for (j = 0; j < charCount; j++) {
            bytesStringTrimmed[j] = bytesString[j];
        }

        return string(bytesStringTrimmed);
    }

    function addressToString(address account_address) internal pure returns (string) {
        bytes memory str = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            byte b = byte(uint8(uint(account_address) / (2**(8*(19 - i)))));
            byte hi = byte(uint8(b) / 16);
            byte lo = byte(uint8(b) - 16 * uint8(hi));
            str[2*i] = char(hi);
            str[2*i+1] = char(lo);
        }
        return string(str);
    }

    function char(byte b) internal pure returns (byte c) {
        if (b < 10) {
            return byte(uint8(b) + 0x30);
        } else {
            return byte(uint8(b) + 0x57);
        }
    }
}
