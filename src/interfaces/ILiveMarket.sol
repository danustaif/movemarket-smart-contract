// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReceiver} from "./IReceiver.sol";
import {MarketType, Side, Status, Outcome} from "./LiveMarketTypes.sol";

/// @title ILiveMarket
/// @notice Pasar prediksi parimutuel per rentang ply partai catur Lichess, diselesaikan oleh report Chainlink CRE.
/// @dev Antarmuka ini wajib identik dengan sot/abi.json (dicek oleh script/check-abi.mjs).
///      Perilaku lengkap: docs/CONTRACTS.md. Invarian yang dijaga implementasi:
///      1. Tidak ada BetPlaced saat block.timestamp >= lockTime.
///      2. Pasar RESOLVED atau VOIDED tidak pernah berubah status atau outcome lagi.
///      3. RESOLVED: total payout <= poolYes + poolNo - fee.
///      4. VOIDED: total refund <= poolYes + poolNo dan fee == 0.
///      5. Satu posisi hanya di-settle sekali (claim atau refund).
///      6. token.balanceOf(this) >= feesAccrued + kewajiban yang belum dibayar.
///      7. Hanya forwarder yang bisa membuat pasar RESOLVED. Owner hanya bisa void.
///      8. lockTime tidak pernah bertambah setelah pasar dibuat.
interface ILiveMarket is IReceiver {
    // ------------------------------------------------------------------ struct

    struct MarketParams {
        string gameRef;           // "lichess:game:{id}" atau "lichess:study:{round}:{chapter}", maks 96 byte
        MarketType marketType;
        Side side;                // CASTLE wajib != ANY
        uint16 fromPly;           // inklusif, 1-based
        uint16 toPly;             // inklusif, lebar maks MAX_WINDOW_PLIES
        uint64 lockTime;          // (now, now + MAX_BET_WINDOW_SEC]
        uint64 resolveDeadline;   // (lockTime, lockTime + MAX_RESOLVE_DELAY_SEC]
    }

    struct Market {
        bytes32 gameKey;          // keccak256(bytes(gameRef))
        MarketType marketType;
        Side side;
        uint16 fromPly;
        uint16 toPly;
        uint64 lockTime;          // bet ditolak saat block.timestamp >= lockTime; hanya maju lewat lockMarkets
        uint64 resolveDeadline;   // refund terbuka kalau masih OPEN setelah ini
        Status status;
        Outcome outcome;
        bool resolutionRequested;
        uint128 poolYes;
        uint128 poolNo;
        uint128 fee;              // diisi saat resolve, 0 kalau salah satu pool kosong
    }

    /// @dev Bentuk ringkas untuk satu EVM read di workflow CRE.
    struct MarketView {
        uint256 id;
        bytes32 gameKey;
        uint8 marketType;
        uint8 side;
        uint16 fromPly;
        uint16 toPly;
        uint64 lockTime;
        uint8 status;
    }

    struct Position {
        uint128 yes;
        uint128 no;
        bool settled;             // true setelah claim atau refund
    }

    // ------------------------------------------------------------------ event

    event MarketCreated(
        uint256 indexed id, bytes32 indexed gameKey, string gameRef,
        uint8 marketType, uint8 side, uint16 fromPly, uint16 toPly,
        uint64 lockTime, uint64 resolveDeadline
    );
    event MarketLocked(uint256 indexed id, uint64 lockTime);
    event BetPlaced(uint256 indexed id, address indexed user, bool yes, uint128 amount, uint128 poolYes, uint128 poolNo);
    event ResolutionRequested(bytes32 indexed gameKey, string gameRef, uint256[] ids);
    event MarketResolved(uint256 indexed id, uint8 outcome);
    event MarketVoided(uint256 indexed id, uint8 reason);         // VOID_* di LiveMarketTypes.sol
    event ResolutionSkipped(uint256 indexed id, uint8 reason);    // SKIP_* di LiveMarketTypes.sol
    event Claimed(uint256 indexed id, address indexed user, uint256 payout);
    event Refunded(uint256 indexed id, address indexed user, uint256 amount);
    event ForwarderUpdated(address forwarder);
    event ResolverUpdated(address resolver);
    event FeesWithdrawn(address to, uint256 amount);

    // ------------------------------------------------------------------ error

    error NotResolver();
    error UnauthorizedForwarder(address caller);
    error InvalidParams(uint256 index);
    error InvalidMarket(uint256 id);
    error MarketNotOpen(uint256 id);
    error BettingClosed(uint256 id);
    error AmountTooSmall();
    error StakeCapExceeded();
    error NotClaimable(uint256 id);
    error NothingToClaim(uint256 id);
    error AlreadySettled(uint256 id);
    error NotRefundable(uint256 id);
    error BadReport();
    error BadBatch();
    error FeeTooHigh();

    // ------------------------------------------------------------------ resolver

