// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MnemoVault
/// @notice Stores sealed (client-side encrypted) notes as events, burns a MNEMO stamp per note,
///         tracks each wallet's key epoch and records which agent wallets a vault owner has granted
///         access to. The contract never sees plaintext or keys: every `bytes` it receives is
///         ciphertext produced in the user's browser.
///
/// Roles
/// - Anyone holding MNEMO writes notes to their own vault with `write`.
/// - A vault owner forgets their own notes with `forget`, rotates their epoch with `rotate`, and
///   grants or revokes agent wallets with `grant` and `revoke`. `revoke` also rotates the epoch.
/// - A granted agent writes notes into the granting owner's vault with `writeFor`, paying the stamp
///   from the agent's own MNEMO.
/// - Anyone publishes an x25519 public key with `register` so vault owners can seal keys to it.
/// - The launch owner (Ownable2Step, renounce disabled) may only change the stamp within
///   [MIN_STAMP, MAX_STAMP]. There is no pause, no upgrade and no other power.
///
/// @dev The constructor makes no external calls so the launch's empty-chain checks can run it; the
///      token is checked on first use (the first stamp burn).
contract MnemoVault is Ownable2Step {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Where every stamp is sent. Nothing can move tokens out of it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Stamp charged per note at launch: 2,000 MNEMO.
    uint256 public constant INITIAL_STAMP = 2_000 * 1e18;

    /// @notice Lowest stamp the owner may set: 100 MNEMO per note.
    uint256 public constant MIN_STAMP = 100 * 1e18;

    /// @notice Highest stamp the owner may set: 100,000 MNEMO per note.
    uint256 public constant MAX_STAMP = 100_000 * 1e18;

    /// @notice Longest ciphertext accepted for one note, in bytes.
    uint256 public constant MAX_NOTE_BYTES = 2_048;

    /// @notice Most notes accepted in one `write` or `writeFor` call.
    uint256 public constant MAX_NOTES_PER_CALL = 16;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The MNEMO token burned as the stamp.
    IERC20 public immutable token;

    /// @notice Current stamp per note, in MNEMO minor units. Applies to future writes only.
    uint256 public stamp;

    /// @notice Number of notes ever sealed; also the last note id issued (ids start at 1).
    uint256 public notesTotal;

    /// @notice Total MNEMO sent to BURN_ADDRESS by this contract.
    uint256 public burnedTotal;

    /// @dev Current key epoch per vault owner.
    mapping(address owner => uint32 epoch) private _epochOf;

    /// @dev Vault owner of each live note id; zero once forgotten or never issued.
    mapping(uint256 id => address owner) private _noteOwner;

    /// @dev Agent wallets granted access per vault owner.
    mapping(address owner => mapping(address agent => bool granted)) private _granted;

    /// @dev Registered x25519 public key per account; zero when unregistered.
    mapping(address account => bytes32 key) private _keyOf;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Noted(address indexed owner, uint256 indexed id, uint32 epoch, bytes ciphertext);
    event Forgotten(address indexed owner, uint256 indexed id);
    event Rotated(address indexed owner, uint32 epoch);
    event Granted(address indexed owner, address indexed agent, uint32 epoch, bytes sealedKey);
    event Revoked(address indexed owner, address indexed agent);
    event KeyRegistered(address indexed account, bytes32 key);
    event StampChanged(uint256 oldStamp, uint256 newStamp);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error NoNotes();
    error TooManyNotes(uint256 count);
    error NoteTooLong(uint256 index, uint256 length);
    error EmptyNote(uint256 index);
    error WrongEpoch(uint32 expected, uint32 given);
    error NotNoteOwner(uint256 id);
    error NotGranted(address owner, address agent);
    error AgentNotRegistered(address agent);
    error SelfGrant();
    error EmptySealedKey();
    error ZeroKey();
    error StampOutOfRange(uint256 stamp_);
    error RenounceDisabled();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param token_ The MNEMO token (the launch token).
    /// @param owner_ The launch owner, who may call `setStamp` only.
    constructor(address token_, address owner_) Ownable(owner_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        stamp = INITIAL_STAMP;
        emit StampChanged(0, INITIAL_STAMP);
    }

    // ---------------------------------------------------------------------------------------------
    // Notes
    // ---------------------------------------------------------------------------------------------

    /// @notice Seal notes into the caller's own vault, burning `stamp` MNEMO per note from the caller.
    /// @param notes  Ciphertexts, 1 to 16 of them, each 1 to 2,048 bytes.
    /// @param epoch  Must equal the caller's current epoch.
    /// @return firstId The id of the first note sealed; the rest follow consecutively.
    function write(bytes[] calldata notes, uint32 epoch) external returns (uint256 firstId) {
        return _write(msg.sender, msg.sender, notes, epoch);
    }

    /// @notice Seal notes into `owner`'s vault as a granted agent, burning the stamp from the agent.
    /// @param owner  The vault owner who granted the caller.
    /// @param notes  Ciphertexts, 1 to 16 of them, each 1 to 2,048 bytes.
    /// @param epoch  Must equal `owner`'s current epoch.
    /// @return firstId The id of the first note sealed; the rest follow consecutively.
    function writeFor(address owner, bytes[] calldata notes, uint32 epoch) external returns (uint256 firstId) {
        if (!_granted[owner][msg.sender]) revert NotGranted(owner, msg.sender);
        return _write(owner, msg.sender, notes, epoch);
    }

    /// @notice Mark the caller's notes as forgotten. The ciphertext already emitted stays on chain;
    ///         clients drop the note and a forgotten id can never be forgotten again.
    /// @param ids Note ids, each live and owned by the caller.
    function forget(uint256[] calldata ids) external {
        uint256 count = ids.length;
        if (count == 0) revert NoNotes();
        for (uint256 i; i < count; ++i) {
            uint256 id = ids[i];
            if (_noteOwner[id] != msg.sender) revert NotNoteOwner(id);
            delete _noteOwner[id];
            emit Forgotten(msg.sender, id);
        }
    }

    /// @notice Advance the caller's key epoch. Later notes are sealed under the new epoch's key, so
    ///         anyone holding only an older sealed key cannot read them. Grants are untouched: the
    ///         owner hands each agent it keeps the new epoch's key by calling `grant` again.
    function rotate() external {
        _rotate(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Agents
    // ---------------------------------------------------------------------------------------------

    /// @notice Publish the caller's x25519 public key so vault owners can seal their key to it.
    ///         Calling again replaces the key.
    function register(bytes32 x25519PublicKey) external {
        if (x25519PublicKey == bytes32(0)) revert ZeroKey();
        _keyOf[msg.sender] = x25519PublicKey;
        emit KeyRegistered(msg.sender, x25519PublicKey);
    }

    /// @notice Grant `agent` write access to the caller's vault. `sealedKey` is the caller's current
    ///         vault key sealed to the agent's registered x25519 key; the contract only relays it.
    ///         Calling it again for an agent that is already granted re-seals: the grant stays, the
    ///         epoch does not move, and `Granted` carries the key for the caller's current epoch. This is
    ///         how an owner re-keys the agents it keeps after `rotate` or after revoking another agent.
    function grant(address agent, bytes calldata sealedKey) external {
        if (agent == address(0)) revert ZeroAddress();
        if (agent == msg.sender) revert SelfGrant();
        if (_keyOf[agent] == bytes32(0)) revert AgentNotRegistered(agent);
        if (sealedKey.length == 0) revert EmptySealedKey();
        _granted[msg.sender][agent] = true;
        emit Granted(msg.sender, agent, _epochOf[msg.sender], sealedKey);
    }

    /// @notice Revoke `agent`'s access to the caller's vault and rotate the caller's epoch, so the
    ///         key the agent held no longer reads anything sealed from now on.
    function revoke(address agent) external {
        if (!_granted[msg.sender][agent]) revert NotGranted(msg.sender, agent);
        _granted[msg.sender][agent] = false;
        emit Revoked(msg.sender, agent);
        _rotate(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Set the stamp charged per note for future writes. Only within [MIN_STAMP, MAX_STAMP].
    function setStamp(uint256 newStamp) external onlyOwner {
        if (newStamp < MIN_STAMP || newStamp > MAX_STAMP) revert StampOutOfRange(newStamp);
        uint256 old = stamp;
        stamp = newStamp;
        emit StampChanged(old, newStamp);
    }

    /// @notice Disabled: the vault always has an owner who can adjust the stamp.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Current key epoch of `owner`'s vault (0 until first rotation).
    function epochOf(address owner) external view returns (uint32) {
        return _epochOf[owner];
    }

    /// @notice Whether `agent` may currently write into `owner`'s vault.
    function isGranted(address owner, address agent) external view returns (bool) {
        return _granted[owner][agent];
    }

    /// @notice Registered x25519 public key of `account`, or zero if none.
    function keyOf(address account) external view returns (bytes32) {
        return _keyOf[account];
    }

    /// @notice Vault owner of a live note id; zero if never issued or forgotten.
    function noteOwnerOf(uint256 id) external view returns (address) {
        return _noteOwner[id];
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _write(address owner, address payer, bytes[] calldata notes, uint32 epoch)
        private
        returns (uint256 firstId)
    {
        uint256 count = notes.length;
        if (count == 0) revert NoNotes();
        if (count > MAX_NOTES_PER_CALL) revert TooManyNotes(count);
        uint32 current = _epochOf[owner];
        if (epoch != current) revert WrongEpoch(current, epoch);

        uint256 id = notesTotal;
        firstId = id + 1;
        for (uint256 i; i < count; ++i) {
            uint256 len = notes[i].length;
            if (len == 0) revert EmptyNote(i);
            if (len > MAX_NOTE_BYTES) revert NoteTooLong(i, len);
            ++id;
            _noteOwner[id] = owner;
            emit Noted(owner, id, current, notes[i]);
        }
        notesTotal = id;

        uint256 cost = stamp * count;
        burnedTotal += cost;
        // External call last: all state above is final before the token is touched.
        token.safeTransferFrom(payer, BURN_ADDRESS, cost);
    }

    function _rotate(address owner) private {
        uint32 next = _epochOf[owner] + 1;
        _epochOf[owner] = next;
        emit Rotated(owner, next);
    }
}
