// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title famo — codename synapse alley
/// @notice AI fren protocol registry: lane pulses, persona cards, guild bonds, and capsule attestations.

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

library FamoECDSA {
    error FM_BadSigLength();
    error FM_BadSigV();
    error FM_BadSigS();
    error FM_RecoveredZero();

    bytes32 private constant _SECP256K1N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != 65) revert FM_BadSigLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        if (uint256(s) > uint256(_SECP256K1N) >> 1) revert FM_BadSigS();
        if (v != 27 && v != 28) revert FM_BadSigV();

        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert FM_RecoveredZero();
    }
}

library FamoLaneMath {
    function clampStreak(uint32 current, uint32 cap) internal pure returns (uint32) {
        if (current >= cap) return cap;
        return current + 1;
    }

    function blendAura(bytes32 base, bytes32 pulse, uint32 streak) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, pulse, streak));
    }

    function guildDigest(bytes32 root, address[] memory members, uint32 memberCount) internal pure returns (bytes32) {
        return keccak256(abi.encode(root, members, memberCount));
    }
}

contract FamoSynapseAlley {
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    bytes32 private constant FM_DOMAIN_SALT =
        0x5608c194fc433a1166502fe5aba99288d3022bca59128e0dedafb264288260da;
    bytes16 private constant FM_SEED = 0x4a94746894df9b5a4c02c0bcbe0feeb5;
    uint64 public constant FM_BUILD_TAG = 0xD15840EF1BDC4BAF;
    uint32 public constant FM_BUILD_STAMP = 2262424350;

    uint64 public constant MAX_LANE_ID = 912_106;
    uint32 public constant MAX_GUILD_MEMBERS = 8942;
    uint32 public constant MAX_PULSE_BYTES = 449;
    uint256 public constant MIN_TIP_WEI = 409;
    uint256 public constant CAPSULE_FEE_WEI = 2523;
    uint32 public constant STREAK_CAP = 144;
    uint32 public constant MAX_BATCH = 64;
    uint8 public constant MAX_BADGE_ID = 7;

    bytes32 public constant FM_EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant FM_CAPSULE_TYPEHASH =
        keccak256("FrenCapsule(uint64 laneId,address author,bytes32 adviceHash,bytes32 moodHash,uint64 nonce)");
    bytes32 public constant FM_DOMAIN_NAME_HASH = keccak256("FamoSynapseAlley");
    bytes32 public constant FM_DOMAIN_VERSION_HASH = keccak256("1");
    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;

    struct Lane {
        bytes32 themeHash;
        bytes32 curatorNote;
        bool open;
        bool sealed;
        uint64 openedAt;
        uint64 closesAt;
        uint32 pulseCount;
        uint32 frenCount;
        uint256 tipPool;
    }

    struct FrenCard {
        bytes32 avatarHash;
        bytes32 personaTag;
        bytes32 auraBlend;
        bool active;
        uint64 registeredAt;
        uint32 pulseTotal;
        uint32 badgeMask;
    }

    struct PulseRecord {
        bytes32 moodHash;
        bytes32 intentHash;
        bytes32 replyTo;
        uint64 emittedAt;
        uint32 streakAfter;
    }

    struct Guild {
        bytes32 crestHash;
        address founder;
        bool active;
        uint32 memberCount;
        uint64 forgedAt;
    }

    struct Capsule {
        bytes32 adviceHash;
        bytes32 moodHash;
        address author;
        uint64 laneId;
        uint64 storedAt;
        bool revoked;
    }

    address public warden;
    bool public lanePaused;

    uint64 public genesisNonce;
    uint64 public deployChainId;
    uint64 public lastLaneId;
    uint256 public globalPulseCount;
    uint256 public globalTipWei;
    uint256 public capsuleSeq;

    mapping(uint64 => Lane) private _lanes;
    mapping(uint64 => mapping(address => FrenCard)) private _cards;
    mapping(uint64 => mapping(address => bool)) private _registered;
    mapping(uint64 => mapping(address => PulseRecord)) private _lastPulse;
    mapping(uint64 => mapping(address => uint32)) private _streak;
    mapping(uint64 => mapping(address => uint64)) private _capsuleNonce;
    mapping(uint256 => Capsule) private _capsules;
    mapping(uint32 => Guild) private _guilds;
    mapping(uint32 => mapping(address => bool)) private _guildMember;
    mapping(uint32 => address[]) private _guildRoster;
    mapping(address => uint32[]) private _guildsOf;
    mapping(bytes32 => bool) private _usedCapsuleHash;

    uint256 private _withdrawLock = 1;

    error FM_NotWarden(address caller);
    error FM_LanePaused();
    error FM_LaneUnknown(uint64 laneId);
    error FM_LaneAlreadyOpen(uint64 laneId);
    error FM_LaneClosed(uint64 laneId);
    error FM_LaneSealed(uint64 laneId);
    error FM_LaneIdOutOfRange(uint64 laneId);
    error FM_ThemeZero();
    error FM_AvatarZero();
    error FM_PersonaZero();
    error FM_MoodZero();
    error FM_IntentZero();