    /// @notice Buat 1 sampai MAX_CREATE_BATCH pasar. ID berurutan mulai nextMarketId.
    /// @dev onlyResolver, whenNotPaused. Revert BadBatch (panjang) atau InvalidParams(index).
    function createMarkets(MarketParams[] calldata p) external returns (uint256 firstId);

    /// @notice Kunci ply (SOT D11): set lockTime = block.timestamp untuk pasar OPEN yang belum terkunci.
    /// @dev onlyResolver, tetap jalan saat paused. Pasar tidak memenuhi syarat dilewati tanpa revert.
    ///      Revert BadBatch kalau panjang di luar 1..MAX_LOCK_BATCH.
    function lockMarkets(uint256[] calldata ids) external;

    /// @notice Minta resolusi final ke CRE. Pasar non-OPEN dilewati; event hanya memuat id tersisa.
    /// @dev onlyResolver. Revert InvalidMarket(id) kalau tidak ada, gameKey beda, atau belum lewat lockTime.
    ///      Revert BadBatch kalau panjang di luar 1..MAX_RESOLVE_BATCH atau tidak ada yang tersisa.
    function requestResolution(string calldata gameRef, uint256[] calldata ids) external;

    // ------------------------------------------------------------------ pengguna

    /// @notice Stake ke sisi YES atau NO. Boleh dua sisi di pasar yang sama.
    /// @dev whenNotPaused. Revert MarketNotOpen, BettingClosed, AmountTooSmall, StakeCapExceeded.
    ///      Butuh approve tUSDC ke kontrak ini.
    function bet(uint256 id, bool yes, uint128 amount) external;

    /// @notice payout = winStake * (poolYes + poolNo - fee) / winPool.
    /// @dev Revert NotClaimable, AlreadySettled, NothingToClaim.
    function claim(uint256 id) external returns (uint256 payout);

    /// @notice Seperti claim untuk banyak pasar; yang tidak bisa diklaim dilewati. Satu transfer.
    function claimMany(uint256[] calldata ids) external returns (uint256 totalPayout);

    /// @notice Kembalikan seluruh stake kalau VOIDED, atau OPEN dan sudah lewat resolveDeadline
    ///         (refund pertama mengubah pasar menjadi VOIDED dengan alasan VOID_EXPIRED).
    /// @dev Revert NotRefundable, AlreadySettled.
    function refund(uint256 id) external returns (uint256 amount);

    // ------------------------------------------------------------------ CRE
    // onReport(bytes metadata, bytes report) dan supportsInterface(bytes4) diwarisi dari IReceiver.
    // onReport: msg.sender wajib forwarder (UnauthorizedForwarder). report = abi.encode(bytes32 gameKey,
    // uint256[] ids, uint8[] outcomes) dengan outcome 1 YES, 2 NO, 3 VOID. Panjang tidak cocok atau
    // > MAX_RESOLVE_BATCH: BadReport. Pasar tidak valid dilewati dengan ResolutionSkipped, tidak revert.
    // supportsInterface wajib true untuk type(IReceiver).interfaceId dan type(IERC165).interfaceId.

    // ------------------------------------------------------------------ owner

    /// @notice Void pasar OPEN (VOID_ADMIN). Owner tidak punya cara menetapkan YES/NO.
    function adminVoid(uint256[] calldata ids) external;
    /// @notice Ganti forwarder: MockKeystoneForwarder (simulasi) atau KeystoneForwarder (DON).
    function setForwarder(address forwarder) external;
    function setResolver(address resolver) external;
    /// @dev Revert FeeTooHigh kalau > MAX_FEE_BPS. Berlaku untuk resolusi berikutnya.
    function setFeeBps(uint16 feeBps) external;
    function setLimits(uint128 minBet, uint128 maxStakePerUser) external;
    function withdrawFees(address to) external;
    /// @dev Menghentikan bet dan createMarkets saja. lockMarkets, claim, refund, onReport tetap jalan.
    function pause() external;
    function unpause() external;

    // ------------------------------------------------------------------ view

    function getMarket(uint256 id) external view returns (Market memory);
    function getMarkets(uint256[] calldata ids) external view returns (MarketView[] memory);
    function getPosition(uint256 id, address user) external view returns (Position memory);
    /// @return 0 kalau tidak bisa klaim.
    function claimable(uint256 id, address user) external view returns (uint256);
    /// @return 0 kalau tidak bisa refund.
    function refundable(uint256 id, address user) external view returns (uint256);

    function token() external view returns (address);
    function forwarder() external view returns (address);
    function resolver() external view returns (address);
    function feeBps() external view returns (uint16);
    function minBet() external view returns (uint128);
    function maxStakePerUser() external view returns (uint128);
    function nextMarketId() external view returns (uint256);
    function feesAccrued() external view returns (uint256);
    function gameRefOf(bytes32 gameKey) external view returns (string memory);
}
