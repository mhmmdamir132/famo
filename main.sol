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
    error FM_AlreadyRegistered(uint64 laneId, address fren);
    error FM_NotRegistered(uint64 laneId, address fren);
    error FM_PulseTooLong(uint256 len, uint256 maxLen);
    error FM_TipTooSmall(uint256 sent, uint256 minWei);
    error FM_CapsuleFeeShort(uint256 sent, uint256 required);
    error FM_CapsuleReplay(bytes32 adviceHash);
    error FM_CapsuleBadSig(address expected, address recovered);
    error FM_CapsuleUnknown(uint256 capsuleId);
    error FM_CapsuleRevoked(uint256 capsuleId);
    error FM_GuildUnknown(uint32 guildId);
    error FM_GuildInactive(uint32 guildId);
    error FM_GuildFull(uint32 guildId, uint32 cap);
    error FM_AlreadyInGuild(uint32 guildId, address member);
    error FM_NotInGuild(uint32 guildId, address member);
    error FM_GuildCrestZero();
    error FM_BadgeAlreadyClaimed(uint8 badgeId);
    error FM_BadgeLocked(uint8 badgeId, uint32 required);
    error FM_BadgeIdOutOfRange(uint8 badgeId, uint8 maxId);
    error FM_BatchTooLarge(uint256 n, uint256 maxN);
    error FM_WithdrawZero();
    error FM_InsufficientTipPool(uint256 requested, uint256 available);
    error FM_TransferFailed();
    error FM_WindowInvalid(uint64 windowSec);
    error FM_Reentrant();

    event Opened(uint64 indexed laneId, bytes32 themeHash, uint64 openedAt, uint64 closesAt);
    event Extended(uint64 indexed laneId, uint64 newClosesAt);
    event Sealed(uint64 indexed laneId, uint32 pulseCount, uint32 frenCount);
    event Registered(uint64 indexed laneId, address indexed fren, bytes32 avatarHash, bytes32 personaTag);
    event AuraUpdated(uint64 indexed laneId, address indexed fren, bytes32 auraBlend);
    event Pulled(uint64 indexed laneId, address indexed fren, bytes32 moodHash, bytes32 intentHash, uint32 streak);
    event TipReceived(uint64 indexed laneId, address indexed from, uint256 amountWei, uint256 lanePool);
    event CapsuleStored(uint256 indexed capsuleId, uint64 indexed laneId, address indexed author, bytes32 adviceHash);
    event CapsuleRevoked(uint256 indexed capsuleId, address indexed warden);
    event Claimed(uint64 indexed laneId, address indexed fren, uint8 badgeId);
    event GuildForged(uint32 indexed guildId, address indexed founder, bytes32 crestHash);
    event GuildJoined(uint32 indexed guildId, address indexed member);
    event GuildLeft(uint32 indexed guildId, address indexed member);
    event GuildDissolved(uint32 indexed guildId);
    event WardenMoved(address indexed previous, address indexed next);
    event LanePauseSet(bool paused);
    event TipsWithdrawn(address indexed warden, uint256 amountWei);
    event Genesis(uint64 indexed genesisNonce, address indexed warden, uint256 chainId, uint64 buildTag);

    constructor() {
        ADDRESS_A = 0x3d4B78178c10C06f5B3A9D67F5e9926F16A5d6B9;
        ADDRESS_B = 0x24Df26B74C605bee0b3cD22C39e723654F74Ab10;
        ADDRESS_C = 0xd8292D368deAa6a65C998B604A287c8eD562E585;

        deployChainId = uint64(block.chainid);
        warden = msg.sender;
        genesisNonce = uint64(uint256(keccak256(abi.encodePacked(deployChainId, msg.sender, block.prevrandao, FM_SEED))) >> 192);

        emit Genesis(genesisNonce, msg.sender, block.chainid, FM_BUILD_TAG);
    }

    modifier onlyWarden() {
        if (msg.sender != warden) revert FM_NotWarden(msg.sender);
        _;
    }

    modifier whenLanesLive() {
        if (lanePaused) revert FM_LanePaused();
        _;
    }

    function transferWarden(address next) external onlyWarden {
        address prev = warden;
        warden = next;
        emit WardenMoved(prev, next);
    }

    function setLanePaused(bool paused) external onlyWarden {
        lanePaused = paused;
        emit LanePauseSet(paused);
    }

    function openLane(uint64 laneId, bytes32 themeHash, uint64 windowSec) external onlyWarden whenLanesLive {
        if (laneId > MAX_LANE_ID) revert FM_LaneIdOutOfRange(laneId);
        if (themeHash == bytes32(0)) revert FM_ThemeZero();
        if (windowSec == 0 || windowSec > 604_800) revert FM_WindowInvalid(windowSec);

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt != 0 && !lane.sealed) revert FM_LaneAlreadyOpen(laneId);

        uint64 openedAt = uint64(block.timestamp);
        lane.themeHash = themeHash;
        lane.curatorNote = bytes32(0);
        lane.open = true;
        lane.sealed = false;
        lane.openedAt = openedAt;
        lane.closesAt = openedAt + windowSec;
        lane.pulseCount = 0;
        lane.frenCount = 0;

        if (laneId > lastLaneId) {
            lastLaneId = laneId;
        }

        emit Opened(laneId, themeHash, openedAt, lane.closesAt);
    }

    function setCuratorNote(uint64 laneId, bytes32 noteHash) external onlyWarden {
        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        lane.curatorNote = noteHash;
    }

    function extendLane(uint64 laneId, uint64 extraSec) external onlyWarden {
        if (extraSec == 0 || extraSec > 172_800) revert FM_WindowInvalid(extraSec);
        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (lane.sealed) revert FM_LaneSealed(laneId);

        lane.closesAt += extraSec;
        emit Extended(laneId, lane.closesAt);
    }

    function sealLane(uint64 laneId) external onlyWarden {
        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (lane.sealed) revert FM_LaneSealed(laneId);

        lane.open = false;
        lane.sealed = true;

        emit Sealed(laneId, lane.pulseCount, lane.frenCount);
    }

    function registerFren(uint64 laneId, bytes32 avatarHash, bytes32 personaTag) external whenLanesLive {
        if (avatarHash == bytes32(0)) revert FM_AvatarZero();
        if (personaTag == bytes32(0)) revert FM_PersonaZero();

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (!lane.open || lane.sealed) revert FM_LaneClosed(laneId);
        if (block.timestamp > lane.closesAt) revert FM_LaneClosed(laneId);
        if (_registered[laneId][msg.sender]) revert FM_AlreadyRegistered(laneId, msg.sender);

        _registered[laneId][msg.sender] = true;
        _cards[laneId][msg.sender] = FrenCard({
            avatarHash: avatarHash,
            personaTag: personaTag,
            auraBlend: keccak256(abi.encode(FM_SEED, avatarHash, personaTag)),
            active: true,
            registeredAt: uint64(block.timestamp),
            pulseTotal: 0,
            badgeMask: 0
        });

        unchecked {
            lane.frenCount += 1;
        }

        emit Registered(laneId, msg.sender, avatarHash, personaTag);
    }

    function refreshAura(uint64 laneId, bytes32 pulseHint) external whenLanesLive {
        if (!_registered[laneId][msg.sender]) revert FM_NotRegistered(laneId, msg.sender);

        FrenCard storage card = _cards[laneId][msg.sender];
        uint32 streak = _streak[laneId][msg.sender];
        card.auraBlend = FamoLaneMath.blendAura(card.auraBlend, pulseHint, streak);

        emit AuraUpdated(laneId, msg.sender, card.auraBlend);
    }

    function emitPulse(uint64 laneId, bytes32 moodHash, bytes32 intentHash, bytes32 replyTo) external whenLanesLive {
        _emitPulse(laneId, moodHash, intentHash, replyTo, 0);
    }

    function emitPulseWithTip(uint64 laneId, bytes32 moodHash, bytes32 intentHash, bytes32 replyTo) external payable whenLanesLive {
        if (msg.value < MIN_TIP_WEI) revert FM_TipTooSmall(msg.value, MIN_TIP_WEI);
        _emitPulse(laneId, moodHash, intentHash, replyTo, msg.value);
    }

    function _emitPulse(uint64 laneId, bytes32 moodHash, bytes32 intentHash, bytes32 replyTo, uint256 tipWei) private {
        if (moodHash == bytes32(0)) revert FM_MoodZero();
        if (intentHash == bytes32(0)) revert FM_IntentZero();
        if (!_registered[laneId][msg.sender]) revert FM_NotRegistered(laneId, msg.sender);

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (!lane.open || lane.sealed) revert FM_LaneClosed(laneId);
        if (block.timestamp > lane.closesAt) revert FM_LaneClosed(laneId);

        uint32 streak = FamoLaneMath.clampStreak(_streak[laneId][msg.sender], STREAK_CAP);
        _streak[laneId][msg.sender] = streak;

        _lastPulse[laneId][msg.sender] = PulseRecord({
            moodHash: moodHash,
            intentHash: intentHash,
            replyTo: replyTo,
            emittedAt: uint64(block.timestamp),
            streakAfter: streak
        });

        FrenCard storage card = _cards[laneId][msg.sender];
        unchecked {
            card.pulseTotal += 1;
            lane.pulseCount += 1;
            globalPulseCount += 1;
        }

        card.auraBlend = FamoLaneMath.blendAura(card.auraBlend, moodHash, streak);

        if (tipWei > 0) {
            lane.tipPool += tipWei;
            globalTipWei += tipWei;
            emit TipReceived(laneId, msg.sender, tipWei, lane.tipPool);
        }

        emit Pulled(laneId, msg.sender, moodHash, intentHash, streak);
    }

    function storeCapsule(
        uint64 laneId,
        bytes32 adviceHash,
        bytes32 moodHash,
        bytes calldata signature
    ) external payable whenLanesLive {
        if (msg.value < CAPSULE_FEE_WEI) revert FM_CapsuleFeeShort(msg.value, CAPSULE_FEE_WEI);
        if (adviceHash == bytes32(0)) revert FM_IntentZero();
        if (_usedCapsuleHash[adviceHash]) revert FM_CapsuleReplay(adviceHash);

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (!lane.open || lane.sealed) revert FM_LaneClosed(laneId);

        uint64 nonce = _capsuleNonce[laneId][msg.sender];
        bytes32 digest = _capsuleDigest(laneId, msg.sender, adviceHash, moodHash, nonce);
        _verifyAuthorSignature(msg.sender, digest, signature);

        unchecked {
            _capsuleNonce[laneId][msg.sender] = nonce + 1;
            capsuleSeq += 1;
        }

        _usedCapsuleHash[adviceHash] = true;
        _capsules[capsuleSeq] = Capsule({
            adviceHash: adviceHash,
            moodHash: moodHash,
            author: msg.sender,
            laneId: laneId,
            storedAt: uint64(block.timestamp),
            revoked: false
        });

        lane.tipPool += msg.value;

        emit CapsuleStored(capsuleSeq, laneId, msg.sender, adviceHash);
    }

    function revokeCapsule(uint256 capsuleId) external onlyWarden {
        Capsule storage cap = _capsules[capsuleId];
        if (cap.storedAt == 0) revert FM_CapsuleUnknown(capsuleId);
        if (cap.revoked) revert FM_CapsuleRevoked(capsuleId);
        cap.revoked = true;
        emit CapsuleRevoked(capsuleId, msg.sender);
    }

    function forgeGuild(uint32 guildId, bytes32 crestHash) external whenLanesLive returns (uint32) {
        if (crestHash == bytes32(0)) revert FM_GuildCrestZero();

        Guild storage g = _guilds[guildId];
        if (g.forgedAt != 0 && g.active) revert FM_GuildUnknown(guildId);

        g.crestHash = crestHash;
        g.founder = msg.sender;
        g.active = true;
        g.memberCount = 1;
        g.forgedAt = uint64(block.timestamp);

        _guildMember[guildId][msg.sender] = true;
        _guildRoster[guildId].push(msg.sender);
        _guildsOf[msg.sender].push(guildId);

        emit GuildForged(guildId, msg.sender, crestHash);
        emit GuildJoined(guildId, msg.sender);
        return guildId;
    }

    function joinGuild(uint32 guildId) external whenLanesLive {
        Guild storage g = _guilds[guildId];
        if (g.forgedAt == 0) revert FM_GuildUnknown(guildId);
        if (!g.active) revert FM_GuildInactive(guildId);
        if (g.memberCount >= MAX_GUILD_MEMBERS) revert FM_GuildFull(guildId, MAX_GUILD_MEMBERS);
        if (_guildMember[guildId][msg.sender]) revert FM_AlreadyInGuild(guildId, msg.sender);

        _guildMember[guildId][msg.sender] = true;
        _guildRoster[guildId].push(msg.sender);
        _guildsOf[msg.sender].push(guildId);

        unchecked {
            g.memberCount += 1;
        }

        emit GuildJoined(guildId, msg.sender);
    }

    function leaveGuild(uint32 guildId) external {
        Guild storage g = _guilds[guildId];
        if (g.forgedAt == 0) revert FM_GuildUnknown(guildId);
        if (!_guildMember[guildId][msg.sender]) revert FM_NotInGuild(guildId, msg.sender);

        _guildMember[guildId][msg.sender] = false;
        _removeFromRoster(guildId, msg.sender);
        _removeFromMemberGuilds(msg.sender, guildId);

        unchecked {
            if (g.memberCount > 0) {
                g.memberCount -= 1;
            }
        }

        if (g.memberCount == 0) {
            g.active = false;
            emit GuildDissolved(guildId);
        }

        emit GuildLeft(guildId, msg.sender);
    }

    function claimBadge(uint64 laneId, uint8 badgeId) external whenLanesLive {
        if (badgeId > MAX_BADGE_ID) revert FM_BadgeIdOutOfRange(badgeId, MAX_BADGE_ID);
        if (!_registered[laneId][msg.sender]) revert FM_NotRegistered(laneId, msg.sender);

        FrenCard storage card = _cards[laneId][msg.sender];
        uint32 bit = uint32(1) << badgeId;
        if (card.badgeMask & bit != 0) revert FM_BadgeAlreadyClaimed(badgeId);

        uint32 required = _badgeThreshold(badgeId);
        if (card.pulseTotal < required) revert FM_BadgeLocked(badgeId, required);

        card.badgeMask |= bit;
        emit Claimed(laneId, msg.sender, badgeId);
    }

    function tipLane(uint64 laneId) external payable whenLanesLive {
        if (msg.value < MIN_TIP_WEI) revert FM_TipTooSmall(msg.value, MIN_TIP_WEI);

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);

        lane.tipPool += msg.value;
        globalTipWei += msg.value;

        emit TipReceived(laneId, msg.sender, msg.value, lane.tipPool);
    }

    function withdrawLaneTips(uint64 laneId, uint256 amountWei) external onlyWarden {
        if (_withdrawLock != 1) revert FM_Reentrant();
        _withdrawLock = 2;

        if (amountWei == 0) revert FM_WithdrawZero();

        Lane storage lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        if (amountWei > lane.tipPool) revert FM_InsufficientTipPool(amountWei, lane.tipPool);

        lane.tipPool -= amountWei;
        _sendWei(payable(msg.sender), amountWei);

        emit TipsWithdrawn(msg.sender, amountWei);
        _withdrawLock = 1;
    }

    function laneMeta(uint64 laneId)
        external
        view
        returns (
            bytes32 themeHash,
            bytes32 curatorNote,
            bool open,
            bool sealed,
            uint64 openedAt,
            uint64 closesAt,
            uint32 pulseCount,
            uint32 frenCount,
            uint256 tipPool
        )
    {
        Lane memory lane = _lanes[laneId];
        if (lane.openedAt == 0) revert FM_LaneUnknown(laneId);
        return (
            lane.themeHash,
            lane.curatorNote,
            lane.open,
            lane.sealed,
            lane.openedAt,
            lane.closesAt,
            lane.pulseCount,
            lane.frenCount,
            lane.tipPool
        );
    }

    function frenCard(uint64 laneId, address fren)
        external
        view
        returns (
            bytes32 avatarHash,
            bytes32 personaTag,
            bytes32 auraBlend,
            bool active,
            uint64 registeredAt,
            uint32 pulseTotal,
            uint32 badgeMask
        )
    {
        if (!_registered[laneId][fren]) revert FM_NotRegistered(laneId, fren);
        FrenCard memory card = _cards[laneId][fren];
        return (
            card.avatarHash,
            card.personaTag,
            card.auraBlend,
            card.active,
            card.registeredAt,
            card.pulseTotal,
            card.badgeMask
        );
    }

    function lastPulseOf(uint64 laneId, address fren)
        external
        view
        returns (bytes32 moodHash, bytes32 intentHash, bytes32 replyTo, uint64 emittedAt, uint32 streakAfter)
    {
        if (!_registered[laneId][fren]) revert FM_NotRegistered(laneId, fren);
        PulseRecord memory p = _lastPulse[laneId][fren];
        return (p.moodHash, p.intentHash, p.replyTo, p.emittedAt, p.streakAfter);
    }

    function streakOf(uint64 laneId, address fren) external view returns (uint32) {
        return _streak[laneId][fren];
    }

    function capsuleById(uint256 capsuleId)
        external
        view
        returns (bytes32 adviceHash, bytes32 moodHash, address author, uint64 laneId, uint64 storedAt, bool revoked)
    {
        Capsule memory cap = _capsules[capsuleId];
        if (cap.storedAt == 0) revert FM_CapsuleUnknown(capsuleId);
        return (cap.adviceHash, cap.moodHash, cap.author, cap.laneId, cap.storedAt, cap.revoked);
    }

    function guildMeta(uint32 guildId)
        external
        view
        returns (bytes32 crestHash, address founder, bool active, uint32 memberCount, uint64 forgedAt)
    {
        Guild memory g = _guilds[guildId];
        if (g.forgedAt == 0) revert FM_GuildUnknown(guildId);
        return (g.crestHash, g.founder, g.active, g.memberCount, g.forgedAt);
    }

    function guildRoster(uint32 guildId) external view returns (address[] memory) {
        if (_guilds[guildId].forgedAt == 0) revert FM_GuildUnknown(guildId);
        return _guildRoster[guildId];
    }

    function guildsFor(address member) external view returns (uint32[] memory) {
        return _guildsOf[member];
    }

    function laneOpenNow(uint64 laneId) external view returns (bool) {
        Lane memory lane = _lanes[laneId];
        if (lane.openedAt == 0) return false;
        if (lane.sealed || !lane.open) return false;
        return block.timestamp <= lane.closesAt;
    }

    function frenLaneProof(uint64 laneId, address fren) external view returns (bytes32) {
        if (!_registered[laneId][fren]) revert FM_NotRegistered(laneId, fren);

        FrenCard memory card = _cards[laneId][fren];
        PulseRecord memory pulse = _lastPulse[laneId][fren];
        Lane memory lane = _lanes[laneId];

        bytes32 hA = keccak256(
            abi.encode(FM_DOMAIN_SALT, FM_SEED, laneId, fren, card.avatarHash, card.personaTag, card.pulseTotal)
        );
        bytes32 hB = keccak256(
            abi.encode(
                card.auraBlend,
                pulse.moodHash,
                pulse.intentHash,
                _streak[laneId][fren],
                lane.themeHash,
                genesisNonce,
                warden
            )
        );

        return keccak256(abi.encodePacked(hA, hB, FM_BUILD_TAG, FM_BUILD_STAMP, ADDRESS_A, ADDRESS_B, ADDRESS_C));
    }

