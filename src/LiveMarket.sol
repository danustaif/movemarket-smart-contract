// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILiveMarket} from "./interfaces/ILiveMarket.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {IERC165} from "./interfaces/IERC165.sol";
import "./interfaces/LiveMarketTypes.sol";

/// @title LiveMarket
/// @notice Pasar prediksi parimutuel per rentang ply partai catur Lichess, diselesaikan oleh report Chainlink CRE.
/// @dev Spesifikasi: source/docs/CONTRACTS.md. ABI wajib sama dengan source/sot/abi.json (script/check-abi.mjs).
contract LiveMarket is ILiveMarket, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    address public immutable token;
    address public forwarder;
    address public resolver;
    // Nilai awal: sot/constants.json contract.defaults
    uint16 public feeBps = 200;
    uint128 public minBet = 1e6;
    uint128 public maxStakePerUser = 100e6;
    uint256 public nextMarketId = 1;
    uint256 public feesAccrued;

    // internal supaya tidak ada getter di luar sot/abi.json; akses lewat getMarket/getPosition
    mapping(uint256 => Market) internal _markets;
    mapping(uint256 => mapping(address => Position)) internal _positions;
    mapping(bytes32 => string) public gameRefOf;

    modifier onlyResolver() {
        if (msg.sender != resolver) revert NotResolver();
        _;
    }

    constructor(IERC20 token_, address forwarder_, address resolver_) Ownable(msg.sender) {
        token = address(token_);
        forwarder = forwarder_;
        resolver = resolver_;
    }

    // ------------------------------------------------------------------ resolver

    function createMarkets(MarketParams[] calldata p) external onlyResolver whenNotPaused returns (uint256 firstId) {
        uint256 n = p.length;
        if (n == 0 || n > MAX_CREATE_BATCH) revert BadBatch();
        firstId = nextMarketId;
        for (uint256 i; i < n; i++) {
            MarketParams calldata q = p[i];
            uint256 refLen = bytes(q.gameRef).length;
            // Urutan cek penting: toPly >= fromPly sebelum pengurangan, lockTime dibatasi sebelum penjumlahan.
            if (
                refLen == 0 || refLen > MAX_GAMEREF_BYTES || q.fromPly < 1 || q.toPly < q.fromPly
                    || q.toPly - q.fromPly >= MAX_WINDOW_PLIES || q.lockTime <= block.timestamp
                    || q.lockTime > block.timestamp + MAX_BET_WINDOW_SEC || q.resolveDeadline <= q.lockTime
                    || q.resolveDeadline > q.lockTime + MAX_RESOLVE_DELAY_SEC
                    || (q.marketType == MarketType.CASTLE && q.side == Side.ANY)
            ) revert InvalidParams(i);

            uint256 id = firstId + i;
            bytes32 gameKey = keccak256(bytes(q.gameRef));
            Market storage m = _markets[id];
            m.gameKey = gameKey;
            m.marketType = q.marketType;
            m.side = q.side;
            m.fromPly = q.fromPly;
            m.toPly = q.toPly;
            m.lockTime = q.lockTime;
            m.resolveDeadline = q.resolveDeadline;
            if (bytes(gameRefOf[gameKey]).length == 0) gameRefOf[gameKey] = q.gameRef;
            emit MarketCreated(
                id, gameKey, q.gameRef, uint8(q.marketType), uint8(q.side), q.fromPly, q.toPly, q.lockTime,
                q.resolveDeadline
            );
        }
        nextMarketId = firstId + n;
    }

    function lockMarkets(uint256[] calldata ids) external onlyResolver {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_LOCK_BATCH) revert BadBatch();
        for (uint256 i; i < n; i++) {
            Market storage m = _markets[ids[i]];
            // Pasar yang tidak ada punya lockTime 0, jadi ikut terlewati oleh cek waktu.
            if (m.status == Status.OPEN && block.timestamp < m.lockTime) {
                m.lockTime = uint64(block.timestamp);
                emit MarketLocked(ids[i], m.lockTime);
            }
        }
    }

    function requestResolution(string calldata gameRef, uint256[] calldata ids) external onlyResolver {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_RESOLVE_BATCH) revert BadBatch();
        bytes32 gameKey = keccak256(bytes(gameRef));
        uint256[] memory open = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; i++) {
            uint256 id = ids[i];
            Market storage m = _markets[id];
            // Pasar yang tidak ada punya gameKey 0, jadi ikut tertolak oleh cek gameKey.
            if (m.gameKey != gameKey || block.timestamp < m.lockTime) revert InvalidMarket(id);
            if (m.status != Status.OPEN) continue;
            m.resolutionRequested = true;
            open[k++] = id;
        }
        if (k == 0) revert BadBatch();
        assembly ("memory-safe") {
            mstore(open, k) // potong ke jumlah pasar yang tersisa
        }
        emit ResolutionRequested(gameKey, gameRef, open);
    }

    // ------------------------------------------------------------------ pengguna

    function bet(uint256 id, bool yes, uint128 amount) external nonReentrant whenNotPaused {
        Market storage m = _markets[id];
        if (!_exists(id) || m.status != Status.OPEN) revert MarketNotOpen(id);
        if (block.timestamp >= m.lockTime) revert BettingClosed(id);
        if (amount < minBet) revert AmountTooSmall();
        Position storage pos = _positions[id][msg.sender];
        if (uint256(pos.yes) + pos.no + amount > maxStakePerUser) revert StakeCapExceeded();

        if (yes) {
            m.poolYes += amount;
            pos.yes += amount;
        } else {
            m.poolNo += amount;
            pos.no += amount;
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit BetPlaced(id, msg.sender, yes, amount, m.poolYes, m.poolNo);
    }

    function claim(uint256 id) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[id];
        if (m.status != Status.RESOLVED) revert NotClaimable(id); // RESOLVED selalu YES atau NO
        Position storage pos = _positions[id][msg.sender];
        if (pos.settled) revert AlreadySettled(id);
        if (_winStake(m, pos) == 0) revert NothingToClaim(id);

        payout = _payout(m, pos);
        pos.settled = true;
        IERC20(token).safeTransfer(msg.sender, payout);
        emit Claimed(id, msg.sender, payout);
    }

    function claimMany(uint256[] calldata ids) external nonReentrant returns (uint256 totalPayout) {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            Market storage m = _markets[id];
            Position storage pos = _positions[id][msg.sender];
            if (m.status != Status.RESOLVED || pos.settled || _winStake(m, pos) == 0) continue;
            uint256 payout = _payout(m, pos);
            pos.settled = true;
            totalPayout += payout;
            emit Claimed(id, msg.sender, payout);
        }
        if (totalPayout > 0) IERC20(token).safeTransfer(msg.sender, totalPayout);
    }

    function refund(uint256 id) external nonReentrant returns (uint256 amount) {
        Market storage m = _markets[id];
        if (_isExpired(id, m)) _void(id, VOID_EXPIRED);
        if (m.status != Status.VOIDED) revert NotRefundable(id);
        Position storage pos = _positions[id][msg.sender];
        if (pos.settled) revert AlreadySettled(id);
        amount = uint256(pos.yes) + pos.no;
        if (amount == 0) revert NotRefundable(id);

        pos.settled = true;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Refunded(id, msg.sender, amount);
    }

    // ------------------------------------------------------------------ CRE

    function onReport(bytes calldata, bytes calldata report) external override {
        if (msg.sender != forwarder) revert UnauthorizedForwarder(msg.sender);
        (bytes32 gameKey, uint256[] memory ids, uint8[] memory outcomes) =
            abi.decode(report, (bytes32, uint256[], uint8[]));
        uint256 n = ids.length;
        if (n != outcomes.length || n > MAX_RESOLVE_BATCH) revert BadReport();

        for (uint256 i; i < n; i++) {
            uint256 id = ids[i];
            uint8 o = outcomes[i];
            Market storage m = _markets[id];
            uint8 skip;
            if (!_exists(id)) skip = SKIP_MARKET_NOT_FOUND;
            else if (m.gameKey != gameKey) skip = SKIP_GAME_MISMATCH;
            else if (m.status != Status.OPEN) skip = SKIP_NOT_OPEN;
            else if (block.timestamp < m.lockTime) skip = SKIP_NOT_LOCKED;
            else if (o < uint8(Outcome.YES) || o > uint8(Outcome.VOID)) skip = SKIP_BAD_OUTCOME;
            if (skip != 0) {
                emit ResolutionSkipped(id, skip);
                continue;
            }

            if (o == uint8(Outcome.VOID)) {
                _void(id, VOID_ORACLE);
                continue;
            }
            uint128 winPool = o == uint8(Outcome.YES) ? m.poolYes : m.poolNo;
            if (winPool == 0) {
                _void(id, VOID_NO_WINNERS);
                continue;
            }
            m.status = Status.RESOLVED;
            m.outcome = Outcome(o);
            if (m.poolYes > 0 && m.poolNo > 0) {
                // aman: fee <= 5% dari dua pool uint128, selalu muat di uint128
                // forge-lint: disable-next-line(unsafe-typecast)
                uint128 fee = uint128((uint256(m.poolYes) + m.poolNo) * feeBps / BPS);
                m.fee = fee;
                feesAccrued += fee;
            }
            emit MarketResolved(id, o);
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ owner

    function adminVoid(uint256[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; i++) {
            if (!_exists(ids[i]) || _markets[ids[i]].status != Status.OPEN) revert MarketNotOpen(ids[i]);
            _void(ids[i], VOID_ADMIN);
        }
    }

    function setForwarder(address forwarder_) external onlyOwner {
        forwarder = forwarder_;
        emit ForwarderUpdated(forwarder_);
    }

    function setResolver(address resolver_) external onlyOwner {
        resolver = resolver_;
        emit ResolverUpdated(resolver_);
    }

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
    }

    function setLimits(uint128 minBet_, uint128 maxStakePerUser_) external onlyOwner {
        minBet = minBet_;
        maxStakePerUser = maxStakePerUser_;
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = feesAccrued;
        feesAccrued = 0;
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ view

    function getMarket(uint256 id) external view returns (Market memory) {
        return _markets[id];
    }

    function getMarkets(uint256[] calldata ids) external view returns (MarketView[] memory views) {
        views = new MarketView[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            Market storage m = _markets[ids[i]];
            views[i] = MarketView(
                ids[i], m.gameKey, uint8(m.marketType), uint8(m.side), m.fromPly, m.toPly, m.lockTime, uint8(m.status)
            );
        }
    }

    function getPosition(uint256 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function claimable(uint256 id, address user) external view returns (uint256) {
        Market storage m = _markets[id];
        Position storage pos = _positions[id][user];
        if (m.status != Status.RESOLVED || pos.settled) return 0;
        return _payout(m, pos);
    }

    function refundable(uint256 id, address user) external view returns (uint256) {
        Market storage m = _markets[id];
        Position storage pos = _positions[id][user];
        if ((m.status != Status.VOIDED && !_isExpired(id, m)) || pos.settled) return 0;
        return uint256(pos.yes) + pos.no;
    }

    // ------------------------------------------------------------------ internal

    function _exists(uint256 id) private view returns (bool) {
        return id != 0 && id < nextMarketId;
    }

    /// @dev OPEN dan sudah lewat resolveDeadline: refund pertama mengubahnya menjadi VOIDED (VOID_EXPIRED).
    function _isExpired(uint256 id, Market storage m) private view returns (bool) {
        return _exists(id) && m.status == Status.OPEN && block.timestamp > m.resolveDeadline;
    }

    function _winStake(Market storage m, Position storage pos) private view returns (uint256) {
        return m.outcome == Outcome.YES ? pos.yes : pos.no;
    }

    /// @dev payout = winStake * (total - fee) / winPool, dibulatkan ke bawah: jumlah semua payout <= total - fee.
    ///      winPool > 0 dijamin onReport (pool pemenang kosong menjadi VOID_NO_WINNERS).
    function _payout(Market storage m, Position storage pos) private view returns (uint256) {
        uint256 winPool = m.outcome == Outcome.YES ? m.poolYes : m.poolNo;
        return Math.mulDiv(_winStake(m, pos), uint256(m.poolYes) + m.poolNo - m.fee, winPool);
    }

    function _void(uint256 id, uint8 reason) private {
        Market storage m = _markets[id];
        m.status = Status.VOIDED;
        m.outcome = Outcome.VOID;
        emit MarketVoided(id, reason);
    }
}
